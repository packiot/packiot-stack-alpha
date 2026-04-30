#!/usr/bin/env python3
"""
PLC Simulator — sends SparkPlug-style metric bursts to edge-node-red.

Reads every active packml_register topic from the DB, creates one MachineState
per topic, and POSTs metric payloads to edge-nodered's /plc-data endpoint on
every tick.  edge-nodered forwards the data through pack-queue → pubsub-out →
oeecloud → DB, exercising the full E2E ingestion pipeline.

Operator actions (start/stop PO, justify events) are NOT simulated here;
those belong to the operator UI layer and to test_operator_pipeline.py.

Env vars (with defaults):
  EDGE_NODERED_URL   http://edge-nodered:1880
  DB_URL             postgresql://postgres:packiot@postgres:5432/packiot
  SIM_INTERVAL       5    (seconds between PLC ticks)
"""

import os
import sys
import time
import json
import random
import logging
import psycopg2
import psycopg2.extras
import requests
from datetime import datetime, timezone

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("sim")

EDGE_NODERED_URL = os.environ.get("EDGE_NODERED_URL", "http://edge-nodered:1880")
DB_URL           = os.environ.get("DB_URL", "postgresql://postgres:packiot@postgres:5432/packiot")
INTERVAL         = int(os.environ.get("SIM_INTERVAL", "5"))

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


# ── Database helpers ──────────────────────────────────────────────────────────

def get_conn():
    return psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)


def load_plc_topics(conn):
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
        return cur.fetchall()


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


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    log.info("Simulator starting (PLC-only, tick=%ds, target=%s)", INTERVAL, EDGE_NODERED_URL)

    for attempt in range(30):
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

    log.info("PLC simulation: %d machines across %d enterprises → edge-nodered → PubSub",
             len(machines), len(by_enterprise))
    for ent, n in sorted(by_enterprise.items()):
        log.info("  %-20s %d topics", ent, n)

    while True:
        try:
            try:
                conn.cursor().execute("SELECT 1")
            except Exception:
                conn = get_conn()

            publish_machine_metrics(machines)
        except Exception as e:
            log.error("Tick error: %s", e, exc_info=True)

        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
