# Superset dashboard bundle — importable asset bundle (W3 PowerBI migration)

Dashboards-as-code bundle recreating the CPACK-relevant PowerBI report families as
native Superset dashboards over the curated `bi.*` semantic layer
(`db/superset/01-superset-ro-role.sql`). Background:
`docs/plans/powerbi-to-superset-migration.md` (report inventory + PowerBI→`bi.*`
mapping) and `docs/plans/cpack-superset-dashboard-buildout.md` (per-dashboard build
log + live row counts).

**Status: LIVE on `production`** (`bi.prod.packiot.app`, box `i-0a5c5dadd9ea5e93e`) —
built 2026-08-11/12 (PR #790/#794), verified live again 2026-08-20 (8 dashboards, 39
charts). **This copy is the port of that exact bundle onto `staging`** — see the
STATUS UPDATE block at the top of `docs/plans/powerbi-to-superset-migration.md` for
what porting does and does not include (the staging Superset container stack itself
has not been started — see that doc).

## Contents

- `metadata.yaml` — export envelope.
- `databases/packiot_analytics.yaml` — the `superset_ro` → `bi` schema connection
  (SELECT-only; raw schema stays dark). **`sqlalchemy_uri` password is a
  placeholder** — inject from Secrets Manager at import. Connects DIRECT to the DB
  box (not pgbouncer — see the note inside the file for why: pgbouncer's
  transaction pooling can defeat the per-request tenant GUC stamp). On staging
  that's `10.10.10.89/packiot_analytics`; production is `10.20.10.89/packiot` (F3
  already reassembled as prod's `public` schema).
- `datasets/packiot_analytics/*.yaml` — 10 datasets over the curated views:
  `bi.oee_shift`, `bi.oee_hourly`, `bi.production_order_runtime`, `bi.downtimes`,
  `bi.equipments`, plus the 5 W3 gap views `bi.live_status`, `bi.equipment_speed`,
  `bi.production_by_team`, `bi.production_orders`, `bi.production_targets`.
- `charts/*.yaml` — 39 charts (gauges, big-numbers, trend lines, bars, pies, pivots,
  tables) across OEE, shift, production, scrap, live-status, machine-speed and
  downtime families.
- `dashboards/*.yaml` — 8 dashboards: **OEE Overview, Shift Report, Total
  Production, Scrap Analysis, Live Status, Downtime Analysis, Production Orders,
  Machine Speed.** Each maps to one or more PowerBI report *families* (§1 of the
  migration plan) — one tenant-generic Superset dashboard replaces N hardcoded
  per-tenant PowerBI reports.

All entities carry stable UUIDs and cross-reference by UUID, so the bundle is
re-importable in place (this is how production re-applied fixes without duplicating
dashboards — `overwrite=true`).

## Import (staging, once the Superset containers are running)

```sh
# zip the bundle and import via the API (or use the UI: Dashboards > Import)
cd configs/superset
zip -r superset-w3-bundle.zip assets
curl -s -X POST "$SUPERSET/api/v1/dashboard/import/" \
  -H "Authorization: Bearer $SUPERSET_ADMIN_TOKEN" \
  -F "formData=@superset-w3-bundle.zip" \
  -F 'passwords={"databases/packiot_analytics.yaml":"'"$SUPERSET_DB_RO_PASSWORD"'"}' \
  -F "overwrite=true"
```

## Live-fill checklist (values that can't be codified)

1. **Stand up the staging Superset stack first** — `compose.superset.yml` has never
   been deployed/profile-activated on `packiot-staging-app`
   (`i-06c9547a2c7091ab7`), even though its `.env` already carries the 12
   `SUPERSET_*` secrets. `docker compose -f compose.staging.yml -f
   compose.superset.yml --profile superset up -d` (after confirming the secrets are
   current in Secrets Manager).
2. **Apply `db/superset/01-superset-ro-role.sql` + `02-tenant-rls.sql`** against
   staging's `packiot_analytics` database (creates the `bi` schema, the 10 views, the
   `superset_ro` role, and the base-table RLS policies) — these are NOT run
   automatically by the compose overlay.
3. **`superset_ro` password** — from Secrets Manager (`superset_db_ro_password`);
   supplied via the import `passwords` map (above).
4. **Verify `bi.downtimes.duration` units** once staging CPACK/sandbox data lands —
   production confirmed this is seconds via live data; staging may differ if its
   `equipment_events` source differs.
5. **Embed UUID** — after import, open each dashboard > *Embed dashboard*; the
   generated embed UUIDs feed edge-api's `SUPERSET_*_DASHBOARD_UUID` env vars if
   front4 embeds staging Superset directly.
6. **RLS** — tenant isolation is enforced in Postgres (SECURITY DEFINER `bi.*`
   views + base-table RLS keyed on the `app.tenant_id` session GUC, stamped per
   request by `superset_config.py`'s `DB_CONNECTION_MUTATOR` from the caller's
   guest-token/authoring-role tenant) — **not** via Superset's native
   `RowLevelSecurityFilter` UI feature (that table is intentionally empty on
   production; verified live 2026-08-20). See `db/superset/02-tenant-rls.sql`.
7. **Run `tests/superset/`** (2-tenant isolation gate) before exposing any nav item
   pointed at staging Superset.
8. **DB rename LANDED (2026-08-20)** — staging's analytics DB was renamed
   `packiot_shadow` → `packiot_analytics`; `databases/packiot_analytics.yaml`'s
   `dbname` already points at `packiot_analytics`.
