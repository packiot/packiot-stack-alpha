# Hasura safety gate — dropping `users.operator_pw_hash` on the legacy `packiot` DB (#220)

Unlike `packiot_analytics` (new-stack, no Hasura, column already absent per #219),
the legacy `packiot` DB on `10.10.10.89` is **Hasura-fronted**. That adds two
exposure paths a plain `DROP COLUMN` would miss, so both were audited before the
drop. This file records the evidence so the drop is reproducible and reversible
reasoning is preserved.

## Verdict: DEAD — safe to drop, no untrack needed

| Gate | Result | Evidence |
|------|--------|----------|
| Column location | `public.users.operator_pw_hash`, `text`, nullable | `information_schema.columns` |
| Data | 8 users, 5 non-null bcrypt hashes (dead auth material) | `count(operator_pw_hash)` |
| View / rule dependency | none | `pg_depend`→`pg_rewrite` join, 0 rows |
| Hasura table tracked? | yes, `users` tracked in source `default` | `hdb_catalog.hdb_metadata` |
| GraphQL column exposure | **NOT exposed** — the only `select_permissions` entry (role `user`) has an explicit 10-column allow-list that omits `operator_pw_hash` | metadata `users.select_permissions[0].permission.columns` |
| Referenced anywhere in metadata? | **NO** — string `operator_pw_hash` absent from the entire 14,868-char metadata blob | `metadata::text LIKE '%operator_pw_hash%'` → `f` |
| Live Hasura HTTP endpoint (staging) | none reachable — only `5432` open on `10.10.10.89` (8080/8081 closed) | tcp scan from staging box |
| back4-api reader (Hasura consumer) | none | `grep -rniE operator_pw_hash` → 0 hits |
| edge-api reader | none — `/session` is Cognito-only (RS256/JWKS); only stale comments remain | `login.service.ts` |
| read-api reader | none — explicitly retired + projected out; a test asserts it is a forbidden secret | `datasets.go`, `datasets_test.go` |

## Why no "untrack column" step was needed

Hasura v2 does not track individual columns — it tracks **tables** and then
auto-exposes columns unless a permission restricts them. A metadata inconsistency
after a `DROP COLUMN` only arises when metadata **references** the dropped column
(a permission's `columns`/`filter`, a `column_config` custom name, a computed
field, or a relationship mapping). Here `operator_pw_hash` is referenced by **none
of those** — proven by the whole-blob string search returning false — so the drop
cannot make metadata inconsistent, and there was nothing to untrack. (Contrast
`id_user_firebase`, which *is* in the permission's `columns` and `filter`; dropping
it later WILL require editing the permission first.)

## Hardproof (post-drop)

- `information_schema.columns` for `public.users` / `operator_pw_hash` → 0 rows.
- `SELECT operator_pw_hash FROM users` → `ERROR 42703 undefined_column` (expected).
- `SELECT count(*) FROM users` → 8 (table intact, no collateral breakage).

## Reversibility

`01_drop_operator_pw_hash.down.sql` re-adds the nullable column. The 5 historical
hashes are **not** restored — they were write-only, unverifiable, and superseded by
Cognito-only operator auth. Re-provisioning would go through the (also-retired)
set-operator-password path, not a data restore.
