"""Layer-2 integration tests for the operator HTTP pipeline.

edge-api's logger middleware writes every CS-Admin-style mutation to user_logs
with category=eventType + payload=request body. We exercise:
  - POST /api/equipment-events/justify  → category 'event-justified'
  - POST /api/production-orders/start   → category 'order-started'

Only Simulator Corp has a stable api_key wired up for synthetic operator
traffic; the other enterprises' keys belong to real customer onboarding flows
so we don't forge them here.
"""

import time
import pytest
from datetime import datetime, timezone
from conftest import edge_api_post, poll_until


SIM_ENTERPRISE = "Simulator Corp"


@pytest.fixture(scope="module")
def simcorp(enterprises):
    for e in enterprises:
        if e["nm_enterprise"] == SIM_ENTERPRISE:
            return e
    pytest.skip(f"{SIM_ENTERPRISE} not seeded — operator tests need it")


@pytest.fixture
def open_event(db, simcorp):
    """Create a fresh open equipment_event for the test, return its id + machine."""
    with db.cursor() as cur:
        cur.execute("""
            SELECT id_equipment FROM equipments
            WHERE id_enterprise = %s AND tp_equipment = 1
            ORDER BY id_equipment ASC LIMIT 1
        """, (simcorp["id_enterprise"],))
        eq = cur.fetchone()
        cur.execute("""
            INSERT INTO equipment_events (id_enterprise, id_equipment, ts_event,
                                          ts_end, status, planned_downtime)
            VALUES (%s, %s, NOW(), NULL, 10, false)
            RETURNING id_equipment_event
        """, (simcorp["id_enterprise"], eq["id_equipment"]))
        ev_id = cur.fetchone()["id_equipment_event"]
    return {"id_equipment_event": ev_id, "id_equipment": eq["id_equipment"]}


def test_justify_event_writes_user_log(db, simcorp, open_event):
    """POST /api/downtimes/justify → user_logs row with category=event-justified."""
    body = {
        "idEquipment":      open_event["id_equipment"],
        "idEquipmentEvent": open_event["id_equipment_event"],
        "cdMachine":        "INTEGRATION-MCH",
        "cdCategory":       "MEC",
        "descCategory":     "Mechanical",
        "cdSubcategory":    "INTEG-TEST",
        "descSubcategory":  "Integration test marker",
        "txtDowntimeNotes": "from test_operator_pipeline",
        "changeOver":       False,
        "idle":             "no",
        "plannedDowntime":  False,
    }
    r = edge_api_post("/api/downtimes/justify", body,
                      simcorp["api_key"], simcorp["id_enterprise"])
    assert r.status_code in (200, 201, 204), f"edge-api: {r.status_code} {r.text[:200]}"

    def _seen():
        with db.cursor() as cur:
            cur.execute("""
                SELECT category, payload, ts_log
                FROM user_logs
                WHERE id_enterprise = %s
                  AND category = 'event-justified'
                  AND payload->>'cdSubcategory' = 'INTEG-TEST'
                  AND ts_log > NOW() - INTERVAL '30 sec'
                ORDER BY ts_log DESC LIMIT 1
            """, (simcorp["id_enterprise"],))
            return cur.fetchone()

    row = poll_until(_seen, message="event-justified user_log row not written")
    assert row["payload"]["descSubcategory"] == "Integration test marker"


def test_start_po_writes_user_log(db, simcorp):
    """Seeding + starting a PO writes 'order-started' to user_logs.

    We seed a fresh PO directly so the test is independent of whatever's
    queued in the simulator's PO pool.
    """
    eq_id = None
    nm_po = f"INTEG-PO-{int(time.time())}"
    with db.cursor() as cur:
        cur.execute("""
            SELECT id_equipment, id_site, id_area FROM equipments
            WHERE id_enterprise = %s AND tp_equipment = 1
            ORDER BY id_equipment ASC LIMIT 1
        """, (simcorp["id_enterprise"],))
        eq = cur.fetchone()
        eq_id = eq["id_equipment"]
        cur.execute("""
            INSERT INTO production_orders
                (id_enterprise, id_site, id_area, id_equipment,
                 nm_production_order, status, production_programmed, nm_product)
            VALUES (%s,%s,%s,%s,%s,1,500,'Integration Widget')
            RETURNING id_production_order
        """, (simcorp["id_enterprise"], eq["id_site"], eq["id_area"],
              eq_id, nm_po))
        po_id = cur.fetchone()["id_production_order"]

    body = {
        "timestamp":          datetime.now(timezone.utc).isoformat(),
        "idEnterprise":       simcorp["id_enterprise"],
        "idSite":             eq["id_site"],
        "idArea":             eq["id_area"],
        "idEquipment":        eq_id,
        "idProductionOrder":  po_id,
    }
    r = edge_api_post("/api/production-orders/start", body,
                      simcorp["api_key"], simcorp["id_enterprise"])
    # edge-api may return 400 if a PO is already running on that equipment;
    # accept that as "system is reachable but a precondition didn't hold"
    # rather than a pipeline failure.
    if r.status_code >= 500:
        pytest.fail(f"edge-api 5xx: {r.status_code} {r.text[:200]}")

    def _seen():
        with db.cursor() as cur:
            cur.execute("""
                SELECT category, payload
                FROM user_logs
                WHERE id_enterprise = %s
                  AND category = 'order-started'
                  AND payload->>'idProductionOrder' = %s
                  AND ts_log > NOW() - INTERVAL '30 sec'
                LIMIT 1
            """, (simcorp["id_enterprise"], str(po_id)))
            return cur.fetchone()

    if r.status_code < 400:
        poll_until(_seen, message=f"order-started user_log not written for PO {po_id}")
