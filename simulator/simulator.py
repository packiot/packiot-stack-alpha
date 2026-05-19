#!/usr/bin/env python3
"""
PLC + Operator Simulator — two-layer simulation for packiot-stack-alpha.

PLC layer: Reads every active packml_register topic from the DB, creates one
  MachineState per topic, and POSTs metric payloads to edge-nodered /plc-data
  on every tick.  edge-nodered forwards through pack-queue → pubsub-out →
  oeecloud → DB, exercising the full E2E ingestion pipeline.

Operator layer: Every OP_INTERVAL seconds, rotates through three simulated
  users (ana.operator, joao.supervisor, maria.operator) and performs a
  realistic operator action against edge-api (justify event, create manual
  event, start/stop PO).  Each user gets one action per cycle so the Grafana
  "Actions per User" panel stays balanced.

Env vars (with defaults):
  EDGE_NODERED_URL   http://edge-nodered:1880
  EDGE_API_URL       http://edge-api:8080
  DB_URL             postgresql://postgres:packiot@postgres:5432/packiot
  SIM_INTERVAL       5    (seconds between PLC ticks)
  OP_INTERVAL        15   (seconds between operator actions)
"""

import os
import sys
import time
import random
import logging
import psycopg2
import psycopg2.extras
import requests
from datetime import datetime, timezone, timedelta
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("sim")

EDGE_NODERED_URL = os.environ.get("EDGE_NODERED_URL", "http://edge-nodered:1880")
EDGE_API_URL     = os.environ.get("EDGE_API_URL",     "http://edge-api:8080")
DB_URL           = os.environ.get("DB_URL", "postgresql://postgres:packiot@postgres:5432/packiot")
INTERVAL         = int(os.environ.get("SIM_INTERVAL", "5"))
OP_INTERVAL      = int(os.environ.get("OP_INTERVAL",  "15"))

# Minimum ticks a machine must stay stopped before it can recover.
# Guarantees all PLC-generated downtime events are >12 min in the historic.
MIN_STOP_TICKS = max(1, 720 // INTERVAL)   # 720 s = 12 min

# Developer testing: keep a handful of unjustified events for the justify/split test flow.
PENDING_MIN = 4

# PackML states / modes
STATE_RUNNING, STATE_STOPPED = 6, 10
MODE_PRODUCTION, MODE_MANUAL = 1, 3

# Per-enterprise PLC profile — drives speed/scrap/downtime variability so
# dashboards see realistic diversity across enterprises.
ENTERPRISE_PROFILES = {
    "Dev Enterprise":    dict(ideal_speed=120, scrap_rate=0.03, stop_prob=0.001,  start_prob=0.006),
    "Demo Factory":      dict(ideal_speed=120, scrap_rate=0.06, stop_prob=0.0015, start_prob=0.005),
    "AutoParts Corp":    dict(ideal_speed=80,  scrap_rate=0.02, stop_prob=0.0008, start_prob=0.006),
    "FoodCo Industries": dict(ideal_speed=200, scrap_rate=0.04, stop_prob=0.001,  start_prob=0.005),
    "Simulator Corp":    dict(ideal_speed=120, scrap_rate=0.04, stop_prob=0.001,  start_prob=0.005),
}
DEFAULT_PROFILE = dict(ideal_speed=120, scrap_rate=0.03, stop_prob=0.07, start_prob=0.25)

# Per-machine overrides — each Simulator Corp machine has a distinct character:
#   A: fast throughput, low scrap, reliable  (hero machine)
#   B: slow but very stable, low downtime    (workhorse)
#   C: medium speed, higher scrap, fragile   (problem child)
#
# stop_prob controls how often a machine stops (at 5s ticks):
#   0.0004 → avg 2500 ticks = 3.5 h between stops → ~2 stops per 8h shift
#   0.0006 → avg 1667 ticks = 2.3 h between stops → ~3 stops per 8h shift
#   0.001  → avg 1000 ticks = 83 min between stops → ~5 stops per 8h shift
# start_prob controls stop duration after the 12-min MIN_STOP_TICKS floor:
#   0.005 → avg ~200 additional ticks = 17 min  (total avg stop ~29 min)
#   0.004 → avg ~250 additional ticks = 21 min  (total avg stop ~33 min)
# stuck_max controls the rare prolonged-fault ceiling (ticks × 5s).
MACHINE_PROFILES = {
    "Sim-Machine-A": dict(ideal_speed=150, scrap_rate=0.01, stop_prob=0.0004, start_prob=0.005, stuck_max=360),
    "Sim-Machine-B": dict(ideal_speed=60,  scrap_rate=0.04, stop_prob=0.0006, start_prob=0.004, stuck_max=240),
    "Sim-Machine-C": dict(ideal_speed=100, scrap_rate=0.08, stop_prob=0.001,  start_prob=0.005, stuck_max=480),
}

# Operator simulation constants
SIMCORP_NAME = "Simulator Corp"

USERS = [
    "ana.operator",
    "joao.supervisor",
    "maria.operator",
]

CATEGORIES = [
    ("MEC", "Mechanical", "JAM",      "Conveyor jam"),
    ("ELE", "Electrical", "SENSOR",   "Sensor fault"),
    ("OP",  "Operator",   "SETUP",    "Setup time"),
    ("QUA", "Quality",    "REWORK",   "Product rework"),
    ("MAT", "Material",   "SHORTAGE", "Material shortage"),
]

# Realistic product + client data for PO generation
PRODUCTS = [
    ("Alpha-Widget-A",   "AlphaComp Ltd"),
    ("Beta-Gear-B12",    "BetaDrive Inc"),
    ("Delta-Bracket-C",  "DeltaMech SA"),
    ("Gamma-Seal-V3",    "GammaFlex"),
    ("Omega-Shaft-20mm", "Omega Precision"),
    ("Sigma-Frame-Std",  "SigmaTools"),
    ("Tau-Plate-4x",     "TauMetals"),
    ("Zeta-Housing-M6",  "ZetaWorks"),
]

# Single system user for all automated actions — the action type is already
# captured in user_logs.category, so the name doesn't need to repeat it.
GUARDIAN_USER = "system"
AUTO_USER     = "system"

# Auto-categorization: rule-engine categories (distinct from human operator choices)
AUTO_CATEGORIES = [
    ("MEC", "Mechanical", "MICRO",     "Micro-stop (auto-detected)"),
    ("ELE", "Electrical", "TRANSIENT", "Transient fault (auto)"),
    ("OP",  "Operator",   "IDLE",      "Idle time (auto-classified)"),
    ("MEC", "Mechanical", "JAM",       "Conveyor jam (auto)"),
]

AUTO_JUSTIFY_PROB = 0.10   # fraction of pending events auto-justified per sweep
AUTO_INTERVAL    = 30      # seconds between guardian + auto-justify sweeps

# Action type pool — drawn with replacement; each action appears in proportion.
# justify (30 %) > manual (17 %) > start-PO (15 %) > stop-PO (10 %) > split (8 %)
# > change_status (4 %) > change_time (4 %) > replace (4 %) > setup (4 %) > edit (4 %)
_ACTIONS = (
    ["justify"]        * 30 +
    ["manual"]         * 17 +
    ["start"]          * 15 +
    ["stop"]           * 10 +
    ["split"]          *  8 +
    ["change_status"]  *  4 +
    ["change_time"]    *  4 +
    ["replace"]        *  4 +
    ["setup"]          *  4 +
    ["edit_manual"]    *  4
)


# ── Database helpers ──────────────────────────────────────────────────────────

def get_conn():
    c = psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)
    c.autocommit = True   # reads-only connection; never leave idle-in-transaction locks
    return c


def load_plc_topics(conn) -> list[Any]:
    """Every active packml_register entry becomes one MachineState.

    We publish at whatever granularity packml_register defines (line, sector,
    or machine) — oeecloud matches the first 4 segments of the metric name to
    pick id_equipment, so we honour the existing topology instead of guessing.
    """
    with conn.cursor() as cur:
        cur.execute("""
            SELECT pr.packml_topic, pr.id_equipment, pr.id_unit,
                   e.nm_enterprise, eq.nm_equipment, eq.tp_equipment
            FROM packml_register pr
            JOIN equipments  eq ON eq.id_equipment = pr.id_equipment
            JOIN enterprises e  ON e.id_enterprise = eq.id_enterprise
            WHERE pr.active = true
            ORDER BY pr.id_packml_register
        """)
        return list(cur.fetchall())


# ── PLC simulation ────────────────────────────────────────────────────────────

class MachineState:
    """Per-topic state machine. One instance per active packml_register row.

    Two metric-name shapes, picked by topic depth so oeecloud's parser routes
    each metric correctly (it has separate code paths for line-level and
    machine-level topics that disagree on which segment carries the type):

      4 segments (`Ent/Site/Area/<Line-or-Machine>`)
        → publish `<topic>/Status/<MetricType>`
      5+ segments (`Ent/Site/Area/Line/Machine[/...]`)
        → publish at line-level: `<topic[0..3]>/Admin/<MetricType>/<id_unit>/<cd_machine>***TRIG_C=I`

    The 5+ form mirrors what edge-node-red's multi-enterprise PLC dummies
    produced and is the only shape oeecloud's `prep new topics` function
    classifies as ProdProcessedCount/Defective (the simpler `<topic>/Status/...`
    form for 5-segment topics is mis-routed to StateCurrent).
    """

    def __init__(self, packml_topic, profile, id_unit=None, cd_machine="MCH"):
        self.topic       = packml_topic
        # Machine-specific profile overrides enterprise defaults when available.
        nm   = packml_topic.rstrip("/").rsplit("/", 1)[-1]
        prof = MACHINE_PROFILES.get(nm) or profile
        self.ideal_speed = prof["ideal_speed"] * random.uniform(0.90, 1.10)
        self.scrap_rate  = prof["scrap_rate"]
        self.stop_prob   = prof["stop_prob"]
        self.start_prob  = prof["start_prob"]
        self._stuck_max  = prof.get("stuck_max", 36)   # max ticks in prolonged fault
        self.state       = STATE_RUNNING
        self.counter     = 0
        self.scrap_ctr   = 0
        # Ticks elapsed since the current stop began.  Machine cannot recover
        # until this reaches MIN_STOP_TICKS (12 min), ensuring all historic
        # events have >10 min duration.
        self._stop_ticks: int = 0
        # Prolonged-stoppage mode: when > 0, machine ignores start_prob.
        # Duration now capped per machine profile (default 3 min max at 5s tick).
        self._stuck_ticks: int = 0

        segments = packml_topic.split("/")
        if len(segments) >= 5:
            self.line_topic = "/".join(segments[:4])
            self.id_unit    = id_unit or 0
            self.cd_machine = cd_machine
            self.shape      = "admin"
        else:
            self.line_topic = packml_topic
            self.shape      = "status"

    def _metric_name(self, metric_type):
        if self.shape == "admin":
            base = f"{self.line_topic}/Admin/{metric_type}/{self.id_unit}/{self.cd_machine}"
            return base + "***TRIG_C=I" if metric_type == "ProdProcessedCount" else base
        return f"{self.line_topic}/Status/{metric_type}"

    def tick(self):
        if self.state == STATE_RUNNING and random.random() < self.stop_prob:
            self.state = STATE_STOPPED
            self._stop_ticks = 0
        elif self.state == STATE_STOPPED:
            self._stop_ticks += 1
            if self._stuck_ticks > 0:
                # In prolonged-stoppage mode — count down, ignore start_prob
                self._stuck_ticks -= 1
            elif self._stop_ticks < MIN_STOP_TICKS:
                # Enforce minimum downtime floor (12 min) so all events >10 min
                pass
            elif random.random() < 0.001:
                # 0.1% chance per stopped-tick to enter a prolonged fault (up to stuck_max ticks)
                self._stuck_ticks = random.randint(60, int(self._stuck_max))
            elif random.random() < self.start_prob:
                self.state = STATE_RUNNING

        ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        metrics = []

        # Machines (shape="admin", 5+ segment topics) publish StateCurrent at their own
        # topic path so oeecloud routes it to the machine's equipment entry, not the line's.
        # Lines (shape="status", 4-segment topics) publish at line_topic as before.
        # Without this, both machine and line write to the same metric path → dual-trigger
        # for the line equipment, causing spurious 6↔10 state cycling every tick.
        state_topic = self.topic if self.shape == "admin" else self.line_topic
        metrics.append({"name": f"{state_topic}/Status/StateCurrent",
                        "timestamp": ts_ms, "value": self.state})

        mode = MODE_PRODUCTION if self.state == STATE_RUNNING else MODE_MANUAL
        metrics.append({"name": f"{self.line_topic}/Status/UnitModeCurrent",
                        "timestamp": ts_ms, "value": mode})

        if self.state == STATE_RUNNING:
            speed = round(self.ideal_speed * random.uniform(0.85, 1.15), 2)
            incr  = max(0, int(speed * INTERVAL / 60 * random.uniform(0.9, 1.1)))
            scrap = 1 if random.random() < self.scrap_rate else 0

            self.counter   += incr
            self.scrap_ctr += scrap

            metrics.append({"name": self._metric_name("ProdProcessedCount"),
                            "timestamp": ts_ms, "value": incr,
                            "counter": self.counter, "curspeed": speed})

            if scrap:
                metrics.append({"name": self._metric_name("ProdDefectiveCount"),
                                "timestamp": ts_ms, "value": scrap,
                                "counter": self.scrap_ctr})

            metrics.append({"name": f"{self.line_topic}/Status/CurMachSpeed",
                            "timestamp": ts_ms, "value": int(speed)})
        else:
            # Publish speed=0 when stopped so dashboards reflect the actual state
            metrics.append({"name": f"{self.line_topic}/Status/CurMachSpeed",
                            "timestamp": ts_ms, "value": 0})

        return {"timestamp": ts_ms, "gateway": "simulator", "metrics": metrics}


def publish_machine_metrics(machines):
    """Tick every machine and POST each payload to edge-nodered /plc-data.

    One POST per machine keeps oeecloud's per-message parsing boundaries
    clean (one message = one topic's metrics in lockstep).  edge-nodered
    forwards the data through pack-queue → pubsub-out → oeecloud → DB.
    """
    url = f"{EDGE_NODERED_URL}/plc-data"
    for m in machines:
        payload = m.tick()
        if not payload["metrics"]:
            continue
        try:
            r = requests.post(url, json=payload, timeout=5)
            r.raise_for_status()
        except requests.exceptions.RequestException as e:
            log.warning("edge-nodered /plc-data failed: %s", e)
    log.debug("Published %d machine ticks to edge-nodered", len(machines))


# ── Operator simulation ───────────────────────────────────────────────────────

class OperatorSimulator:
    """Simulates operator activity for Simulator Corp against edge-api.

    Rotates through USERS round-robin so every user receives the same number
    of actions over time.  The action type is drawn randomly from _ACTIONS
    (weighted pool) so the mix of justify / manual / start / stop looks
    realistic on Grafana dashboards.

    Falls back gracefully when no suitable event or PO exists for an action
    (e.g. no open events → creates a manual event instead; no available PO →
    skips the start action silently).
    """

    def __init__(self):
        self._user_idx: int = 0
        self._ent: Any = None          # Simulator Corp row (RealDictRow), loaded on first act()
        self._next_id_order: int | None = None  # auto-incrementing PO id_order, seeded from DB on first use

    # ── DB queries ──────────────────────────────────────────────────────────

    def _load_enterprise(self, conn):
        with conn.cursor() as cur:
            cur.execute("""
                SELECT e.id_enterprise, e.api_key,
                       s.id_site, a.id_area
                FROM enterprises e
                JOIN sites  s ON s.id_enterprise = e.id_enterprise
                JOIN areas  a ON a.id_enterprise = e.id_enterprise
                WHERE e.nm_enterprise = %s
                LIMIT 1
            """, (SIMCORP_NAME,))
            return cur.fetchone()

    @staticmethod
    def _iso(dt) -> str:
        """Format datetime as millisecond-precision UTC ISO (matches JS toISOString)."""
        ms = dt.microsecond // 1000
        return dt.astimezone(timezone.utc).strftime(f"%Y-%m-%dT%H:%M:%S.{ms:03d}Z")

    def _justifiable_events(self, conn):
        """Real PLC stop events with no category — eligible for operator justification.

        Excludes forced_creation_system=true fixtures so the operator sim never
        consumes the guardian's test events.  Those are reserved for real developers
        manually testing the justify/split flows in the operator UI.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event, ee.id_equipment,
                       eq.nm_equipment
                FROM equipment_events ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.status = 10
                  AND (ee.cd_category IS NULL OR ee.cd_category = '')
                  AND ee.forced_creation_system = false
                ORDER BY ee.ts_event
                LIMIT 10
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _available_pos(self, conn):
        with conn.cursor() as cur:
            cur.execute("""
                SELECT po.id_production_order, po.id_equipment,
                       eq.id_site, eq.id_area
                FROM production_orders po
                JOIN equipments eq ON eq.id_equipment = po.id_equipment
                WHERE po.id_enterprise = %s AND po.status = 1
                  AND po.id_equipment NOT IN (
                    SELECT id_equipment FROM production_orders
                    WHERE id_enterprise = %s AND status = 2
                  )
                ORDER BY po.id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"], self._ent["id_enterprise"]))
            return cur.fetchall()

    def _running_pos(self, conn):
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id_production_order, id_equipment,
                       COALESCE(production_final, 0) AS qty
                FROM production_orders
                WHERE id_enterprise = %s AND status = 2
                ORDER BY id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _splittable_man_events(self, conn):
        """Closed manual downtime events eligible for split (equipment_events_man).

        Requires whole-second timestamps so the split service's integer-second
        duration arithmetic and timestamp string-equality check both pass.
        Returns rows tagged with source='man' so _split() picks the right endpoint.
        Category fields are included so _split() can inherit them for the first piece.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event AS id_event, ee.id_equipment,
                       ee.ts_event, ee.ts_end, ee.duration,
                       COALESCE(ee.cd_machine, eq.nm_equipment) AS machine_code,
                       ee.cd_category, ee.desc_category,
                       ee.cd_subcategory, ee.desc_subcategory,
                       ee.txt_downtime_notes,
                       'man' AS source
                FROM equipment_events_man ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.ts_end IS NOT NULL
                  AND ee.duration IS NOT NULL AND ee.duration > 60
                  AND ee.forced_creation_system = false
                  AND DATE_TRUNC('second', ee.ts_event) = ee.ts_event
                  AND DATE_TRUNC('second', ee.ts_end)   = ee.ts_end
                ORDER BY ee.ts_end DESC
                LIMIT 10
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _splittable_std_events(self, conn):
        """Closed standard downtime events eligible for split (equipment_events).

        The split service computes: sum(event_duration_ms)/1000 == original.duration.
        This is satisfied whenever (ts_end - ts_event) has no sub-second remainder —
        which is true when the fractional millisecond on both timestamps is identical
        (e.g. seeded data where both carry .892ms), or when both are whole seconds.
        Returns rows tagged with source='std' so _split() picks the right endpoint.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event AS id_event, ee.id_equipment,
                       ee.ts_event, ee.ts_end, ee.duration,
                       COALESCE(ee.cd_machine, eq.nm_equipment) AS machine_code,
                       ee.cd_category, ee.desc_category,
                       ee.cd_subcategory, ee.desc_subcategory,
                       ee.txt_downtime_notes,
                       'std' AS source
                FROM equipment_events ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.ts_end IS NOT NULL
                  AND ee.duration IS NOT NULL AND ee.duration > 60
                  AND ee.status != 6
                  AND EXTRACT(EPOCH FROM (ee.ts_end - ee.ts_event))::numeric %% 1 = 0
                ORDER BY ee.ts_end DESC
                LIMIT 10
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _closed_manual_events(self, conn):
        """Recently-closed manual downtime events (for edit simulation)."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event AS id_event, ee.id_equipment,
                       ee.ts_event, ee.ts_end,
                       COALESCE(ee.cd_machine, eq.nm_equipment) AS machine_code
                FROM equipment_events_man ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.ts_end IS NOT NULL
                  AND ee.forced_creation_system = false
                ORDER BY ee.ts_end DESC
                LIMIT 10
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _equipments(self, conn):
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id_equipment, nm_equipment
                FROM equipments
                WHERE id_enterprise = %s AND tp_equipment = 1
                ORDER BY id_equipment
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _free_equipments(self, conn):
        """Equipment with no currently running PO (safe to start on)."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id_equipment, nm_equipment
                FROM equipments
                WHERE id_enterprise = %s AND tp_equipment = 1
                  AND id_equipment NOT IN (
                    SELECT id_equipment FROM production_orders
                    WHERE id_enterprise = %s AND status = 2
                  )
                ORDER BY id_equipment
            """, (self._ent["id_enterprise"], self._ent["id_enterprise"]))
            return cur.fetchall()

    def _paused_pos(self, conn):
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id_production_order, id_equipment
                FROM production_orders
                WHERE id_enterprise = %s AND status = 4
                ORDER BY id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _running_pos_with_runtime(self, conn):
        """Running POs joined with their currently-open runtime row (for change-time)."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT po.id_production_order, po.id_equipment,
                       por.id_production_order_runtime,
                       lower(por.runtime_timerange) AS ts_start
                FROM production_orders po
                JOIN production_orders_runtime por
                  ON por.id_production_order = po.id_production_order
                 AND upper(por.runtime_timerange) IS NULL
                JOIN equipments eq ON eq.id_equipment = po.id_equipment
                WHERE po.id_enterprise = %s AND po.status = 2
                ORDER BY po.id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _available_pos_for_replace(self, conn):
        """Available POs on equipment that already has a running PO (for replace)."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT po.id_production_order, po.id_equipment
                FROM production_orders po
                WHERE po.id_enterprise = %s AND po.status = 1
                  AND po.id_equipment IN (
                    SELECT id_equipment FROM production_orders
                    WHERE id_enterprise = %s AND status = 2
                  )
                ORDER BY po.id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"], self._ent["id_enterprise"]))
            return cur.fetchall()

    def _running_pos_with_hierarchy(self, conn):
        """Running POs with equipment's site + area (for setup changeover)."""
        with conn.cursor() as cur:
            cur.execute("""
                SELECT po.id_production_order, po.id_equipment,
                       COALESCE(po.production_final, 0) AS qty,
                       eq.id_site, eq.id_area
                FROM production_orders po
                JOIN equipments eq ON eq.id_equipment = po.id_equipment
                WHERE po.id_enterprise = %s AND po.status = 2
                ORDER BY po.id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _alloc_id_order(self) -> int:
        """Return the next safe id_order for this session.

        Seeds from the current epoch-second so each simulator restart gets a
        fresh base — avoids collisions with POs created in previous sessions
        without requiring a DB query.
        """
        if self._next_id_order is None:
            self._next_id_order = int(time.time())
        assert self._next_id_order is not None
        val = self._next_id_order
        self._next_id_order += 1
        return val

    # ── HTTP helpers ─────────────────────────────────────────────────────────

    def _post(self, path, body, user) -> bool:
        params  = {"token": self._ent["api_key"],
                   "idEnterprise": self._ent["id_enterprise"]}
        headers = {"X-User": user, "Content-Type": "application/json"}
        try:
            r = requests.post(f"{EDGE_API_URL}{path}", json=body,
                              params=params, headers=headers, timeout=10)
            if r.status_code >= 400:
                log.warning("edge-api %s → %d %s", path, r.status_code, r.text[:200])
                return False
            return True
        except requests.exceptions.RequestException as e:
            log.warning("edge-api %s failed: %s", path, e)
            return False

    # ── Individual actions ────────────────────────────────────────────────────

    def _justify(self, conn, user) -> bool:
        events = self._justifiable_events(conn)
        if not events:
            return self._manual(conn, user)   # fallback when no events to justify
        ev                    = random.choice(events)
        cd, desc, sub, subdesc = random.choice(CATEGORIES)
        return self._post("/api/downtimes/justify", {
            "idEquipment":      ev["id_equipment"],
            "idEquipmentEvent": ev["id_equipment_event"],
            "cdMachine":        ev["nm_equipment"],
            "cdCategory":       cd,
            "descCategory":     desc,
            "cdSubcategory":    sub,
            "descSubcategory":  subdesc,
            "txtDowntimeNotes": f"Justified by {user}",
            "changeOver":       False,
            "idle":             "no",
            "plannedDowntime":  False,
        }, user)

    def _manual(self, conn, user) -> bool:
        eqs = self._equipments(conn)
        if not eqs:
            return False
        eq                    = random.choice(eqs)
        cd, desc, sub, subdesc = random.choice(CATEGORIES)
        # Zero microseconds so the event is splittable later (split service
        # requires integer-second duration; sub-second ts causes mismatch).
        now = datetime.now(timezone.utc).replace(microsecond=0)
        dur = random.randint(900, 3600)   # 15–60 min so events are visible and splittable
        return self._post("/api/downtimes/create-manual-event", {
            "idEnterprise":    self._ent["id_enterprise"],
            "idEquipment":     eq["id_equipment"],
            "cdMachine":       eq["nm_equipment"],
            "cdCategory":      cd,
            "descCategory":    desc,
            "cdSubcategory":   sub,
            "descSubcategory": subdesc,
            "txtDowntimeNotes": f"Manual entry by {user}",
            "tsEvent": self._iso(now - timedelta(seconds=dur)),
            "tsEnd":   self._iso(now),
        }, user)

    def _split(self, conn, user) -> bool:
        """Split a closed downtime event into two halves.

        Piece A inherits the original event's category/subcategory/notes if the
        event was already justified — matching real UI behaviour where the first
        child keeps the parent's classification.  Piece B always gets a fresh
        random category (simulating the operator filling in the new information).

        Draws from both equipment_events (standard PLC events, /api/downtimes/split)
        and equipment_events_man (manual events, /api/downtimes/split-manual-downtime).
        """
        candidates = self._splittable_man_events(conn) + self._splittable_std_events(conn)
        if not candidates:
            log.info("Operator %-20s split — skipped (no splittable events yet)", user)
            return False
        ev       = random.choice(candidates)
        source   = ev["source"]
        ts_start = ev["ts_event"].astimezone(timezone.utc)
        ts_end   = ev["ts_end"].astimezone(timezone.utc)
        total_secs = int((ts_end - ts_start).total_seconds())
        mid_secs   = total_secs // 2
        ts_mid     = ts_start + timedelta(seconds=mid_secs)
        machine    = ev["machine_code"] or "MCH"

        # Piece A: inherit original classification if the event was justified
        if ev["cd_category"]:
            cd_a    = ev["cd_category"]
            desc_a  = ev["desc_category"] or cd_a
            sub_a   = ev["cd_subcategory"] or ""
            sdesc_a = ev["desc_subcategory"] or ""
            note_a  = ev["txt_downtime_notes"] or f"Inherited — {user}"
        else:
            cd_a, desc_a, sub_a, sdesc_a = random.choice(CATEGORIES)
            note_a = f"Split A — {user}"

        # Piece B: always a fresh classification (user fills this in for real)
        cd_b, desc_b, sub_b, sdesc_b = random.choice(CATEGORIES)

        event_a = {
            "startTime":       self._iso(ts_start),
            "endTime":         self._iso(ts_mid),
            "machineCode":     machine,
            "categoryCode":    cd_a,
            "descCategory":    desc_a,
            "subcategoryCode": sub_a,
            "descSubcategory": sdesc_a,
            "note":            note_a,
            "changeOver":      False,
            "plannedDowntime": False,
            "idle":            "no",
        }
        event_b = {
            "startTime":       self._iso(ts_mid),
            "endTime":         self._iso(ts_end),
            "machineCode":     machine,
            "categoryCode":    cd_b,
            "descCategory":    desc_b,
            "subcategoryCode": sub_b,
            "descSubcategory": sdesc_b,
            "note":            f"Split B — {user}",
            "changeOver":      False,
            "plannedDowntime": False,
            "idle":            "no",
        }

        endpoint = "/api/downtimes/split" if source == "std" else "/api/downtimes/split-manual-downtime"
        return self._post(endpoint, {
            "idEquipmentEvent": ev["id_event"],
            "idEquipment":      ev["id_equipment"],
            "eventType":        "downtime",
            "events":           [event_a, event_b],
        }, user)

    def _edit_manual(self, conn, user) -> bool:
        """Re-categorise an existing closed manual downtime event."""
        events = self._closed_manual_events(conn)
        if not events:
            return False
        ev                    = random.choice(events)
        cd, desc, sub, subdesc = random.choice(CATEGORIES)
        machine               = ev["machine_code"] or "MCH"
        return self._post("/api/downtimes/edit-manual-event", {
            "idEquipmentEvent": ev["id_event"],
            "idEquipment":      ev["id_equipment"],
            "cdMachine":        machine,
            "cdCategory":       cd,
            "descCategory":     desc,
            "cdSubcategory":    sub,
            "descSubcategory":  subdesc,
            "txtDowntimeNotes": f"Corrected by {user}",
            "idle":             "no",
            "changeOver":       False,
            "plannedDowntime":  False,
            "start":            self._iso(ev["ts_event"].astimezone(timezone.utc)),
            "end":              self._iso(ev["ts_end"].astimezone(timezone.utc)),
        }, user)

    def _change_status_po(self, conn, user) -> bool:
        """Move a paused PO to finished (the only direction change-status supports)."""
        pos = self._paused_pos(conn)
        if not pos:
            log.info("Operator %-20s change-status — skipped (no paused POs)", user)
            return False
        po = random.choice(pos)
        return self._post("/api/production-orders/change-status", {
            "idProductionOrder": po["id_production_order"],
            "idEquipment":       po["id_equipment"],
        }, user)

    def _change_time_po(self, conn, user) -> bool:
        """Shift the start of a running PO's open runtime.

        Safe strategy: find the latest ts_end of any OTHER closed runtime on the
        same equipment (the one that logically precedes this open slot), then set
        new_start = that_end + 10–30s.  This is always conflict-free because no
        other closed runtime can fall between that_end and ∞ on the same equipment
        — if one did, it would already conflict with the current open range.

        When there are no preceding closed runtimes (equipment's first PO), we
        nudge the current start slightly forward (later → smaller window, safe).
        Both cases are guarded: new_start must be at least 1 minute before now.
        """
        pos = self._running_pos_with_runtime(conn)
        if not pos:
            log.info("Operator %-20s change-time — skipped (no running POs with runtime)", user)
            return False
        po = random.choice(pos)

        # Find the floor: latest upper-bound of ANY other closed runtime on this equipment
        with conn.cursor() as cur:
            cur.execute("""
                SELECT MAX(upper(runtime_timerange)) AS floor
                FROM production_orders_runtime
                WHERE id_equipment = %s
                  AND upper(runtime_timerange) IS NOT NULL
                  AND id_production_order_runtime <> %s
            """, (po["id_equipment"], po["id_production_order_runtime"]))
            row = cur.fetchone()

        now = datetime.now(timezone.utc)
        if row and row["floor"]:
            floor_dt  = row["floor"].astimezone(timezone.utc)
            new_start = floor_dt + timedelta(seconds=random.randint(10, 30))
        else:
            ts_start  = po["ts_start"].astimezone(timezone.utc)
            new_start = ts_start + timedelta(minutes=random.randint(1, 3))

        if new_start >= now - timedelta(minutes=1):
            log.info("Operator %-20s change-time — skipped (no safe time slot)", user)
            return False

        return self._post("/api/production-orders/change-time", {
            "idProductionOrderRuntime": po["id_production_order_runtime"],
            "idProductionOrder":        po["id_production_order"],
            "idEquipment":              po["id_equipment"],
            "start":                    self._iso(new_start),
        }, user)

    def _replace_po(self, conn, user) -> bool:
        """Reassign the most recent runtime slot on an equipment to a different PO.

        replace needs an available PO on an equipment that already has a running PO.
        Since available POs are consumed quickly, we first create one on a running
        equipment if none exists, then immediately call replace to swap it in.
        """
        # Pick a running PO's equipment to target
        running = self._running_pos(conn)
        if not running:
            log.info("Operator %-20s replace — skipped (no running POs)", user)
            return False
        po_running = random.choice(running)
        id_equip   = po_running["id_equipment"]

        # Check if there's already an available PO on that equipment
        with conn.cursor() as cur:
            cur.execute("""
                SELECT po.id_production_order
                FROM production_orders po
                WHERE po.id_enterprise = %s AND po.id_equipment = %s AND po.status = 1
                LIMIT 1
            """, (self._ent["id_enterprise"], id_equip))
            avail = cur.fetchone()

        if not avail:
            # Create an available PO on that equipment first
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT eq.id_site, eq.id_area
                    FROM equipments eq WHERE eq.id_equipment = %s
                """, (id_equip,))
                eq = cur.fetchone()
            if not eq:
                return False
            id_order_int    = self._alloc_id_order()
            product, client = random.choice(PRODUCTS)
            ok = self._post("/api/production-orders/create", {
                "idEnterprise":            self._ent["id_enterprise"],
                "idSite":                  eq["id_site"],
                "idArea":                  eq["id_area"],
                "idEquipment":             id_equip,
                "idOrder":                 id_order_int,
                "nmProductionOrder":       product,
                "txtProductionOrderNotes": client,
                "productionOrderQuantity": random.randint(500, 3000),
            }, user)
            if not ok:
                return False
            # Re-fetch the newly created available PO
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT id_production_order FROM production_orders
                    WHERE id_enterprise = %s AND id_equipment = %s AND status = 1
                    ORDER BY id_production_order DESC LIMIT 1
                """, (self._ent["id_enterprise"], id_equip))
                avail = cur.fetchone()
            if not avail:
                return False

        return self._post("/api/production-orders/replace", {
            "idEnterprise":      self._ent["id_enterprise"],
            "idEquipment":       id_equip,
            "idProductionOrder": avail["id_production_order"],
        }, user)

    def _setup_po(self, conn, user) -> bool:
        """Changeover: stop the running PO and immediately start a fresh one.

        shouldOpenNewPo=True + shouldCreatePo=True → the service stops the old
        PO, inserts a new production_orders row, and starts it.  This exercises
        the full setup path without requiring a pre-created available PO.
        """
        pos = self._running_pos_with_hierarchy(conn)
        if not pos:
            log.info("Operator %-20s setup — skipped (no running POs)", user)
            return False
        po              = random.choice(pos)
        id_order_int    = self._alloc_id_order()
        qty             = random.randint(500, 5000)
        product, client = random.choice(PRODUCTS)
        return self._post("/api/production-orders/setup", {
            "timestamp":                   datetime.now(timezone.utc).isoformat(),
            "shouldOpenNewPo":             True,
            "stopType":                    "finish",
            "idEnterprise":                self._ent["id_enterprise"],
            "idSite":                      po["id_site"],
            "idArea":                      po["id_area"],
            "idEquipment":                 po["id_equipment"],
            "shouldCreatePo":              True,
            "oldIdProductionOrder":        po["id_production_order"],
            "oldProductionOrderProdFinal": int(po["qty"]),
            "idOrder":                     id_order_int,
            "nmProductionOrder":           product,
            "txtProductionOrderNotes":     client,
            "productionOrderQuantity":     qty,
        }, user)

    def _create_and_start_po(self, conn, user) -> bool:
        """Create a fresh PO and start it immediately (no pre-existing status=1 row needed).

        Called when _start_po finds no available POs.  Only targets equipment with
        no running PO — if all equipment are busy, skips silently instead of
        sending a guaranteed-400 request.
        """
        eqs = self._free_equipments(conn)
        if not eqs:
            log.info("Operator %-20s start — skipped (all equipment busy)", user)
            return False
        # Pick from products not already running, shuffled for uniqueness within batch.
        available     = self._available_products(conn)
        products_pool = random.sample(available, len(available))
        ok = False
        for i, eq in enumerate(eqs):
            id_order_int    = self._alloc_id_order()
            qty             = random.randint(500, 5000)
            product, client = products_pool[i % len(products_pool)]
            result = self._post("/api/production-orders/create-and-start", {
                "idEnterprise":            self._ent["id_enterprise"],
                "idSite":                  self._ent["id_site"],
                "idArea":                  self._ent["id_area"],
                "idEquipment":             eq["id_equipment"],
                "idOrder":                 id_order_int,
                "nmProductionOrder":       product,
                "txtProductionOrderNotes": client,
                "productionOrderQuantity": qty,
                "timestamp":               datetime.now(timezone.utc).isoformat(),
            }, user)
            ok = ok or result
        return ok

    def _available_products(self, conn) -> list:
        """Products not currently running on any machine in this enterprise.

        Prevents two machines from showing the same product simultaneously —
        which confuses the operator UI into looking like the same PO.
        Falls back to the full PRODUCTS list if every product is already in use.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT COALESCE(id_order_text, id_production_order::text) AS nm
                FROM production_orders
                WHERE id_enterprise = %s AND status = 2
            """, (self._ent["id_enterprise"],))
            running = {row["nm"] for row in cur.fetchall()}
        available = [p for p in PRODUCTS if p[0] not in running]
        return available if available else list(PRODUCTS)

    def _ensure_machines_running(self, conn) -> None:
        """Guardian: start POs on any idle machine without consuming an operator action slot.

        Runs on a separate AUTO_INTERVAL timer.  Guarantees no machine sits idle
        for more than ~30s regardless of what the random operator-action draw picks.
        Excludes products already running on other machines so the UI shows
        distinct products per machine.
        """
        free = self._free_equipments(conn)
        if not free:
            return
        available     = self._available_products(conn)
        products_pool = random.sample(available, len(available))
        for i, eq in enumerate(free):
            product, client = products_pool[i % len(products_pool)]
            id_order_int    = self._alloc_id_order()
            ok = self._post("/api/production-orders/create-and-start", {
                "idEnterprise":            self._ent["id_enterprise"],
                "idSite":                  self._ent["id_site"],
                "idArea":                  self._ent["id_area"],
                "idEquipment":             eq["id_equipment"],
                "idOrder":                 id_order_int,
                "nmProductionOrder":       product,
                "txtProductionOrderNotes": client,
                "productionOrderQuantity": random.randint(500, 5000),
                "timestamp":               datetime.now(timezone.utc).isoformat(),
            }, GUARDIAN_USER)
            if ok:
                log.info("Guardian              started PO on %s — %s", eq["nm_equipment"], product)

    def _auto_justifiable_events(self, conn):
        """Unjustified PLC stop events eligible for rule-engine auto-categorisation.

        Excludes forced_creation_system events — those are synthetic test fixtures
        that must remain unjustified so developers can manually test the justify flow.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event, ee.id_equipment,
                       eq.nm_equipment
                FROM equipment_events ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.status = 10
                  AND (ee.cd_category IS NULL OR ee.cd_category = '')
                  AND ee.forced_creation_system = false
                  AND ee.ts_end IS NOT NULL
                ORDER BY ee.ts_event
                LIMIT 10
            """, (self._ent["id_enterprise"],))
            return cur.fetchall()

    def _auto_justify_events(self, conn) -> None:
        """Rule-engine: auto-justify a fraction of real PLC stop events.

        Only touches forced_creation_system=false events (real PLC stops).
        Forced test fixtures are left alone so developers always have events
        to manually justify in the operator UI.
        """
        events = self._auto_justifiable_events(conn)
        count  = 0
        for ev in events:
            if random.random() > AUTO_JUSTIFY_PROB:
                continue
            cd, desc, sub, subdesc = random.choice(AUTO_CATEGORIES)
            ok = self._post("/api/downtimes/justify", {
                "idEquipment":      ev["id_equipment"],
                "idEquipmentEvent": ev["id_equipment_event"],
                "cdMachine":        ev["nm_equipment"],
                "cdCategory":       cd,
                "descCategory":     desc,
                "cdSubcategory":    sub,
                "descSubcategory":  subdesc,
                "txtDowntimeNotes": "Auto-categorized by rule engine",
                "changeOver":       False,
                "idle":             "no",
                "plannedDowntime":  False,
            }, AUTO_USER)
            if ok:
                count += 1
        if count:
            log.info("Auto-processor         %d event(s) auto-justified", count)

    def guardian_act(self, conn) -> None:
        """Per-tick guardian: restart any idle machine within one PLC cycle (5s).

        Runs on every tick — the query is cheap (one SELECT + one POST per free
        machine) and the idle window must be shorter than the operator stop rate.
        """
        if self._ent is None:
            self._ent = self._load_enterprise(conn)
            if not self._ent:
                return
        try:
            self._ensure_machines_running(conn)
        except Exception as e:
            log.warning("Guardian failed: %s", e)

    def _ensure_pending_events(self, conn) -> None:
        """Guardian: seed unjustified events so developers always have ≥PENDING_MIN to work with.

        First removes closed unjustified events shorter than the minimum stop
        duration (simulator artifacts predating MIN_STOP_TICKS), then refills
        the backlog to PENDING_MIN with properly long events.
        Called after _auto_justify_events so the backlog is replenished each sweep.
        """
        min_dur = MIN_STOP_TICKS * INTERVAL  # seconds
        with conn.cursor() as cur:
            cur.execute("""
                DELETE FROM equipment_events
                WHERE id_enterprise = %s
                  AND status = 10
                  AND (cd_category IS NULL OR cd_category = '')
                  AND ts_end IS NOT NULL
                  AND (duration IS NULL OR duration < %s)
            """, (self._ent["id_enterprise"], min_dur))
            deleted = cur.rowcount
        if deleted:
            log.info("Guardian: removed %d short unjustified event(s) (duration < %ds)",
                     deleted, min_dur)

        with conn.cursor() as cur:
            cur.execute("""
                SELECT COUNT(*) AS cnt
                FROM equipment_events
                WHERE id_enterprise = %s
                  AND status = 10
                  AND (cd_category IS NULL OR cd_category = '')
            """, (self._ent["id_enterprise"],))
            cnt = cur.fetchone()["cnt"]

        needed = PENDING_MIN - cnt
        if needed <= 0:
            return

        eqs = self._equipments(conn)
        if not eqs:
            return

        now    = datetime.now(timezone.utc).replace(microsecond=0)
        seeded = 0
        with conn.cursor() as cur:
            for _ in range(needed):
                eq  = random.choice(eqs)
                dur = random.randint(720, 3600)   # 12–60 min; always >10 min
                # Place events 3–8 hours ago so they never land inside an active PO window
                offset   = random.randint(10800, 28800)
                ts_end   = now - timedelta(seconds=offset)
                ts_event = ts_end - timedelta(seconds=dur)
                cur.execute("""
                    INSERT INTO equipment_events
                        (ts_event, id_enterprise, id_equipment, status,
                         ts_end, duration, cd_machine, forced_creation_system)
                    VALUES (%s, %s, %s, 10, %s, %s, %s, true)
                    ON CONFLICT (id_equipment, ts_event) DO NOTHING
                """, (ts_event, self._ent["id_enterprise"],
                      eq["id_equipment"], ts_end, dur, eq["nm_equipment"]))
                seeded += 1

        if seeded:
            log.info("Guardian: seeded %d pending event(s) (backlog was %d/%d)",
                     seeded, cnt, PENDING_MIN)

    def auto_act(self, conn) -> None:
        """Periodic rule-engine sweep: auto-justify pending events (every 30s)."""
        if self._ent is None:
            self._ent = self._load_enterprise(conn)
            if not self._ent:
                return
        try:
            self._auto_justify_events(conn)
            # Replenish after the justify sweep so the net backlog stays ≥ PENDING_MIN
            self._ensure_pending_events(conn)
        except Exception as e:
            log.warning("Auto-action failed: %s", e)

    def _start_po(self, conn, user) -> bool:
        """Start an existing available PO, or create-and-start a fresh one when the pool is empty."""
        pos = self._available_pos(conn)
        if not pos:
            return self._create_and_start_po(conn, user)
        po = random.choice(pos)
        return self._post("/api/production-orders/start", {
            "timestamp":         datetime.now(timezone.utc).isoformat(),
            "idEnterprise":      self._ent["id_enterprise"],
            "idSite":            po["id_site"],
            "idArea":            po["id_area"],
            "idEquipment":       po["id_equipment"],
            "idProductionOrder": po["id_production_order"],
        }, user)

    def _stop_po(self, conn, user) -> bool:
        """Stop a running PO — finish (75%) or pause (25%) to mix status=3 and status=4 events."""
        pos = self._running_pos(conn)
        if not pos:
            return False
        po        = random.choice(pos)
        stop_type = random.choices(["finish", "pause"], weights=[75, 25])[0]
        return self._post("/api/production-orders/stop", {
            "timestamp":               datetime.now(timezone.utc).isoformat(),
            "stopType":                stop_type,
            "idEnterprise":            self._ent["id_enterprise"],
            "idEquipment":             po["id_equipment"],
            "idProductionOrder":       po["id_production_order"],
            "productionOrderQuantity": int(po["qty"]),
        }, user)

    # ── Public interface ──────────────────────────────────────────────────────

    def act(self, conn):
        """Perform one operator action for the next user in the rotation."""
        if self._ent is None:
            self._ent = self._load_enterprise(conn)
            if not self._ent:
                log.warning("Simulator Corp not found — operator sim idle")
                return

        user   = USERS[self._user_idx % len(USERS)]
        self._user_idx += 1
        action = random.choice(_ACTIONS)

        try:
            if action == "justify":
                ok = self._justify(conn, user)
            elif action == "manual":
                ok = self._manual(conn, user)
            elif action == "start":
                ok = self._start_po(conn, user)
            elif action == "stop":
                ok = self._stop_po(conn, user)
            elif action == "split":
                ok = self._split(conn, user)
            elif action == "change_status":
                ok = self._change_status_po(conn, user)
            elif action == "change_time":
                ok = self._change_time_po(conn, user)
            elif action == "replace":
                ok = self._replace_po(conn, user)
            elif action == "setup":
                ok = self._setup_po(conn, user)
            else:
                ok = self._edit_manual(conn, user)
            if ok:
                log.info("Operator %-20s %s", user, action)
        except Exception as e:
            log.warning("Operator action failed (user=%s action=%s): %s", user, action, e)


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    log.info("Simulator starting (PLC tick=%ds, operator action=%ds)",
             INTERVAL, OP_INTERVAL)
    log.info("  PLC target  : %s", EDGE_NODERED_URL)
    log.info("  API target  : %s", EDGE_API_URL)

    for _ in range(30):
        try:
            conn = get_conn()
            break
        except Exception as e:
            log.warning("DB not ready (%s), retrying...", e)
            time.sleep(5)
    else:
        log.error("Could not connect to DB after 30 attempts")
        sys.exit(1)

    topics = load_plc_topics(conn)
    if not topics:
        log.error("No active packml_register topics found — DB not seeded?")
        sys.exit(1)

    machines = []
    by_enterprise = {}
    for t in topics:
        prof = ENTERPRISE_PROFILES.get(t["nm_enterprise"], DEFAULT_PROFILE)
        machines.append(MachineState(
            t["packml_topic"], prof,
            id_unit=t.get("id_unit") or t["id_equipment"],
            cd_machine=t["nm_equipment"] or "MCH",
        ))
        by_enterprise.setdefault(t["nm_enterprise"], 0)
        by_enterprise[t["nm_enterprise"]] += 1

    log.info("PLC simulation: %d machines across %d enterprises",
             len(machines), len(by_enterprise))
    for ent, n in sorted(by_enterprise.items()):
        log.info("  %-20s %d topics", ent, n)

    op_sim     = OperatorSimulator()
    op_ticks   = max(1, OP_INTERVAL  // INTERVAL)
    auto_ticks = max(1, AUTO_INTERVAL // INTERVAL)
    op_counter   = 0
    auto_counter = 0

    log.info("Operator simulation: %d users, action every %d ticks (%ds)",
             len(USERS), op_ticks, op_ticks * INTERVAL)
    log.info("Auto-processor: rule-engine every %d ticks (%ds); guardian every tick",
             auto_ticks, auto_ticks * INTERVAL)

    while True:
        try:
            try:
                conn.cursor().execute("SELECT 1")
            except Exception:
                conn = get_conn()

            publish_machine_metrics(machines)

            # Guardian fires every tick — machines never idle for more than 5s
            op_sim.guardian_act(conn)

            op_counter += 1
            if op_counter >= op_ticks:
                op_counter = 0
                op_sim.act(conn)

            auto_counter += 1
            if auto_counter >= auto_ticks:
                auto_counter = 0
                op_sim.auto_act(conn)

        except Exception as e:
            log.error("Tick error: %s", e, exc_info=True)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
