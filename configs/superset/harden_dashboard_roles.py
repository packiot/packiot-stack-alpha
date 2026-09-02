# configs/superset/harden_dashboard_roles.py
# ─────────────────────────────────────────────────────────────────────────────
# Assign explicit RBAC roles to every imported dashboard, run by superset-init
# AFTER `superset import-dashboards` (the dashboards must exist first).
#
# WHY: with DASHBOARD_RBAC enabled, a dashboard whose `roles` list is EMPTY falls
# back to dataset-level perms — so anyone whose role can read the datasets can list
# and open it. Historically that included the over-broad Public role (the anon
# metadata leak). We pin each dashboard to explicit non-Public roles:
#
#   * Admin       — the internal super-admin (always has access anyway; listed for
#                   clarity and so the board is never orphaned).
#   * GuestViewer — the dedicated embed/guest role (GUEST_ROLE_NAME). Keeps the
#                   embedded guest-token path working under RBAC; GuestViewer is
#                   assumed ONLY by tenant-locked guest tokens, never by anon.
#
# Anonymous (Public) callers hold neither role → cannot list or open the boards,
# complementing the Public strip in bootstrap_guest_role.py. Idempotent.
#
# Mounted read-only at /app/pythonpath/harden_dashboard_roles.py.

import sys

from superset.app import create_app

EXTRA_DASHBOARD_ROLE = "Admin"


def main() -> int:
    app = create_app()
    with app.app_context():
        from superset import db  # noqa: WPS433 (import inside app context)
        from superset.extensions import security_manager as sm
        from superset.models.dashboard import Dashboard

        guest_role_name = app.config.get("GUEST_ROLE_NAME", "GuestViewer")
        roles = [r for r in (sm.find_role(EXTRA_DASHBOARD_ROLE),
                             sm.find_role(guest_role_name)) if r is not None]
        if not roles:
            print("[harden_dashboards] no target roles found — nothing to do.",
                  file=sys.stderr)
            return 1

        count = 0
        for dash in db.session.query(Dashboard).all():
            dash.roles = list(roles)
            db.session.merge(dash)
            count += 1
        db.session.commit()
        print(f"[harden_dashboards] assigned roles "
              f"{[r.name for r in roles]} to {count} dashboards")
    return 0


if __name__ == "__main__":
    sys.exit(main())
