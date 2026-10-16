# t286 — Samples box tables public → bronze

Moves `scanned_boxes` + `sample_boxes` (the currently 0-row Samples feature) from
`public` to `bronze`, per the medallion taxonomy (raw box-scan events = bronze).
User decision: bronze.

## Trace (why it's transparent)

| Consumer | How it references the tables |
|---|---|
| edge-api `src/data/DAO/samples/samples-dao.ts` (list/create/edit/delete) | **bare** `sample_boxes` |
| edge-api `src/data/DAO/labels/labels-dao.ts` | **bare** `scanned_boxes` |

Both DAOs inject the primary `PostgresAdapter` → `packiot_analytics` (via pgbouncer),
which sets **no** explicit search_path and so inherits the DB-default medallion path
`$user, gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`
— `bronze` precedes `public`, so the bare names resolve to bronze after the move. No
code change. (Same resolution edge-api already relies on for `core.*`/`identity.*`.)

No view, routine, or Go service references either table (`services/` grep = 0). No
incoming FKs; `SET SCHEMA` carries the PK/UNIQUE + indexes and the 2 outgoing FKs
(`sample_boxes` → `enterprises`, `equipments`).

## HARDPROOF (staging, rolled-back tx under the DB-default search_path)

After `SET SCHEMA bronze` for both:
- bare `INSERT INTO scanned_boxes ...` and `INSERT INTO sample_boxes ...` → land in
  `bronze.scanned_boxes` / `bronze.sample_boxes` (1 row each)
- `public` has neither table (count 0) — no 42P01 risk was possible because bronze
  precedes public
- bare `SELECT * FROM sample_boxes` / `scanned_boxes` read from bronze (1 row each)
- 8 indexes on `bronze.scanned_boxes`, 2 FKs on `bronze.sample_boxes` followed

## Apply (staging, packiot_analytics)

```sh
psql ... -f 01-move.sql
```

`rollback.sql` moves both back to `public`.
