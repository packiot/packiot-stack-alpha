# Superset OEE dashboard — importable asset bundle

Draft, dashboards-as-code bundle for the curated **OEE Overview** dashboard,
derived from front4's Overview tiles over the `bi.*` views. See the full spec:
`docs/plans/superset-oee-dashboard-spec.md`.

**Nothing here is deployed.** This is a reproducible import bundle in Superset's
dashboard-export YAML format (Superset 4.1.x).

## Contents

- `metadata.yaml` — export envelope.
- `databases/packiot_analytics.yaml` — the `superset_ro` → `bi` schema connection
  (SELECT-only; raw schema stays dark). **`sqlalchemy_uri` password is a
  placeholder** — inject from Secrets Manager at import.
- `datasets/packiot_analytics/*.yaml` — 5 datasets over the curated views
  (`bi.oee_shift`, `bi.oee_hourly`, `bi.production_order_runtime`, `bi.downtimes`,
  `bi.equipments`).
- `charts/*.yaml` — 12 charts (gauge, big-numbers, trend line, production bar,
  downtime pareto, tables).
- `dashboards/oee_overview.yaml` — the layout.

All entities carry stable UUIDs and cross-reference by UUID, so the bundle is
re-importable in place.

## Import (staging-first, once Superset is up)

```sh
# zip the bundle and import via the API (or use the UI: Dashboards > Import)
cd configs/superset
zip -r oee-overview-bundle.zip assets
curl -s -X POST "$SUPERSET/api/v1/dashboard/import/" \
  -H "Authorization: Bearer $SUPERSET_ADMIN_TOKEN" \
  -F "formData=@oee-overview-bundle.zip" \
  -F 'passwords={"databases/packiot_analytics.yaml":"'"$SUPERSET_DB_RO_PASSWORD"'"}' \
  -F "overwrite=true"
```

## Live-fill checklist (values that can't be codified)

1. **`superset_ro` password** — from Secrets Manager (`superset_db_ro_password`);
   supplied via the import `passwords` map (above). Route the host via pgbouncer.
2. **Verify `bi.downtimes.duration` type** — datasets assume BIGINT seconds; if the
   `equipment_events.duration` is an interval, adjust the `total_duration` metric.
3. **Embed UUID** — after import, open *OEE Overview* > *Embed dashboard*; the
   generated embed UUID feeds edge-api's `SUPERSET_OEE_DASHBOARD_UUID`.
4. **RLS** — not in this bundle by design; the `id_enterprise` tenant filter is
   applied at runtime by Superset RLS (guest token for embed, role filter for
   authoring). See `docs/plans/w2-embedded-superset.md`.
5. **Run `tests/superset/`** (2-tenant isolation gate) before exposing the nav item.
