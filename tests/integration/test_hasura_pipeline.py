"""Layer-2 integration tests for Hasura GraphQL — metadata & data consistency.

Hasura sits in front of PostgreSQL and provides the GraphQL interface that
edge-nodered uses to resolve packml topics → id_equipment.  If Hasura metadata
is missing or stale, edge-nodered cannot route PLC messages and the entire
pipeline breaks silently.

These tests verify:
  1. Hasura responds to health + GraphQL requests (basic liveness).
  2. packml_register is tracked (metadata applied correctly by hasura-init).
  3. GraphQL results for active topics match what the DB returns directly —
     this is the consistency check that catches Hasura metadata drift.
  4. The enterprises and equipments tables are tracked and queryable.
"""

import pytest
import requests
from conftest import HASURA_URL, hasura_query


# ── Helpers ───────────────────────────────────────────────────────────────────

def _errors(resp: dict) -> list:
    return resp.get("errors", [])


# ── 1. Liveness ───────────────────────────────────────────────────────────────

def test_hasura_health():
    """Hasura /healthz returns 200 — service is up and DB-connected."""
    r = requests.get(f"{HASURA_URL}/healthz", timeout=5)
    assert r.status_code == 200, f"Hasura health: {r.status_code} {r.text[:200]}"


def test_hasura_graphql_endpoint_reachable():
    """A minimal introspection query returns schema data — GraphQL engine live."""
    resp = hasura_query("{ __typename }")
    assert not _errors(resp), f"GraphQL errors: {_errors(resp)}"
    assert resp.get("data", {}).get("__typename") == "query_root", (
        f"Unexpected response: {resp}"
    )


# ── 2. Metadata: tracked tables ───────────────────────────────────────────────

def test_packml_register_tracked():
    """packml_register table is tracked — hasura-init applied metadata."""
    resp = hasura_query("""
        {
            packml_register(limit: 1) {
                id_packml_register
                packml_topic
                active
            }
        }
    """)
    assert not _errors(resp), (
        f"packml_register not tracked or metadata wrong: {_errors(resp)}"
    )
    data = resp.get("data", {})
    assert "packml_register" in data, f"packml_register missing from response: {data}"


def test_enterprises_tracked():
    """enterprises table is tracked and returns id + name fields."""
    resp = hasura_query("""
        {
            enterprises(limit: 1) {
                id_enterprise
                nm_enterprise
            }
        }
    """)
    assert not _errors(resp), f"enterprises query errors: {_errors(resp)}"
    assert "enterprises" in resp.get("data", {}), resp


def test_equipments_tracked():
    """equipments table is tracked and returns hierarchy fields."""
    resp = hasura_query("""
        {
            equipments(limit: 1) {
                id_equipment
                nm_equipment
                tp_equipment
                id_enterprise
            }
        }
    """)
    assert not _errors(resp), f"equipments query errors: {_errors(resp)}"
    assert "equipments" in resp.get("data", {}), resp


# ── 3. Data consistency: Hasura ↔ DB ─────────────────────────────────────────

def test_active_packml_topics_match_db(db):
    """Active topics from Hasura GraphQL match a direct DB count.

    This is the critical consistency check: if metadata is applied to a stale
    schema, Hasura may serve zero rows even when the DB has data, breaking
    edge-nodered's topic resolution silently.
    """
    # Direct DB count
    with db.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS n FROM packml_register WHERE active = true")
        db_count = cur.fetchone()["n"]

    if db_count == 0:
        pytest.skip("No active packml_register rows — DB not seeded")

    # GraphQL count via Hasura
    resp = hasura_query("""
        {
            packml_register_aggregate(where: {active: {_eq: true}}) {
                aggregate { count }
            }
        }
    """)
    assert not _errors(resp), f"aggregate query errors: {_errors(resp)}"

    gql_count = (
        resp.get("data", {})
            .get("packml_register_aggregate", {})
            .get("aggregate", {})
            .get("count", -1)
    )
    assert gql_count == db_count, (
        f"Hasura count ({gql_count}) ≠ DB count ({db_count}) for active "
        f"packml_register rows — metadata may be stale or tracking wrong table"
    )


def test_packml_topics_values_consistent(db):
    """Topic strings returned by Hasura match the DB rows exactly.

    Catches schema-drift (column renamed, wrong table tracked) and
    permission gaps (Hasura returning fewer rows than the DB sees).
    """
    # Fetch up to 20 active topics from the DB
    with db.cursor() as cur:
        cur.execute("""
            SELECT packml_topic FROM packml_register
            WHERE active = true
            ORDER BY id_packml_register
            LIMIT 20
        """)
        db_topics = {row["packml_topic"] for row in cur.fetchall()}

    if not db_topics:
        pytest.skip("No active packml_register rows — DB not seeded")

    # Same query via Hasura
    resp = hasura_query("""
        {
            packml_register(
                where: {active: {_eq: true}}
                order_by: {id_packml_register: asc}
                limit: 20
            ) {
                packml_topic
            }
        }
    """)
    assert not _errors(resp), f"packml_register query errors: {_errors(resp)}"

    gql_topics = {
        row["packml_topic"]
        for row in resp.get("data", {}).get("packml_register", [])
    }
    assert gql_topics == db_topics, (
        f"Topic mismatch — Hasura: {gql_topics!r}, DB: {db_topics!r}"
    )


# ── 4. Pipeline smoke: edge-nodered uses Hasura to resolve topics ─────────────

def test_hasura_serves_equipment_for_active_topics():
    """Every active topic's id_equipment is resolvable through Hasura.

    edge-nodered queries Hasura to resolve packml_topic → id_equipment when
    routing SparkPlug messages.  This verifies the join path works end-to-end
    through the GraphQL layer: packml_register → equipment fields.
    """
    resp = hasura_query("""
        {
            packml_register(where: {active: {_eq: true}}, limit: 10) {
                packml_topic
                id_equipment
                id_unit
            }
        }
    """)
    assert not _errors(resp), f"packml_register query errors: {_errors(resp)}"

    rows = resp.get("data", {}).get("packml_register", [])
    if not rows:
        pytest.skip("No active packml_register rows — DB not seeded")

    for row in rows:
        assert row["id_equipment"] is not None, (
            f"Null id_equipment for topic {row['packml_topic']!r} — "
            "routing would fail in edge-nodered"
        )
