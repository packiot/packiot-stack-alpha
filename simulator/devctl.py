#!/usr/bin/env python3
"""
devctl — Manual operator control for packiot-stack-alpha.

A dev-facing interactive CLI that lets you trigger any operator action
against edge-api as a special 'dev.user' identity, independent of the
running simulator.  Useful for testing specific flows without waiting
for the simulator to randomly pick the action you care about.

Usage (from host — needs localhost ports exposed):
  python simulator/devctl.py

Env vars:
  EDGE_API_URL  http://localhost:8080    (or http://edge-api:8080 inside Docker)
  DB_URL        postgresql://postgres:packiot@localhost:5432/packiot
  DEV_USER      dev.user
  ENTERPRISE    Simulator Corp
"""

import os
import sys
import random
import textwrap
import psycopg2
import psycopg2.extras
import requests
from datetime import datetime, timezone, timedelta

EDGE_API_URL = os.environ.get("EDGE_API_URL", "http://localhost:8080")
DB_URL       = os.environ.get("DB_URL", "postgresql://postgres:packiot@localhost:5432/packiot")
DEV_USER     = os.environ.get("DEV_USER", "dev.user")
ENT_NAME     = os.environ.get("ENTERPRISE", "Simulator Corp")

CATEGORIES = [
    ("MEC", "Mechanical", "JAM",      "Conveyor jam"),
    ("ELE", "Electrical", "SENSOR",   "Sensor fault"),
    ("OP",  "Operator",   "SETUP",    "Setup time"),
    ("QUA", "Quality",    "REWORK",   "Product rework"),
    ("MAT", "Material",   "SHORTAGE", "Material shortage"),
]

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


# ── Helpers ───────────────────────────────────────────────────────────────────

def _iso(dt) -> str:
    ms = dt.microsecond // 1000
    return dt.astimezone(timezone.utc).strftime(f"%Y-%m-%dT%H:%M:%S.{ms:03d}Z")

def _wo() -> str:
    today = datetime.now(timezone.utc).strftime("%y%m%d")
    return f"WO-{today}-{random.randint(1, 999):03d}"

def _c(text, code="0"):
    return f"\033[{code}m{text}\033[0m"

def header(title):
    print(f"\n{_c('═'*60, '34')}")
    print(f"  {_c(title, '1;37')}")
    print(f"{_c('═'*60, '34')}")

def pick(items, label, display=None):
    """Numbered picker. display(item) → string. Returns chosen item or None."""
    if not items:
        print(f"  {_c('(none)', '33')}")
        return None
    for i, item in enumerate(items, 1):
        text = display(item) if display else str(item)
        print(f"  [{_c(str(i), '1;36')}] {text}")
    raw = input(f"\n{label} (1-{len(items)}, Enter=cancel): ").strip()
    if not raw:
        return None
    try:
        idx = int(raw) - 1
        if 0 <= idx < len(items):
            return items[idx]
    except ValueError:
        pass
    print(_c("  Invalid choice.", "31"))
    return None

def pick_category():
    print("\n  Downtime categories:")
    for i, (cd, desc, sub, subdesc) in enumerate(CATEGORIES, 1):
        print(f"    [{_c(str(i), '1;36')}] {desc} / {subdesc}")
    raw = input("  Category (1-5, Enter=random): ").strip()
    if not raw:
        return random.choice(CATEGORIES)
    try:
        idx = int(raw) - 1
        if 0 <= idx < len(CATEGORIES):
            return CATEGORIES[idx]
    except ValueError:
        pass
    return random.choice(CATEGORIES)

def pick_product():
    print("\n  Products:")
    for i, (prod, client) in enumerate(PRODUCTS, 1):
        print(f"    [{_c(str(i), '1;36')}] {prod}  ({client})")
    raw = input("  Product (1-8, Enter=random): ").strip()
    if not raw:
        return random.choice(PRODUCTS)
    try:
        idx = int(raw) - 1
        if 0 <= idx < len(PRODUCTS):
            return PRODUCTS[idx]
    except ValueError:
        pass
    return random.choice(PRODUCTS)


# ── State loading ─────────────────────────────────────────────────────────────

def load_state(conn, ent):
    eid = ent["id_enterprise"]
    with conn.cursor() as cur:
        cur.execute("""
            SELECT po.id_production_order, po.id_equipment,
                   po.nm_production_order, po.production_programmed,
                   po.ts_start, eq.nm_equipment,
                   por.id_production_order_runtime,
                   lower(por.runtime_timerange) AS rt_start
            FROM production_orders po
            JOIN equipments eq ON eq.id_equipment = po.id_equipment
            LEFT JOIN production_orders_runtime por
              ON por.id_production_order = po.id_production_order
             AND upper(por.runtime_timerange) IS NULL
            WHERE po.id_enterprise = %s AND po.status = 2
            ORDER BY po.id_production_order
        """, (eid,))
        running = cur.fetchall()

        cur.execute("""
            SELECT po.id_production_order, po.id_equipment,
                   po.nm_production_order, po.production_programmed,
                   eq.nm_equipment
            FROM production_orders po
            JOIN equipments eq ON eq.id_equipment = po.id_equipment
            WHERE po.id_enterprise = %s AND po.status = 1
            ORDER BY po.id_production_order LIMIT 10
        """, (eid,))
        available = cur.fetchall()

        cur.execute("""
            SELECT po.id_production_order, po.id_equipment,
                   po.nm_production_order, eq.nm_equipment
            FROM production_orders po
            JOIN equipments eq ON eq.id_equipment = po.id_equipment
            WHERE po.id_enterprise = %s AND po.status = 4
            ORDER BY po.id_production_order LIMIT 5
        """, (eid,))
        paused = cur.fetchall()

        cur.execute("""
            SELECT ee.id_equipment_event, ee.id_equipment,
                   eq.nm_equipment, ee.ts_event, ee.cd_category, ee.duration
            FROM equipment_events ee
            JOIN equipments eq ON eq.id_equipment = ee.id_equipment
            WHERE ee.id_enterprise = %s AND ee.status = 10
              AND (ee.ts_end IS NULL OR ee.forced_creation_system = true)
            ORDER BY ee.ts_event LIMIT 10
        """, (eid,))
        events = cur.fetchall()

        cur.execute("""
            SELECT id_equipment, nm_equipment
            FROM equipments
            WHERE id_enterprise = %s AND tp_equipment = 1
              AND id_equipment NOT IN (
                SELECT id_equipment FROM production_orders
                WHERE id_enterprise = %s AND status = 2
              )
            ORDER BY id_equipment
        """, (eid, eid))
        free_eqs = cur.fetchall()

        cur.execute("""
            SELECT id_equipment, nm_equipment
            FROM equipments
            WHERE id_enterprise = %s AND tp_equipment = 1
            ORDER BY id_equipment
        """, (eid,))
        all_eqs = cur.fetchall()

    return dict(running=running, available=available, paused=paused,
                events=events, free_eqs=free_eqs, all_eqs=all_eqs)


def print_state(state):
    def ago(ts):
        if not ts:
            return ""
        diff = datetime.now(timezone.utc) - ts.astimezone(timezone.utc)
        m = int(diff.total_seconds() // 60)
        return f"{m}m ago"

    header("Current State")

    print(f"\n  {_c('Running POs', '1;32')}:")
    if state["running"]:
        for r in state["running"]:
            name = r["nm_production_order"] or f"PO-{r['id_production_order']}"
            qty  = int(r["production_programmed"] or 0)
            print(f"    PO {_c(str(r['id_production_order']), '1;37')} "
                  f"│ {r['nm_equipment']:<16} │ {name:<20} │ qty={qty} │ {ago(r['ts_start'])}")
    else:
        print(f"    {_c('(none)', '33')}")

    print(f"\n  {_c('Available POs', '1;34')}:")
    if state["available"]:
        for a in state["available"]:
            name = a["nm_production_order"] or f"PO-{a['id_production_order']}"
            qty  = int(a["production_programmed"] or 0)
            print(f"    PO {_c(str(a['id_production_order']), '1;37')} "
                  f"│ {a['nm_equipment']:<16} │ {name:<20} │ qty={qty}")
    else:
        print(f"    {_c('(none)', '33')}")

    print(f"\n  {_c('Paused POs', '1;33')}:")
    if state["paused"]:
        for p in state["paused"]:
            name = p["nm_production_order"] or f"PO-{p['id_production_order']}"
            print(f"    PO {_c(str(p['id_production_order']), '1;37')} "
                  f"│ {p['nm_equipment']:<16} │ {name}")
    else:
        print(f"    {_c('(none)', '33')}")

    print(f"\n  {_c('Pending Events', '1;31')}:")
    if state["events"]:
        for ev in state["events"]:
            cat  = ev["cd_category"] or _c("unjustified", "33")
            dur  = f"{ev['duration']}s" if ev["duration"] else "open"
            print(f"    Event {_c(str(ev['id_equipment_event']), '1;37')} "
                  f"│ {ev['nm_equipment']:<16} │ {cat:<12} │ {dur}")
    else:
        print(f"    {_c('(none)', '33')}")

    print(f"\n  {_c('Free Equipment', '90')} (no running PO): "
          + ", ".join(e["nm_equipment"] for e in state["free_eqs"]) or "(all busy)")


# ── API calls ─────────────────────────────────────────────────────────────────

class DevCtl:
    def __init__(self, ent):
        self._ent = ent

    def _post(self, path, body) -> bool:
        params  = {"token": self._ent["api_key"],
                   "idEnterprise": self._ent["id_enterprise"]}
        headers = {"X-User": DEV_USER, "Content-Type": "application/json"}
        try:
            r = requests.post(f"{EDGE_API_URL}{path}", json=body,
                              params=params, headers=headers, timeout=10)
            if r.status_code >= 400:
                print(_c(f"  ✗ {path} → {r.status_code}: {r.text[:200]}", "31"))
                return False
            print(_c(f"  ✓ {path} → {r.status_code}", "32"))
            return True
        except requests.exceptions.RequestException as e:
            print(_c(f"  ✗ {path} failed: {e}", "31"))
            return False

    # ── Actions ───────────────────────────────────────────────────────────────

    def start_po(self, state):
        """Start an existing available PO."""
        if not state["available"]:
            print(_c("  No available POs. Use 'create+start' instead.", "33"))
            return
        po = pick(state["available"], "Pick PO to start",
                  lambda p: f"PO-{p['id_production_order']} │ {p['nm_equipment']} │ {p['nm_production_order'] or '(unnamed)'}")
        if not po:
            return
        self._post("/api/production-orders/start", {
            "timestamp":         datetime.now(timezone.utc).isoformat(),
            "idEnterprise":      self._ent["id_enterprise"],
            "idSite":            po["id_site"] if "id_site" in po else self._ent["id_site"],
            "idArea":            po["id_area"] if "id_area" in po else self._ent["id_area"],
            "idEquipment":       po["id_equipment"],
            "idProductionOrder": po["id_production_order"],
        })

    def create_and_start(self, state):
        """Create a new PO and start it immediately on a free machine."""
        if not state["free_eqs"]:
            print(_c("  All machines have running POs.", "33"))
            return
        eq = pick(state["free_eqs"], "Pick machine",
                  lambda e: e["nm_equipment"])
        if not eq:
            return
        product, client = pick_product()
        raw = input(f"  Target quantity (Enter={random.randint(500,5000)}): ").strip()
        qty = int(raw) if raw.isdigit() else random.randint(500, 5000)
        self._post("/api/production-orders/create-and-start", {
            "idEnterprise":            self._ent["id_enterprise"],
            "idSite":                  self._ent["id_site"],
            "idArea":                  self._ent["id_area"],
            "idEquipment":             eq["id_equipment"],
            "idOrder":                 _wo(),
            "nmProductionOrder":       product,
            "txtProductionOrderNotes": client,
            "productionOrderQuantity": qty,
            "timestamp":               datetime.now(timezone.utc).isoformat(),
        })

    def stop_po(self, state):
        """Stop a running PO (finish or pause)."""
        if not state["running"]:
            print(_c("  No running POs.", "33"))
            return
        po = pick(state["running"], "Pick PO to stop",
                  lambda p: f"PO-{p['id_production_order']} │ {p['nm_equipment']} │ {p['nm_production_order'] or '(unnamed)'}")
        if not po:
            return
        stop_type = input("  Stop type — [f]inish / [p]ause (Enter=finish): ").strip().lower()
        stop_type = "pause" if stop_type == "p" else "finish"
        self._post("/api/production-orders/stop", {
            "timestamp":               datetime.now(timezone.utc).isoformat(),
            "stopType":                stop_type,
            "idEnterprise":            self._ent["id_enterprise"],
            "idEquipment":             po["id_equipment"],
            "idProductionOrder":       po["id_production_order"],
            "productionOrderQuantity": int(po["production_programmed"] or 0),
        })

    def justify(self, state):
        """Justify a pending downtime event."""
        if not state["events"]:
            print(_c("  No pending events.", "33"))
            return
        ev = pick(state["events"], "Pick event to justify",
                  lambda e: f"Event {e['id_equipment_event']} │ {e['nm_equipment']} │ {e['cd_category'] or 'unjustified'}")
        if not ev:
            return
        cd, desc, sub, subdesc = pick_category()
        self._post("/api/downtimes/justify", {
            "idEquipment":      ev["id_equipment"],
            "idEquipmentEvent": ev["id_equipment_event"],
            "cdMachine":        ev["nm_equipment"],
            "cdCategory":       cd,
            "descCategory":     desc,
            "cdSubcategory":    sub,
            "descSubcategory":  subdesc,
            "txtDowntimeNotes": f"Justified by {DEV_USER}",
            "changeOver":       False,
            "idle":             "no",
            "plannedDowntime":  False,
        })

    def manual_event(self, state):
        """Create a manual downtime event."""
        eq = pick(state["all_eqs"], "Pick machine",
                  lambda e: e["nm_equipment"])
        if not eq:
            return
        cd, desc, sub, subdesc = pick_category()
        raw = input("  Duration in seconds (Enter=300): ").strip()
        dur = int(raw) if raw.isdigit() else 300
        now = datetime.now(timezone.utc).replace(microsecond=0)
        self._post("/api/downtimes/create-manual-event", {
            "idEnterprise":    self._ent["id_enterprise"],
            "idEquipment":     eq["id_equipment"],
            "cdMachine":       eq["nm_equipment"],
            "cdCategory":      cd,
            "descCategory":    desc,
            "cdSubcategory":   sub,
            "descSubcategory": subdesc,
            "txtDowntimeNotes": f"Manual entry by {DEV_USER}",
            "tsEvent": _iso(now - timedelta(seconds=dur)),
            "tsEnd":   _iso(now),
        })

    def finish_paused(self, state):
        """Move a paused PO to finished."""
        if not state["paused"]:
            print(_c("  No paused POs.", "33"))
            return
        po = pick(state["paused"], "Pick paused PO to finish",
                  lambda p: f"PO-{p['id_production_order']} │ {p['nm_equipment']}")
        if not po:
            return
        self._post("/api/production-orders/change-status", {
            "idProductionOrder": po["id_production_order"],
            "idEquipment":       po["id_equipment"],
        })

    def changeover(self, state):
        """Stop a running PO and immediately start a new one (setup/changeover)."""
        if not state["running"]:
            print(_c("  No running POs.", "33"))
            return
        po = pick(state["running"], "Pick PO to change over FROM",
                  lambda p: f"PO-{p['id_production_order']} │ {p['nm_equipment']}")
        if not po:
            return
        product, client = pick_product()
        raw = input(f"  New PO quantity (Enter=random): ").strip()
        qty = int(raw) if raw.isdigit() else random.randint(500, 5000)

        # Fetch hierarchy for this equipment
        with psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor) as conn2:
            with conn2.cursor() as cur:
                cur.execute("SELECT id_site, id_area FROM equipments WHERE id_equipment = %s",
                            (po["id_equipment"],))
                eq = cur.fetchone()
        if not eq:
            print(_c("  Equipment not found.", "31"))
            return
        self._post("/api/production-orders/setup", {
            "timestamp":                   datetime.now(timezone.utc).isoformat(),
            "shouldOpenNewPo":             True,
            "stopType":                    "finish",
            "idEnterprise":                self._ent["id_enterprise"],
            "idSite":                      eq["id_site"],
            "idArea":                      eq["id_area"],
            "idEquipment":                 po["id_equipment"],
            "shouldCreatePo":              True,
            "oldIdProductionOrder":        po["id_production_order"],
            "oldProductionOrderProdFinal": int(po["production_programmed"] or 0),
            "idOrder":                     _wo(),
            "nmProductionOrder":           product,
            "txtProductionOrderNotes":     client,
            "productionOrderQuantity":     qty,
        })


# ── REPL ──────────────────────────────────────────────────────────────────────

MENU = textwrap.dedent("""\

  Actions:
    [1] Start available PO       [2] Create + start new PO
    [3] Stop running PO          [4] Changeover (stop + new PO)
    [5] Justify event            [6] Create manual event
    [7] Finish paused PO
    [r] Refresh state            [q] Quit
""")

def main():
    print(_c("\n  PackIOT DevCtl", "1;34"))
    print(f"  API : {EDGE_API_URL}")
    print(f"  DB  : {DB_URL}")
    print(f"  User: {_c(DEV_USER, '1;33')}")

    conn = psycopg2.connect(DB_URL, cursor_factory=psycopg2.extras.RealDictCursor)
    with conn.cursor() as cur:
        cur.execute("""
            SELECT e.id_enterprise, e.api_key, s.id_site, a.id_area
            FROM enterprises e
            JOIN sites  s ON s.id_enterprise = e.id_enterprise
            JOIN areas  a ON a.id_enterprise = e.id_enterprise
            WHERE e.nm_enterprise = %s LIMIT 1
        """, (ENT_NAME,))
        ent = cur.fetchone()

    if not ent:
        print(_c(f"\n  Enterprise '{ENT_NAME}' not found. Set ENTERPRISE env var.", "31"))
        sys.exit(1)

    print(f"  Ent : {_c(ENT_NAME, '1;32')} (id={ent['id_enterprise']})\n")

    ctl   = DevCtl(ent)
    state = load_state(conn, ent)
    print_state(state)

    while True:
        print(MENU)
        try:
            cmd = input("  > ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\n  Bye.")
            break

        if cmd == "q":
            print("  Bye.")
            break
        elif cmd == "r":
            state = load_state(conn, ent)
            print_state(state)
        elif cmd == "1":
            # Need id_site/id_area on the po rows — re-query with join
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT po.id_production_order, po.id_equipment,
                           po.nm_production_order, po.production_programmed,
                           eq.nm_equipment, eq.id_site, eq.id_area
                    FROM production_orders po
                    JOIN equipments eq ON eq.id_equipment = po.id_equipment
                    WHERE po.id_enterprise = %s AND po.status = 1
                    ORDER BY po.id_production_order LIMIT 10
                """, (ent["id_enterprise"],))
                avail = list(cur.fetchall())
            old = state["available"]
            state["available"] = avail
            ctl.start_po(state)
            state["available"] = old
            state = load_state(conn, ent)
        elif cmd == "2":
            ctl.create_and_start(state)
            state = load_state(conn, ent)
        elif cmd == "3":
            ctl.stop_po(state)
            state = load_state(conn, ent)
        elif cmd == "4":
            ctl.changeover(state)
            state = load_state(conn, ent)
        elif cmd == "5":
            ctl.justify(state)
            state = load_state(conn, ent)
        elif cmd == "6":
            ctl.manual_event(state)
            state = load_state(conn, ent)
        elif cmd == "7":
            ctl.finish_paused(state)
            state = load_state(conn, ent)
        else:
            print(_c("  Unknown command.", "33"))

        print_state(state)


if __name__ == "__main__":
    main()
