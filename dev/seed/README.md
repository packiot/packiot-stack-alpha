# dev/seed — anonymized dev database seed (ADR-0060 D4–D6)

| File | Role |
|---|---|
| `manifest.yml` | every base table of `packiot_analytics` with a mode: `rows` (+ `where` using `:tenant`, `:since`), `full`, `replace`, `schema_only` |
| `classification.yml` | every text/json/array column of a copied table: `keep`, `pseudonym`, `scrub`, `null`, with the reason and the leak-scan counts |
| `schema-columns.tsv` | snapshot of the schema (names and types only) the two files were checked against |
| `validate.py` | fail-closed check; run it in CI and at the start of every seed build against the live schema |
| `extract.sh` | on the staging runner: validate → tokens → DDL dump (no data) + roles (no passwords) + secret scan → per-table `COPY (SELECT …)` → `anonymize.py` → `leakgate.py` → `metadata.json` + `load.sql` |
| `anonymize.py` / `leakgate.py` | streaming CSV anonymizer; output scanner that fails on any tenant token, e-mail or IPv4 (stdlib, unit-tested) |
| `load.sh` + `Dockerfile` | seed image (`timescale/timescaledb:2.27.0-pg15`): at first start restores roles (dev password `dev`), DDL, then `load.sql` with Δ = whole weeks since `snapshot_end` |

**Fail-closed, three ways:** an unlisted table, an unclassified text column, or a column with an unknown data type all fail
`validate.py`. When the schema grows, the seed build stops until someone decides what the new thing is.

**Classes.** `pseudonym` = keyed HMAC of the value (same input → same output, so `cd_machine` and `cd_equipment` still join).
`scrub` = replace every known sensitive token (enterprise/site/area/equipment/client/product names of the tenant) inside the
string with its pseudonym; keeps labels and JSON readable. `null` = dropped. `keep` = copied as-is.
Numeric, boolean, uuid, date/time, interval and range columns are kept by type; timestamps, dates and `tstzrange` columns are
shifted by whole weeks at load (D6).

**How the classification was made (2026-10-06):** rules on column names, then a read-only leak scan of every text column
(counts only: values containing a tenant name token, an e-mail, or an IPv4), then a manual review that overrode 72 entries.
The scan sample was not time-windowed, so "empty in sample" was only trusted for columns of unknown meaning.

```bash
dev/seed/validate.py                       # against the committed snapshot
dev/seed/validate.py --columns live.tsv    # against a live inventory (seed job)
```

## Why a full dump without data, not `pg_dump --schema-only`
TimescaleDB stores hypertable, continuous-aggregate and policy metadata as **rows** in `_timescaledb_catalog` /
`_timescaledb_config`. A schema-only dump drops them: restored tables come back as plain tables and caggs as hollow views
(proven locally on 2.27.0). The extractor dumps everything but excludes the data of every user schema and of
`_timescaledb_internal` (chunks); the image restores it between `timescaledb_pre_restore()` and `timescaledb_post_restore()`.

## Proven end to end (local fake source, 2026-10-06)
Two tenants, names in labels, an e-mail in a `null` column, rows inside and outside the window, a login role with a
password. Result: only tenant 3 in-window rows; 0 occurrences of any real name, the e-mail, the role password or the
real API key anywhere in the payload; hypertable + cagg preserved and refreshed (sum exact); identity ids kept,
generated column recomputed; telemetry off; a 15-day-old snapshot loaded with Δ = 14 days, weekdays and range bounds intact.
