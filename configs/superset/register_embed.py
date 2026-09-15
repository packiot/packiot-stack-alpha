"""register_embed.py — pin a STABLE embed UUID for the client-facing dashboard.

WHY THIS EXISTS
───────────────
Superset's `POST /api/v1/dashboard/{id}/embedded` mints a RANDOM embed uuid and
stores it in `embedded_dashboards`. front4 (`VITE_SUPERSET_UUID`) and edge-api
(`SUPERSET_OEE_DASHBOARD_UUID`, the broker's `resources[].id`) both reference that
uuid as a CONSTANT. So a hand-registered embed uuid (the W2 `3607a436-…`) does NOT
survive a metadata-DB rebuild — a fresh Superset would mint a DIFFERENT uuid, and
every mint would target a dashboard that no longer has that embed id → the front4
iframe 404s. This step makes the embed registration reproducible and idempotent:
it upserts an `embedded_dashboards` row with a FIXED uuid for a chosen dashboard,
so the same uuid comes back on every rebuild.

Runs in superset-init AFTER import_bundle.py + harden_dashboard_roles.py (the
dashboard must exist first). Idempotent; a no-op when the env is not provisioned.

ENV
───
  SUPERSET_OEE_DASHBOARD_UUID       the STABLE embed uuid front4/edge-api reference
                                    (the value that must never change). Required.
  SUPERSET_EMBED_TARGET_DASHBOARD   the dashboard to embed, by its OWN stable uuid
                                    (from the asset bundle). Defaults to the OEE
                                    Overview dashboard's bundle uuid. NOTE: a client
                                    tenant should see its OEE report, not the
                                    synthetic Scanned Boxes demo dashboard — set this
                                    to the intended client dashboard's uuid.
  SUPERSET_FRAME_ANCESTOR           front4 origin allowed to iframe (allow_domain_list).
"""
import os
from superset.app import create_app

# Bundle uuids (configs/superset/assets/dashboards/*). Kept here so the target is
# explicit and greppable rather than a bare env value.
OEE_OVERVIEW_UUID = "6c4fa4a1-ddd2-4b4e-b5cb-4eb56bb30937"   # "OEE Overview" (12 charts)
SCANNED_BOXES_UUID = "d1000001-0a1b-4c2d-8e3f-000000000001"  # "Scanned Boxes" (synthetic demo)

app = create_app()
with app.app_context():
    from superset import db
    from superset.models.dashboard import Dashboard
    from superset.models.embedded_dashboard import EmbeddedDashboard

    embed_uuid = os.environ.get("SUPERSET_OEE_DASHBOARD_UUID", "").strip()
    if not embed_uuid:
        print("register_embed: SUPERSET_OEE_DASHBOARD_UUID unset — skipping (embed unconfigured).")
        raise SystemExit(0)

    target_dash_uuid = os.environ.get("SUPERSET_EMBED_TARGET_DASHBOARD", OEE_OVERVIEW_UUID).strip()
    front4_origin = os.environ.get("SUPERSET_FRAME_ANCESTOR", "").strip()
    allow_domains = [front4_origin] if front4_origin else []

    dash = db.session.query(Dashboard).filter(Dashboard.uuid == target_dash_uuid).one_or_none()
    if dash is None:
        raise SystemExit(
            f"register_embed: target dashboard uuid {target_dash_uuid} not found — "
            f"did the asset import run first?"
        )

    # Is this stable embed uuid already registered? Reconcile it onto the target.
    existing = db.session.query(EmbeddedDashboard).filter(
        EmbeddedDashboard.uuid == embed_uuid
    ).one_or_none()

    # Drop any OTHER embed row on the target dashboard (only one stable embed per dash).
    for e in db.session.query(EmbeddedDashboard).filter(
        EmbeddedDashboard.dashboard_id == dash.id,
        EmbeddedDashboard.uuid != embed_uuid,
    ).all():
        print(f"register_embed: removing stale embed {e.uuid} on dashboard {dash.id}")
        db.session.delete(e)

    if existing is None:
        e = EmbeddedDashboard()
        e.uuid = embed_uuid
        e.dashboard_id = dash.id
        e.allow_domain_list = allow_domains
        db.session.add(e)
        action = "created"
    else:
        existing.dashboard_id = dash.id
        existing.allow_domain_list = allow_domains
        action = "reconciled"

    db.session.commit()
    print(
        f"register_embed: {action} embed uuid={embed_uuid} -> dashboard "
        f"id={dash.id} '{dash.dashboard_title}' (uuid={target_dash_uuid}); "
        f"allow_domain_list={allow_domains}"
    )
