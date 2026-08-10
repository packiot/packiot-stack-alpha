# configs/superset/bootstrap_guest_role.py
# ─────────────────────────────────────────────────────────────────────────────
# Grant the guest/embed role the MINIMAL permissions the embedded chart-data path
# needs, so `@protect()` does not 403 the request BEFORE Row-Level Security runs.
#
# THE BUG THIS FIXES: `superset init` creates the guest role (GUEST_ROLE_NAME, by
# default "Public") with ZERO permissions. When front4 loads an embedded dashboard
# with a guest token, Superset resolves the guest identity to that role and then
# checks perms on the chart-data endpoints. With no perms the `@protect()` guard
# returns 403 — the request never reaches the RLS layer, so the (proven) tenant
# isolation never even gets a chance to run. The viewer just sees broken tiles.
#
# WHAT IT GRANTS (idempotent — safe to run on every superset-init):
#   * can_read on Chart, Dashboard, Dataset  — read the embedded objects + their
#     dataset metadata.
#   * can_explore / can_explore_json on Superset — the chart-data render path the
#     embedded SDK calls.
#   * can_read on EmbeddedDashboard (best-effort) — the embed-config lookup; skipped
#     cleanly if the view-menu isn't present on this Superset build.
#
# RLS is STILL the tenant enforcer: these grants only let the guest role reach the
# chart-data endpoint; the per-tenant guest-token RLS clause (+ the Postgres
# co-enforcer in db/superset/02-tenant-rls.sql) is what filters the rows. Granting
# object-level read to the guest role does NOT widen tenant visibility.
#
# Mounted read-only at /app/pythonpath/bootstrap_guest_role.py (inert there — only
# superset_config.py is auto-imported). superset-init runs it explicitly with
# `python /app/pythonpath/bootstrap_guest_role.py` AFTER `superset init`.

import sys

from superset.app import create_app

# The minimal (permission_name, view_menu_name) set the embedded chart-data path
# checks. Best-effort: any pvm this Superset build doesn't define is skipped.
REQUIRED_PERMS = [
    ("can_read", "Chart"),
    ("can_read", "Dashboard"),
    ("can_read", "Dataset"),
    ("can_explore", "Superset"),
    ("can_explore_json", "Superset"),
    ("can_read", "EmbeddedDashboard"),
]


def main() -> int:
    app = create_app()
    with app.app_context():
        from superset import db  # noqa: WPS433 (import inside app context)
        from superset.extensions import security_manager as sm

        role_name = app.config.get("GUEST_ROLE_NAME", "Public")
        role = sm.find_role(role_name)
        if role is None:
            print(f"[bootstrap_guest_role] role {role_name!r} not found — "
                  "did `superset init` run? Nothing to do.", file=sys.stderr)
            return 1

        granted, skipped = [], []
        for perm_name, view_name in REQUIRED_PERMS:
            pvm = sm.find_permission_view_menu(perm_name, view_name)
            if pvm is None:
                skipped.append(f"{perm_name} on {view_name} (no such pvm)")
                continue
            # add_permission_role is itself idempotent (no-op if already present),
            # but we check first so the log is honest about what changed.
            if pvm in role.permissions:
                continue
            sm.add_permission_role(role, pvm)
            granted.append(f"{perm_name} on {view_name}")

        db.session.commit()
        print(f"[bootstrap_guest_role] role={role_name} "
              f"granted={granted or 'none (already present)'} skipped={skipped or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
