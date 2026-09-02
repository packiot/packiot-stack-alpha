# configs/superset/bootstrap_guest_role.py
# ─────────────────────────────────────────────────────────────────────────────
# BI security bootstrap — run by superset-init AFTER `superset init` (which syncs
# the built-in Admin/Alpha/Gamma/Public roles) and AFTER the service/admin users
# are created. Idempotent; safe to run on every boot.
#
# It hardens four things (see docs/audits/superset-dashboard-data-review.md and the
# staging BI-hardening pass 2026-08-23):
#
#  1. DEDICATED GUEST ROLE (GUEST_ROLE_NAME, now "GuestViewer" — NOT "Public").
#     The embedded chart-data path resolves a guest token to GUEST_ROLE_NAME and
#     `@protect()` 403s the request BEFORE Row-Level Security runs unless that role
#     carries the minimal read/explore perms. We grant them to a role SEPARATE from
#     Public so the (tenant-locked, RLS-fail-closed) guest perms are NEVER inherited
#     by anonymous callers — see #2.
#
#  2. STRIP THE PUBLIC (ANONYMOUS) ROLE. In Flask-AppBuilder "Public" is the role
#     every UNAUTHENTICATED request assumes. Historically the guest role WAS Public,
#     so anonymous callers inherited `can read on Dashboard/Chart/Dataset` +
#     `all_datasource_access` and `GET /api/v1/dashboard/` returned 200 with
#     dashboard/dataset/chart METADATA to the whole internet. Stripping Public to
#     zero perms closes that leak (the endpoint now 401s for anon). Guest tokens use
#     GuestViewer (#1), which anon never assumes.
#
#  3. MINIMAL GUEST-TOKEN MINTER ROLE ("GuestTokenMinter" = only
#     `can_grant_guest_token on SecurityRestApi`). edge-api authenticates as the
#     minter service account to MINT guest tokens; it does not need — and must not
#     have — full Admin. We scope the service account down to this one permission
#     (blast radius 167 Admin perms → 1), lockout-safe (see below).
#
# RLS is STILL the tenant enforcer. These grants only let the guest role REACH the
# chart-data endpoint; the per-tenant guest-token RLS clause + the Postgres
# co-enforcer (db/superset/02-tenant-rls.sql, fail-closed) filter the rows.
#
# Dashboard-level RBAC roles are assigned AFTER the asset bundle is imported, by
# configs/superset/harden_dashboard_roles.py (dashboards don't exist yet here).
#
# Mounted read-only at /app/pythonpath/bootstrap_guest_role.py.

import os
import sys

from superset.app import create_app

# Minimal (permission_name, view_menu_name) set the embedded chart-data path checks.
# Best-effort: any pvm this Superset build doesn't define is skipped.
#
# all_datasource_access is intentionally kept HERE (on the dedicated GuestViewer
# role, never on anon-Public): the only registered DB is the RLS-protected bi
# analytics connection, every guest query is tenant-filtered by its token RLS
# clause + the DB_CONNECTION_MUTATOR (app.tenant_id), and the analytics DB is
# registered expose_in_sqllab=False + allow_dml=False — so datasource read here
# cannot widen tenant visibility or reach raw base tables.
GUEST_EMBED_PERMS = [
    ("can_read", "Chart"),
    ("can_read", "Dashboard"),
    ("can_read", "Dataset"),
    ("can_explore", "Superset"),
    ("can_explore_json", "Superset"),
    ("can_read", "EmbeddedDashboard"),
    ("all_datasource_access", "all_datasource_access"),
]

# The ONLY permission the guest-token mint endpoint (POST /api/v1/security/guest_token/)
# checks. `can_grant_guest_token` lives on the `SecurityRestApi` view-menu.
MINTER_PERMS = [("can_grant_guest_token", "SecurityRestApi")]

MINTER_ROLE_NAME = "GuestTokenMinter"


def _ensure_role(sm, name):
    role = sm.find_role(name)
    if role is None:
        role = sm.add_role(name)
        print(f"[bootstrap] created role {name!r}")
    return role


def _grant(sm, role, perms):
    granted, skipped = [], []
    for perm_name, view_name in perms:
        pvm = sm.find_permission_view_menu(perm_name, view_name)
        if pvm is None:
            skipped.append(f"{perm_name} on {view_name} (no such pvm)")
            continue
        if pvm in role.permissions:
            continue
        sm.add_permission_role(role, pvm)
        granted.append(f"{perm_name} on {view_name}")
    print(f"[bootstrap] {role.name}: granted={granted or 'none (already present)'} "
          f"skipped={skipped or 'none'}")


def main() -> int:
    app = create_app()
    with app.app_context():
        from superset import db  # noqa: WPS433 (import inside app context)
        from superset.extensions import security_manager as sm

        # 1. Dedicated guest/embed role (GUEST_ROLE_NAME) — NOT Public.
        guest_role_name = app.config.get("GUEST_ROLE_NAME", "GuestViewer")
        if guest_role_name == "Public":
            print("[bootstrap] WARNING: GUEST_ROLE_NAME is 'Public' — guest perms would "
                  "leak to anonymous callers. Set GUEST_ROLE_NAME to a dedicated role.",
                  file=sys.stderr)
        guest_role = _ensure_role(sm, guest_role_name)
        _grant(sm, guest_role, GUEST_EMBED_PERMS)

        # 3. Minimal minter role.
        minter_role = _ensure_role(sm, MINTER_ROLE_NAME)
        _grant(sm, minter_role, MINTER_PERMS)

        # 2. Strip the Public (anonymous) role to zero perms — closes the anon
        # metadata leak. (Only strip when it isn't itself the guest role.)
        public = sm.find_role("Public")
        if public is not None and public.name != guest_role_name:
            n = len(public.permissions)
            if n:
                public.permissions = []
                db.session.merge(public)
            print(f"[bootstrap] stripped Public: {n} -> 0")

        # 3b. Scope the guest-token minter SERVICE ACCOUNT down to the minter role.
        # LOCKOUT-SAFE: only remove Admin if a DIFFERENT Admin user still exists
        # (e.g. the durable human super-admin created from SUPERSET_ADMIN_*). On a
        # deploy where no separate admin is provisioned (e.g. current prod), the
        # service account keeps Admin so the instance is never left with zero admins.
        svc_username = os.environ.get("SUPERSET_GUESTTOKEN_ADMIN_USER", "").strip()
        if svc_username:
            svc = sm.find_user(username=svc_username)
            if svc is not None and any(r.name == "Admin" for r in svc.roles):
                other_admins = [
                    u for u in sm.get_all_users()
                    if u.username != svc_username
                    and any(r.name == "Admin" for r in u.roles)
                ]
                if other_admins:
                    svc.roles = [minter_role]
                    db.session.merge(svc)
                    print(f"[bootstrap] scoped {svc_username!r} Admin -> {MINTER_ROLE_NAME} "
                          f"(other admins present: {[u.username for u in other_admins]})")
                else:
                    print(f"[bootstrap] KEEPING {svc_username!r} as Admin — no other Admin "
                          "user exists (lockout guard). Provision SUPERSET_ADMIN_* to scope it.")

        db.session.commit()
        print("[bootstrap] done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
