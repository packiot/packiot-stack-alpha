# packiot40 — Cognito user-id migration (#159 / ADR-0034)

**Target DB:** the LEGACY customer database `packiot40` (18.220.223.110, us-east-2)
— the plane served by back4-api + primary-api + edge-api-prod. **NOT** the
new-stack `packiot` / `packiot_analytics` DBs (those already carry the column via
`edge-node-red/db/32-cognito-user-id.sql`).

**Status: AUTHORED — NOT EXECUTED.** Every file here is a reviewable artifact.
Running any of them is a **prod-customer-DB write** gated on explicit user go
(see `docs/plans/firebase-to-cognito-migration-epic.md`, Phase 0). Nothing here
runs as part of CI or any deploy.

## Files (apply order)

| File | What | When |
|---|---|---|
| `01_add_id_user_cognito.up.sql` | `ADD COLUMN id_user_cognito` + partial-unique index `CONCURRENTLY`. Additive, nullable, zero impact on the live Firebase path. | Phase 0.3 — any time before the front4-prod cutover. |
| `01_add_id_user_cognito.down.sql` | Rollback (drop index + column). Safe only while Firebase is still dual-accepted. | Rollback only. |
| `02_remediate_7_unlinkable_users.sql` | Resolve the 7 rows that cannot be email-linked (2 dup-email pairs + 5 NULL-email). **Deactivates prod rows — read STEP 0 first.** | Phase 0.4 — before enabling link-on-login / Firebase-off. |

## How to run (when authorized)

`CREATE/DROP INDEX CONCURRENTLY` cannot run inside a transaction block, so do
**not** pass `--single-transaction` / `-1` for `01_*`:

```bash
# 01 — schema (NO single-transaction; CONCURRENTLY manages its own locks)
psql "$PACKIOT40_URL" -v ON_ERROR_STOP=1 -f 01_add_id_user_cognito.up.sql

# 02 — remediation. Run STEP 0 (read-only) FIRST, confirm the plan, then run the
# guarded STEP 1 / STEP 2 blocks. Each block is its own BEGIN/COMMIT with a
# row-count assertion that aborts on a wrong id set.
psql "$PACKIOT40_URL" -v ON_ERROR_STOP=1 -f 02_remediate_7_unlinkable_users.sql
```

## Safety summary

- `01` is additive + reversible; harmless to apply early.
- `02` deactivates 4 rows (2 stale dup + optionally 5 no-email = up to 7) and is
  the one destructive step. It keeps the earliest `id_user` per collision to match
  the link-on-login `ORDER BY id_user ASC` guard — but **confirm which row is the
  live Firebase identity** (STEP 0) before running, or you can lock a user out.
- Every write is a single-column `active` flip (soft-delete) — fully reversible
  by setting `active = true` again.
