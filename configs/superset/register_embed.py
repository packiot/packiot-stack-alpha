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
OEE_OVERVIEW_UUID = "6c4fa4a1-ddd2-4b4e-b5cb-4eb56bb30937"    # "OEE Overview" (en, 12 charts)
OEE_OVERVIEW_PT_UUID = "a1b2c3d4-0000-4b4e-b5cb-4eb56bb30937"  # "Visão Geral de OEE" (pt-BR, 12 charts)
SCANNED_BOXES_UUID = "d1000001-0a1b-4c2d-8e3f-000000000001"   # "Scanned Boxes" (synthetic demo)

app = create_app()
with app.app_context():
    from superset import db
    from superset.models.dashboard import Dashboard
    from superset.models.embedded_dashboard import EmbeddedDashboard

    # SUPERSET_FRAME_ANCESTOR may carry MULTIPLE comma-separated origins — front4 is
    # reachable at more than one host (e.g. staging.packiot.com AND
    # front.staging.packiot.app). Split into a clean list of origins (shared by both
    # the en and pt embeds).
    frame_ancestor = os.environ.get("SUPERSET_FRAME_ANCESTOR", "").strip()
    allow_domains = [o.strip() for o in frame_ancestor.split(",") if o.strip()]

    def reconcile(embed_uuid, target_dash_uuid, label):
        """Pin one stable embed uuid onto its target dashboard (idempotent)."""
        dash = db.session.query(Dashboard).filter(
            Dashboard.uuid == target_dash_uuid).one_or_none()
        if dash is None:
            raise SystemExit(
                f"register_embed: {label} target dashboard uuid {target_dash_uuid} "
                f"not found — did the asset import run first?"
            )
        existing = db.session.query(EmbeddedDashboard).filter(
            EmbeddedDashboard.uuid == embed_uuid).one_or_none()
        # Only one stable embed per dashboard — drop any OTHER embed on this target.
        for e in db.session.query(EmbeddedDashboard).filter(
            EmbeddedDashboard.dashboard_id == dash.id,
            EmbeddedDashboard.uuid != embed_uuid,
        ).all():
            print(f"register_embed: removing stale embed {e.uuid} on dashboard {dash.id}")
            db.session.delete(e)
        # `allow_domain_list` is a COMMA-SEPARATED STRING (Superset's
        # EmbeddedDashboard.allowed_domains property does `.split(",")`). It must NOT
        # be a Python list: psycopg2 serialises a list into the Postgres array literal
        # `{https://…}`, whose LITERAL braces then survive the split and break
        # same_origin() → every embed request 403s (view.py referrer check). Join first.
        if existing is None:
            e = EmbeddedDashboard()
            e.uuid = embed_uuid
            e.dashboard_id = dash.id
            e.allow_domain_list = ",".join(allow_domains)
            db.session.add(e)
            action = "created"
        else:
            existing.dashboard_id = dash.id
            existing.allow_domain_list = ",".join(allow_domains)
            action = "reconciled"
        db.session.commit()
        print(
            f"register_embed: {label} {action} embed uuid={embed_uuid} -> dashboard "
            f"id={dash.id} '{dash.dashboard_title}' (uuid={target_dash_uuid}); "
            f"allow_domain_list={allow_domains}"
        )

    # English embed (required). pt-BR embed (optional — only if SUPERSET_OEE_DASHBOARD_UUID_PT
    # is set; edge-api mints for it when the caller's language is Portuguese).
    en_embed = os.environ.get("SUPERSET_OEE_DASHBOARD_UUID", "").strip()
    if not en_embed:
        print("register_embed: SUPERSET_OEE_DASHBOARD_UUID unset — skipping (embed unconfigured).")
        raise SystemExit(0)
    reconcile(en_embed,
              os.environ.get("SUPERSET_EMBED_TARGET_DASHBOARD", OEE_OVERVIEW_UUID).strip(),
              "en")

    pt_embed = os.environ.get("SUPERSET_OEE_DASHBOARD_UUID_PT", "").strip()
    if pt_embed:
        reconcile(pt_embed,
                  os.environ.get("SUPERSET_EMBED_TARGET_DASHBOARD_PT", OEE_OVERVIEW_PT_UUID).strip(),
                  "pt")
