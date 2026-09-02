# db/init-f3/snapshot — the authoritative F3 schema DDL

`compose.production.yml`'s `db-schema-f3` one-shot applies these in order to a
fresh prod DB, assembling F3 as `public`. **Proven end-to-end to `F3_MISSING=0`**
against the live-`packiot_analytics` target manifest (see ../README.md §5/§6).

| File | Applied | What |
|---|---|---|
| `00-packiot_analytics-schema.sql` | best-effort | curated schema-only `pg_dump` of staging `packiot_analytics` — all 152 tables, 129 user functions, 10 views (byte-parity). Cagg-view/`_timescaledb_internal`/cross-schema/debris blocks stripped (recreated strict below or intentionally dropped). |
| `05-f3-cagg-agg.sql` | strict | `= docs/adr/reference/migrations/0012-f3-cagg-layer.sql` — the `equipment_values` hypertable + the 9 `agg_*` continuous aggregates. |
| `10-f3-timescale-supplement.sql` | strict | the 3 remaining raw hypertables (`equipment_events`, `equipment_values_raw`, `equipment_events_raw`) + the 5 `ca_*` continuous aggregates. Definitions introspected SELECT-only from `packiot_analytics`. |
| `15-f3-read-api-composite-type-fixes.sql` | strict | fixes 2 porting bugs `00` inherited from live `packiot_analytics` that 500'd 9 read-api `/v1/query` datasets (docs/audits/front4-operator-endpoint-health.md): 8 `h_piot_*`/`h_*` row-shape tables had a jsonb-aggregate column typo'd `text[]` instead of `jsonb[]` (F1 parity confirmed via live `pg_attribute` diff), and `h_piot_get_mission_control_timeline` read `agg_equipment_values_1min_t` — a name already owned by an unrelated, differently-shaped F3 view — instead of the correctly-shaped `agg_equipment_values_1min`. Applied live to staging `packiot_analytics` 2026-08-20 (idempotent: safe to re-run, safe to drop once a `00` regeneration captures the fix at the source). |

**Why `00` is best-effort + a separate timescale layer:** a plain `pg_dump` cannot
restore TimescaleDB continuous aggregates (it dumps them as views over
`_timescaledb_internal._materialized_hypertable_NN`, absent on a fresh DB). So the
caggs + hypertables are recreated timescale-aware in `05`/`10`, and `00`'s
stripped cagg-view residue / debris index refs fail benignly under best-effort.
The parity gate (`scripts/prod-f3-schema-parity-check.sh`) is the real guarantee.

**To regenerate** (e.g. after F3 schema evolves on staging):
`CONFIRM=yes scripts/capture-f3-snapshot.sh` re-dumps + re-strips `00`; refresh
`10` by re-introspecting the cagg defs; then re-run the gate. Prod cagg
refresh/retention **policies** in `05` are staging-tuned — re-tune for prod
(does not affect schema parity). See ../README.md §4/§7.
