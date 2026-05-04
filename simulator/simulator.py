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

# PackML states / modes
STATE_RUNNING, STATE_STOPPED = 6, 10
MODE_PRODUCTION, MODE_MANUAL = 1, 3

# Per-enterprise PLC profile — drives speed/scrap/downtime variability so
# dashboards see realistic diversity across enterprises.
ENTERPRISE_PROFILES = {
    "Dev Enterprise":    dict(ideal_speed=120, scrap_rate=0.03, stop_prob=0.06, start_prob=0.30),
    "Demo Factory":      dict(ideal_speed=120, scrap_rate=0.06, stop_prob=0.10, start_prob=0.35),
    "AutoParts Corp":    dict(ideal_speed=80,  scrap_rate=0.02, stop_prob=0.05, start_prob=0.25),
    "FoodCo Industries": dict(ideal_speed=200, scrap_rate=0.04, stop_prob=0.07, start_prob=0.30),
    "Simulator Corp":    dict(ideal_speed=120, scrap_rate=0.04, stop_prob=0.08, start_prob=0.25),
}
DEFAULT_PROFILE = dict(ideal_speed=120, scrap_rate=0.03, stop_prob=0.07, start_prob=0.25)

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

# Action type pool — drawn with replacement; each action appears in proportion.
# justify (35 %) > manual (20 %) > start-PO (18 %) > stop-PO (12 %) > split (10 %) > edit (5 %)
_ACTIONS = (
    ["justify"]      * 35 +
    ["manual"]       * 20 +
    ["start"]        * 18 +
    ["stop"]         * 12 +
    ["split"]        * 10 +
    ["edit_manual"]  *  5
)


# ── Database helpers ──────────────────────────────────────────────────────────

def get_conn():
    return psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)


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
        self.ideal_speed = profile["ideal_speed"] * random.uniform(0.85, 1.15)
        self.scrap_rate  = profile["scrap_rate"]
        self.stop_prob   = profile["stop_prob"]
        self.start_prob  = profile["start_prob"]
        self.state       = STATE_RUNNING
        self.counter     = 0
        self.scrap_ctr   = 0

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
        elif self.state == STATE_STOPPED and random.random() < self.start_prob:
            self.state = STATE_RUNNING

        ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        metrics = []

        metrics.append({"name": f"{self.line_topic}/Status/StateCurrent",
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
        """Standard events eligible for justify/re-categorisation in equipment_events.

        Includes:
        - Open (ongoing) events with no ts_end — the classic case
        - Closed split children (forced_creation_system=true, status=10/stopped) —
          after a split the operator can still re-categorise each piece

        JustifyService accepts any event where status == stopped (10).  Split
        children inherit the original event's status so they qualify.
        Manual split children (equipment_events_man) are intentionally excluded:
        edit-manual-event rejects adjacent timestamps, which is always the case
        for split pieces sharing a boundary.
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_event, ee.id_equipment,
                       eq.nm_equipment
                FROM equipment_events ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.status = 10
                  AND (
                    ee.ts_end IS NULL
                    OR ee.forced_creation_system = true
                  )
                ORDER BY ee.ts_event
                LIMIT 15
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
                ORDER BY po.id_production_order
                LIMIT 5
            """, (self._ent["id_enterprise"],))
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
        """
        with conn.cursor() as cur:
            cur.execute("""
                SELECT ee.id_equipment_events_man AS id_event, ee.id_equipment,
                       ee.ts_event, ee.ts_end, ee.duration,
                       COALESCE(ee.cd_machine, eq.nm_equipment) AS machine_code,
                       'man' AS source
                FROM equipment_events_man ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.ts_end IS NOT NULL
                  AND ee.duration IS NOT NULL AND ee.duration > 120
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
                       'std' AS source
                FROM equipment_events ee
                JOIN equipments eq ON eq.id_equipment = ee.id_equipment
                WHERE ee.id_enterprise = %s
                  AND ee.ts_end IS NOT NULL
                  AND ee.duration IS NOT NULL AND ee.duration > 120
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
                SELECT ee.id_equipment_events_man AS id_event, ee.id_equipment,
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

    def _alloc_id_order(self, conn) -> int:
        """Return the next safe id_order, initialised once from MAX(id_order) in the DB."""
        if self._next_id_order is None:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COALESCE(MAX(id_order), 1000) + 1 "
                    "FROM production_orders WHERE id_enterprise = %s",
                    (self._ent["id_enterprise"],),
                )
                self._next_id_order = int(cur.fetchone()[0])
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
        dur = random.randint(130, 900)   # >120 so new events pass the split filter
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
        """Split a closed downtime event into two halves with different categories.

        Draws from both equipment_events (standard PLC events, /api/downtimes/split)
        and equipment_events_man (manual events, /api/downtimes/split-manual-downtime).
        The standard events DTO requires an 'idle' field; the manual one does not.
        """
        candidates = self._splittable_man_events(conn) + self._splittable_std_events(conn)
        if not candidates:
            log.info("Operator %-20s split — skipped (no splittable events yet)", user)
            return False
        ev       = random.choice(candidates)
        source   = ev["source"]
        duration = ev["duration"]
        mid_secs = duration // 2
        ts_start = ev["ts_event"].astimezone(timezone.utc)
        ts_mid   = ts_start + timedelta(seconds=mid_secs)
        ts_end   = ev["ts_end"].astimezone(timezone.utc)
        machine  = ev["machine_code"] or "MCH"
        cd1, desc1, sub1, sdesc1 = random.choice(CATEGORIES)
        cd2, desc2, sub2, sdesc2 = random.choice(CATEGORIES)

        event_a = {
            "startTime":       self._iso(ts_start),
            "endTime":         self._iso(ts_mid),
            "machineCode":     machine,
            "categoryCode":    cd1,
            "descCategory":    desc1,
            "subcategoryCode": sub1,
            "descSubcategory": sdesc1,
            "note":            f"Split A — {user}",
            "changeOver":      False,
            "plannedDowntime": False,
        }
        event_b = {
            "startTime":       self._iso(ts_mid),
            "endTime":         self._iso(ts_end),
            "machineCode":     machine,
            "categoryCode":    cd2,
            "descCategory":    desc2,
            "subcategoryCode": sub2,
            "descSubcategory": sdesc2,
            "note":            f"Split B — {user}",
            "changeOver":      False,
            "plannedDowntime": False,
        }

        event_a["idle"] = "no"
        event_b["idle"] = "no"
        if source == "std":
            endpoint = "/api/downtimes/split"
        else:
            endpoint = "/api/downtimes/split-manual-downtime"

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

    def _create_and_start_po(self, conn, user) -> bool:
        """Create a fresh PO and start it immediately (no pre-existing status=1 row needed).

        Called when _start_po finds no available POs — keeps the PO lifecycle
        flowing continuously so "Production Orders Started/Stopped per Hour" always
        has data regardless of how long the simulator has been running.
        """
        eqs = self._equipments(conn)
        if not eqs:
            return False
        eq       = random.choice(eqs)
        id_order = self._alloc_id_order(conn)
        qty      = random.randint(500, 5000)
        return self._post("/api/production-orders/create-and-start", {
            "idEnterprise":            self._ent["id_enterprise"],
            "idSite":                  self._ent["id_site"],
            "idArea":                  self._ent["id_area"],
            "idEquipment":             eq["id_equipment"],
            "idOrder":                 id_order,
            "productionOrderQuantity": qty,
            "timestamp":               datetime.now(timezone.utc).isoformat(),
        }, user)

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

    op_sim    = OperatorSimulator()
    op_ticks  = max(1, OP_INTERVAL // INTERVAL)   # PLC ticks between each operator action
    op_counter = 0

    log.info("Operator simulation: %d users, action every %d ticks (%ds)",
             len(USERS), op_ticks, op_ticks * INTERVAL)

    while True:
        try:
            try:
                conn.cursor().execute("SELECT 1")
            except Exception:
                conn = get_conn()

            publish_machine_metrics(machines)

            op_counter += 1
            if op_counter >= op_ticks:
                op_counter = 0
                op_sim.act(conn)

        except Exception as e:
            log.error("Tick error: %s", e, exc_info=True)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
