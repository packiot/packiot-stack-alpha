"""Pytest fixtures for the packiot-stack-alpha integration tests.

These tests target the live compose stack — they assert end-to-end behaviour:
inject a SparkPlug-style payload via edge-nodered /plc-data → see the row land
in equipment_values, hit edge-api → see user_logs filled in, etc.
They are NOT unit tests.

The fixtures here read env vars that the `tests` compose service sets (or the
host-side defaults that match `make up` port mappings), so the same code runs
both inside docker (`make test-integration`) and from the host.
"""

import os
import time
import requests
import psycopg2
import psycopg2.extras
import pytest


# ── connection details (overridable for host-side runs) ──────────────────────

PG_DSN           = os.environ.get("DB_URL",
                                  "postgresql://postgres:packiot@localhost:5433/packiot")
EDGE_NODERED_URL = os.environ.get("EDGE_NODERED_URL", "http://localhost:1880")
EDGE_API_URL     = os.environ.get("EDGE_API_URL",     "http://localhost:8080")
POLL_TIMEOUT     = float(os.environ.get("INT_POLL_TIMEOUT", "30"))
POLL_INTERVAL    = float(os.environ.get("INT_POLL_INTERVAL", "1"))


# ── fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def db():
    """Session-scoped Postgres connection (RealDictCursor for ergonomics)."""
    conn = psycopg2.connect(PG_DSN, cursor_factory=psycopg2.extras.RealDictCursor)
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def enterprises(db):
    """Inventory of enterprises seeded in the running stack."""
    with db.cursor() as cur:
        cur.execute("""
            SELECT id_enterprise, nm_enterprise, api_key
            FROM enterprises ORDER BY id_enterprise
        """)
        return cur.fetchall()


@pytest.fixture(scope="session")
def packml_topics(db):
    """All active topics → equipment mapping. Used to pick a real machine
    per enterprise so we can publish a PLC message that the pipeline routes."""
    with db.cursor() as cur:
        cur.execute("""
            SELECT pr.packml_topic, pr.id_equipment, eq.nm_equipment,
                   eq.tp_equipment, e.id_enterprise, e.nm_enterprise
            FROM packml_register pr
            JOIN equipments  eq ON eq.id_equipment = pr.id_equipment
            JOIN enterprises e  ON e.id_enterprise = eq.id_enterprise
            WHERE pr.active = true
            ORDER BY pr.id_packml_register
        """)
        return cur.fetchall()


# ── helpers (importable by tests) ────────────────────────────────────────────

def publish_sparkplug(topic: str, metrics: list, gateway: str = "test") -> str:
    """Inject a SparkPlug-style payload into edge-nodered via POST /plc-data.

    edge-nodered forwards it through pack-queue → pubsub-out → oeecloud → DB,
    exercising the full E2E ingestion path (not a PubSub shortcut).

    The metric `name` shape — first 4-5 segments — is how oeecloud resolves
    id_equipment, so we prepend the topic exactly as the simulator does.
    """
    ts_ms = int(time.time() * 1000)
    for m in metrics:
        m.setdefault("timestamp", ts_ms)
        m["name"] = f"{topic}/{m['name']}"
    payload = {"timestamp": ts_ms, "gateway": gateway, "metrics": metrics}
    r = requests.post(f"{EDGE_NODERED_URL}/plc-data", json=payload, timeout=5)
    r.raise_for_status()
    return "injected"


def poll_until(predicate, *, timeout=None, interval=None, message=""):
    """Spin on `predicate()` returning a truthy value within timeout.

    Returns the predicate's value. Raises pytest.fail with `message` on timeout
    so failures show what we were waiting for, not just "AssertionError".
    """
    timeout = timeout if timeout is not None else POLL_TIMEOUT
    interval = interval if interval is not None else POLL_INTERVAL
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    pytest.fail(f"Timed out after {timeout}s: {message} (last value: {last!r})")


def edge_api_post(path: str, body: dict, api_key: str, enterprise_id: int,
                  user: str = "integration.test"):
    """POST to edge-api with the same params shape the simulator uses."""
    r = requests.post(
        f"{EDGE_API_URL}{path}",
        json=body,
        params={"token": api_key, "idEnterprise": enterprise_id},
        headers={"X-User": user, "Content-Type": "application/json"},
        timeout=15,
    )
    return r
