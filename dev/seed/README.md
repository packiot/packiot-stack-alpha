# dev/seed — anonymized dev database seed (ADR-0060 D4–D6)

| File | Role |
|---|---|
| `manifest.yml` | every base table of `packiot_analytics` with a mode: `rows` (+ `where` using `:tenant`, `:since`), `full`, `replace`, `schema_only` |
| `classification.yml` | every text/json/array column of a copied table: `keep`, `pseudonym`, `scrub`, `null`, with the reason and the leak-scan counts |
| `schema-columns.tsv` | snapshot of the schema (names and types only) the two files were checked against |
| `validate.py` | fail-closed check; run it in CI and at the start of every seed build against the live schema |

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
