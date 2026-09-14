# t282 — historian-gateway #270 glue (sweep R2/R4/R5/R6/R7/R8/R9)

Closes the remaining glue items from `docs/plans/historian-gateway-schema-sweep.md`
after R1/R3 landed in #1254 (t271 promoted allow-list + refresh gating). All items are
documentation / column-pin / monitor / defense-in-depth glue — **zero data risk, fully
reversible**.

## What's here

| File | Target DB | Items |
|------|-----------|-------|
| `02-analytics-histgw-ro.sql` | `packiot_analytics` (10.10.10.89) | R9 — mint least-privilege `histgw_ro` remote FDW role (SELECT on the 2 silver facts only) |
| `01-gateway.sql` | hist-gateway `postgres` | R2 (cold id-space provenance), R5 (`hist_meta` stamp table), R6 (year/month prune-contract COMMENTs), R8 (pin `live.equipment_events` to 12 cols), R9 (repoint `cloudbeaver_histro` mapping → `histgw_ro`) |
| `rollback-01-gateway.sql` / `rollback-02-analytics-histgw-ro.sql` | resp. | reverse |

R4 (staleness monitor) + R7 (EE hot-coverage reconciliation) ship as scheduled checks,
not DDL — see `scripts/historian-staleness-monitor.sh`, `scripts/historian-ee-coverage-check.sh`,
the aggregator `scripts/historian-integrity-monitor.sh`, and the systemd units
`systemd/historian-integrity-monitor.{service,timer}`. R5's stamp is written by the
append post-run hook (`scripts/stamp-hist-meta.sql`, wired in `historian-staging-run-append.sh`).

## Apply order (staging)

```sh
# 1) analytics side first — mint the remote role (secret via -v, never in git)
PW='<histgw_ro secret>'
psql -h 10.10.10.89 -U postgres -d packiot_analytics -v histgw_ro_pass="$PW" \
     -f 02-analytics-histgw-ro.sql
# 2) gateway side — same secret repoints the browser mapping
docker exec -i hist-gateway psql -U postgres -d postgres -v histgw_ro_pass="$PW" \
     -f - < 01-gateway.sql
```

Store `$PW` in the gateway `.env` as `HISTGW_RO_PASS` (consumed by the init script on a
fresh boot). The gateway init `10-historian-gateway.sh` reproduces this exact state on a
clean volume — keep the two in sync.

## Rollback

```sh
# gateway first (repoints mapping off histgw_ro), then analytics (drops the role)
docker exec -i hist-gateway psql -U postgres -d postgres -v fdw_pass="$FDW_PASS" -f - < rollback-01-gateway.sql
psql -h 10.10.10.89 -U postgres -d packiot_analytics -f rollback-02-analytics-histgw-ro.sql
```
