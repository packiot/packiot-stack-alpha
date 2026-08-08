"""Ephemeral-Postgres harness for the W2 Superset per-tenant isolation GATE.

This is the NON-NEGOTIABLE gate (docs/plans/w2-embedded-superset.md §8): it stands
up a throwaway Postgres, seeds TWO enterprises' data, applies the REAL shipped
`db/superset/01-superset-ro-role.sql` + `02-tenant-rls.sql`, then proves — as the
NOBYPASSRLS `superset_ro` login role, reading the curated `bi.*` views — that:

  * a session stamped `SET app.tenant_id = <A>` sees ONLY tenant A's rows,
  * stamped `<B>` sees ONLY B's rows,
  * UNSET sees ZERO rows (fail-closed),
  * a wrong-tenant WHERE clause (the guest-token-clause shape) is ALSO blocked,
  * the two tenants' row-sets are DISJOINT and partition the data,

and that every `bi.*` view carries `id_enterprise` and every base table under it
has an RLS policy (the "no view without a rule" guard).

It is DB-layer ground truth for tenant isolation — it needs no running Superset,
so it runs in CI on a bare Postgres container. The full end-to-end guest-token
mint against a live Superset is the STAGING acceptance step (spec §6.1 step 11);
this gate is what blocks a merge.

Runs against an ephemeral `docker run postgres:16` by default. Set
SUPERSET_TEST_PG_DSN to a THROWAWAY superuser DSN to reuse an existing server
(the harness DROPs its roles/schema on teardown). If neither docker nor a DSN is
available the whole module SKIPS (never a false green — see the CI job, which
fails if the collected test count is zero).
"""

import os
import socket
import subprocess
import time
import uuid
from pathlib import Path

import psycopg2
import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = REPO_ROOT / "db" / "superset"

# Two tenants with deliberately non-adjacent ids so an off-by-one can't pass.
TENANT_A = 101
TENANT_B = 202
RO_PASSWORD = "isolation_gate_ro_pw"  # test-only; never a production credential


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _docker_available() -> bool:
    try:
        subprocess.run(
            ["docker", "info"], capture_output=True, timeout=10, check=True
        )
        return True
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


def _wait_ready(dsn: str, timeout: float = 45.0) -> None:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            psycopg2.connect(dsn).close()
            return
        except psycopg2.OperationalError as exc:  # not up yet
            last = exc
            time.sleep(1.0)
    raise RuntimeError(f"Postgres never became ready: {last}")


# ── minimal analytics base schema (only the columns the bi.* views read) ──────
_BASE_SCHEMA = """
CREATE TABLE equipments (
    id_enterprise int  NOT NULL,
    id_equipment  int  PRIMARY KEY,
    nm_equipment  text NOT NULL,
    tp_equipment  int  NOT NULL DEFAULT 1,
    id_area       int,
    lead_machine  int,
    active        boolean NOT NULL DEFAULT true
);
CREATE TABLE equipment_runtime_shift (
    id_equipment     int  NOT NULL,
    id_shift         int  NOT NULL,
    begin_time       timestamptz NOT NULL,
    end_time         timestamptz NOT NULL,
    oee              numeric, oee_availability numeric,
    oee_performance  numeric, oee_quality numeric,
    count numeric, gross numeric, running_time numeric
);
CREATE TABLE equipment_runtime_1hour (
    id_equipment int NOT NULL,
    bucket       timestamptz NOT NULL,
    oee numeric, oee_availability numeric,
    oee_performance numeric, oee_quality numeric,
    count numeric, gross numeric, running_time numeric
);
CREATE TABLE production_orders_runtime (
    id_enterprise       int NOT NULL,
    id_production_order int NOT NULL,
    id_equipment        int NOT NULL,
    oee numeric, oee_availability numeric,
    oee_performance numeric, oee_quality numeric,
    count numeric, gross numeric,
    begin_time timestamptz, end_time timestamptz
);
CREATE TABLE downtimes (
    id_downtime        int PRIMARY KEY,
    id_equipment       int NOT NULL,
    id_downtime_reason int,
    begin_time timestamptz, end_time timestamptz,
    duration numeric
);
"""


def _drop_roles(cur):
    """Drop the gate's roles if present. Role names are hardcoded constants, so
    the f-strings carry no injection surface (and psycopg2 can't param a rolname)."""
    for role in ("superset_ro", "bi_owner"):
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,))
        if cur.fetchone():
            cur.execute(f"DROP OWNED BY {role} CASCADE")
            cur.execute(f"DROP ROLE {role}")


def _seed_tenant(cur, ent: int, equip_ids: list[int], base_po: int, base_dt: int):
    for eq in equip_ids:
        cur.execute(
            "INSERT INTO equipments (id_enterprise,id_equipment,nm_equipment,tp_equipment,id_area,lead_machine,active)"
            " VALUES (%s,%s,%s,1,%s,%s,true)",
            (ent, eq, f"EQ-{eq}", ent, eq),
        )
        cur.execute(
            "INSERT INTO equipment_runtime_shift (id_equipment,id_shift,begin_time,end_time,oee,oee_availability,oee_performance,oee_quality,count,gross,running_time)"
            " VALUES (%s,1,now()-interval '8h',now(),0.8,0.9,0.95,0.93,100,110,7.2)",
            (eq,),
        )
        cur.execute(
            "INSERT INTO equipment_runtime_1hour (id_equipment,bucket,oee,oee_availability,oee_performance,oee_quality,count,gross,running_time)"
            " VALUES (%s,date_trunc('hour',now()),0.8,0.9,0.95,0.93,20,22,0.9)",
            (eq,),
        )
        cur.execute(
            "INSERT INTO downtimes (id_downtime,id_equipment,id_downtime_reason,begin_time,end_time,duration)"
            " VALUES (%s,%s,7,now()-interval '1h',now(),3600)",
            (base_dt + eq, eq),
        )
    cur.execute(
        "INSERT INTO production_orders_runtime (id_enterprise,id_production_order,id_equipment,oee,oee_availability,oee_performance,oee_quality,count,gross,begin_time,end_time)"
        " VALUES (%s,%s,%s,0.8,0.9,0.95,0.93,500,540,now()-interval '8h',now())",
        (ent, base_po, equip_ids[0]),
    )


@pytest.fixture(scope="session")
def superuser_dsn():
    """A throwaway superuser DSN — ephemeral docker Postgres, or an external one."""
    external = os.environ.get("SUPERSET_TEST_PG_DSN")
    if external:
        _wait_ready(external)
        yield external
        return

    if not _docker_available():
        msg = "no docker and no SUPERSET_TEST_PG_DSN — cannot run the isolation gate"
        # In CI the gate is REQUIRED: a skip must never masquerade as a pass.
        # SUPERSET_GATE_REQUIRE=1 turns "can't run" into a hard failure.
        if os.environ.get("SUPERSET_GATE_REQUIRE") == "1":
            pytest.fail(msg + " (SUPERSET_GATE_REQUIRE=1)")
        pytest.skip(msg)

    name = f"superset-rls-gate-{uuid.uuid4().hex[:8]}"
    port = _free_port()
    pw = "gate_super_pw"
    subprocess.run(
        [
            "docker", "run", "-d", "--rm", "--name", name,
            "-e", f"POSTGRES_PASSWORD={pw}",
            "-p", f"127.0.0.1:{port}:5432",
            "postgres:16-alpine",
        ],
        check=True, capture_output=True,
    )
    dsn = f"postgresql://postgres:{pw}@127.0.0.1:{port}/postgres"
    try:
        _wait_ready(dsn)
        yield dsn
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)


@pytest.fixture(scope="session")
def applied_db(superuser_dsn):
    """Seed 2 tenants, apply the REAL db/superset/*.sql, grant superset_ro login.

    Yields (superuser_dsn, superset_ro_dsn). On teardown for an external server,
    drops everything this gate created so the DSN stays reusable.
    """
    conn = psycopg2.connect(superuser_dsn)
    conn.autocommit = True
    with conn.cursor() as cur:
        # Clean slate (in case an external DSN carries prior state).
        cur.execute("DROP SCHEMA IF EXISTS bi CASCADE;")
        _drop_roles(cur)
        for tbl in ("equipments", "equipment_runtime_shift", "equipment_runtime_1hour",
                    "production_orders_runtime", "downtimes"):
            cur.execute(f"DROP TABLE IF EXISTS {tbl} CASCADE;")

        # Base schema + two tenants' data (as superuser → bypasses RLS for seeding).
        cur.execute(_BASE_SCHEMA)
        _seed_tenant(cur, TENANT_A, [1001, 1002], base_po=9001, base_dt=0)
        _seed_tenant(cur, TENANT_B, [2001], base_po=9002, base_dt=50000)

        # Apply the SHIPPED artifacts verbatim — the SQL files ARE under test.
        cur.execute((SQL_DIR / "01-superset-ro-role.sql").read_text())
        cur.execute((SQL_DIR / "02-tenant-rls.sql").read_text())

        # The apply-time step 01 documents: grant LOGIN + password from Secrets
        # Manager. Here we inject a test-only password (never a prod credential).
        cur.execute("ALTER ROLE superset_ro LOGIN PASSWORD %s;", (RO_PASSWORD,))

    # Build the superset_ro DSN from the superuser one (swap creds).
    # postgresql://postgres:pw@host:port/db  →  postgresql://superset_ro:ropw@...
    tail = superuser_dsn.split("@", 1)[1]
    ro_dsn = f"postgresql://superset_ro:{RO_PASSWORD}@{tail}"
    yield superuser_dsn, ro_dsn

    if os.environ.get("SUPERSET_TEST_PG_DSN"):
        with conn.cursor() as cur:
            cur.execute("DROP SCHEMA IF EXISTS bi CASCADE;")
            _drop_roles(cur)
    conn.close()
