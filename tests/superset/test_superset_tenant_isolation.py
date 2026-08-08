"""W2 embedded-Superset — the NON-NEGOTIABLE 2-tenant isolation GATE.

See tests/superset/conftest.py for the ephemeral-Postgres harness and
docs/plans/w2-embedded-superset.md §8 for why this blocks a merge.

Two independent classes of check:

  1. STRUCTURAL GUARDS (fail if the curated surface could ever leak):
     - every bi.* view exposes an `id_enterprise` column (no view can omit the
       tenant key — the denormalization guarantee);
     - every base table under a bi.* view has RLS enabled + a policy (no view
       without a rule). These auto-discover from the catalog, so a NET-NEW bi.*
       view added later without a tenant key / without base RLS FAILS the gate.

  2. BEHAVIOURAL ISOLATION (a net-new raw query per bi.* model, as superset_ro):
     - GUC=A → only tenant A; GUC=B → only tenant B;
     - GUC unset → zero rows (fail-closed);
     - GUC=A + WHERE id_enterprise=B (the guest-token-clause shape) → zero rows;
     - tenant A rows ∩ tenant B rows == ∅ and their union == all rows.
"""

import psycopg2
import pytest

from conftest import TENANT_A, TENANT_B


# ── catalog helpers ──────────────────────────────────────────────────────────

def _bi_views(su_conn) -> list[str]:
    with su_conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.views "
            "WHERE table_schema='bi' ORDER BY table_name"
        )
        return [r[0] for r in cur.fetchall()]


def _base_tables_of_view(su_conn, view: str) -> set[str]:
    """Base RELATIONS a bi.* view depends on, via pg_rewrite/pg_depend."""
    with su_conn.cursor() as cur:
        cur.execute(
            """
            SELECT DISTINCT t.relname
            FROM pg_class v
            JOIN pg_namespace nv ON nv.oid = v.relnamespace
            JOIN pg_rewrite r ON r.ev_class = v.oid
            JOIN pg_depend  d ON d.objid = r.oid
                             AND d.refclassid = 'pg_class'::regclass
            JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
            WHERE nv.nspname = 'bi' AND v.relkind = 'v'
              AND v.relname = %s AND t.oid <> v.oid
            """,
            (view,),
        )
        return {r[0] for r in cur.fetchall()}


@pytest.fixture(scope="session")
def su(applied_db):
    su_dsn, _ = applied_db
    conn = psycopg2.connect(su_dsn)
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def views(su):
    vs = _bi_views(su)
    assert vs, "no bi.* views were created — 01-superset-ro-role.sql did not apply"
    return vs


def _ro_rows(applied_db, view: str, tenant: int | None, where: str = ""):
    """A NET-NEW raw query as superset_ro, optional session tenant stamp."""
    _, ro_dsn = applied_db
    conn = psycopg2.connect(ro_dsn)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            if tenant is not None:
                cur.execute("SET app.tenant_id = %s", (str(tenant),))
            cur.execute(f"SELECT id_enterprise FROM bi.{view} {where}")
            return [r[0] for r in cur.fetchall()]
    finally:
        conn.close()


# ── 1. STRUCTURAL GUARDS ─────────────────────────────────────────────────────

def test_guard_every_bi_view_exposes_id_enterprise(su, views):
    """No bi.* view may omit the tenant key."""
    missing = []
    with su.cursor() as cur:
        for v in views:
            cur.execute(
                "SELECT 1 FROM information_schema.columns "
                "WHERE table_schema='bi' AND table_name=%s AND column_name='id_enterprise'",
                (v,),
            )
            if cur.fetchone() is None:
                missing.append(v)
    assert not missing, f"bi.* views WITHOUT id_enterprise (cannot be tenant-scoped): {missing}"


def test_guard_every_base_table_under_a_bi_view_has_rls(su, views):
    """No bi.* view without a rule: every base table it reads must have RLS+policy."""
    offenders = []
    with su.cursor() as cur:
        for v in views:
            for tbl in _base_tables_of_view(su, v):
                cur.execute("SELECT relrowsecurity FROM pg_class WHERE relname=%s", (tbl,))
                row = cur.fetchone()
                rls_on = bool(row and row[0])
                cur.execute("SELECT count(*) FROM pg_policies WHERE tablename=%s", (tbl,))
                has_policy = cur.fetchone()[0] > 0
                if not (rls_on and has_policy):
                    offenders.append((v, tbl, rls_on, has_policy))
    assert not offenders, (
        "bi.* view(s) read a base table lacking RLS-enabled + a policy "
        f"(view, table, rls_enabled, has_policy): {offenders}"
    )


def test_read_roles_never_bypass_rls(su):
    with su.cursor() as cur:
        cur.execute(
            "SELECT rolname, rolbypassrls, rolsuper FROM pg_roles "
            "WHERE rolname IN ('superset_ro','bi_owner')"
        )
        for name, bypass, sup in cur.fetchall():
            assert not bypass, f"{name} has BYPASSRLS — isolation is void"
            assert not sup, f"{name} is SUPERUSER — isolation is void"


# ── 2. BEHAVIOURAL ISOLATION (parametrized over every discovered bi.* view) ──

def test_stamped_tenant_sees_only_its_own_rows(applied_db, su, views):
    for v in views:
        a = _ro_rows(applied_db, v, TENANT_A)
        b = _ro_rows(applied_db, v, TENANT_B)
        assert a, f"bi.{v}: tenant A stamped but saw zero rows (RLS too strict / no data)"
        assert b, f"bi.{v}: tenant B stamped but saw zero rows"
        assert set(a) == {TENANT_A}, f"bi.{v}: tenant A leaked non-A rows: {set(a)}"
        assert set(b) == {TENANT_B}, f"bi.{v}: tenant B leaked non-B rows: {set(b)}"


def test_unset_guc_denies_all_rows_fail_closed(applied_db, views):
    for v in views:
        rows = _ro_rows(applied_db, v, tenant=None)
        assert rows == [], f"bi.{v}: UNSET tenant returned rows {set(rows)} — RLS is NOT fail-closed"


def test_wrong_tenant_clause_is_blocked(applied_db, views):
    """The guest-token clause shape (WHERE id_enterprise=<other>) must also return
    nothing when the session is stamped for a different tenant — defense-in-depth."""
    for v in views:
        rows = _ro_rows(applied_db, v, tenant=TENANT_A, where=f"WHERE id_enterprise = {TENANT_B}")
        assert rows == [], f"bi.{v}: session A + WHERE id_enterprise=B returned rows — cross-tenant leak"


def test_tenant_rowsets_are_disjoint_and_partition(applied_db, su, views):
    # The "universe" of tenants with seeded data, read from the BASE table as
    # superuser (bypasses base-table RLS). We deliberately do NOT read it through
    # a bi.* view: the views are SECURITY DEFINER owned by the NOBYPASSRLS
    # bi_owner, so even a superuser selecting `bi.<view>` with no GUC gets ZERO
    # rows — a nice second proof that the co-enforcer holds even against superuser.
    with su.cursor() as cur:
        cur.execute("SELECT DISTINCT id_enterprise FROM equipments")
        universe = {r[0] for r in cur.fetchall()}
    assert universe == {TENANT_A, TENANT_B}, f"unexpected seed universe: {universe}"

    for v in views:
        a = set(_ro_rows(applied_db, v, TENANT_A))
        b = set(_ro_rows(applied_db, v, TENANT_B))
        assert a & b == set(), f"bi.{v}: tenant A and B row-sets overlap: {a & b}"
        assert (a | b) == universe, (
            f"bi.{v}: stamped A∪B ({a | b}) != all tenants ({universe}) — a tenant is unreachable"
        )
