# Go-live rehearsal — TimescaleDB-free path, 2026-10-16

Re-rehearses the **database part** of [go-live-bispharma.md](go-live-bispharma.md) after staging dropped TimescaleDB
(ADR-0063 end state) and the transplant was adapted (#1836). The services/box part did not change and stands on the
[2026-10-15 rehearsal](go-live-bispharma-rehearsal-2026-10-15.md). Authorized by the user on 2026-10-16.

**No production change:** a throwaway clone of the prod DB server (r7g.large from the AWS Backup AMI of 2026-10-15
04:13, `ami-0737e5c6d0a2df1d0`, prod DB subnet, SG with no ingress and egress 80/443 only). Staging was read only (one
`REPEATABLE READ READ ONLY` extract, a schema dump, catalog/ACL reads). Legacy was not touched.

## Verdict

**The TS-free DB path is GO.** One defect found and fixed (below); every gate 0.

## Timings (prod server shape, real Bispharma data)

| Step | Time | Notes |
|---|---|---|
| Staging extract | 84 s | 83 files, 2.9 GB COPY text (280 MB gz), +52 s upload |
| Image swap to D2 on prod's pgdata | 10 s to ready | old `packiot` keeps TimescaleDB 2.25.2; `template1` too (hence `TEMPLATE template0`) |
| `roles` → `seqfloor` | **198 s** | `tload` 48 s (13,512,869 rows), `post` 21 s, `seqfloor` 103 s |
| Swap | 564 ms | incl. a 0.5 s pause after terminating sessions; `ALLOW_CONNECTIONS false` first so TimescaleDB workers cannot reconnect |
| `refresh` | **0.26 s** | was 438–563 s with caggs; only `serving.downtime_events_resolved` (3,199 rows) |
| Housekeeping timers | install + 3 units `success` | partition-maintain 143 ms, downtime-resolved 175 ms, data-invariants 2.3 s |
| Rollback | **5.3 s** | timers disabled first; rename back 1.2 s; old image back 4.1 s; old `packiot` 2.25.2, 19,789 POs |

## Gates

| Gate | Result |
|---|---|
| Fingerprints (`fingerprint-diff.py`) | **82/82 equal**, 13,512,843 rows |
| Purity | 0 foreign rows in 55 tenant-keyed tables |
| `compare-catalog` | TOTAL 0 (224 tables, 131 partitions; views = PG15→16 deparse) |
| `compare-acl` | TOTAL 0; retention catalog 26/26; jobs 0/0 (housekeeping is outside the DB) |
| Housekeeping guards | 4 × 0 (no timescaledb in `packiot`, no raw retention, no raw partition keep, partitions ahead) |
| Deploy one-shots (SQL) | `db-schema-f3` guard skips; `knex-baseline.sql` 0 errors (57/57 unique names); `pg_cron` absent → tolerated |
| Invariants | 28/30 ok; L1 (23 endpoints silent — the clone has no live feed) and L2 (L60, the known dead PLC) expected |

**New:** the rolled-back Bispharma DB now **opens under the old 2.25.2 image** (on 10-15 it needed 2.27): it has no
TimescaleDB dependency.

## Defect found

| Defect | Effect | Fix |
|---|---|---|
| `COMMENT ON CONSTRAINT` of a **CHECK** ran before the CHECK existed. The tenant load drops CHECKs and phase `checks` re-adds them after `post` | Before #1836: the comment ran in `pre` and was **silently lost** with the dropped CHECK. After #1836: a `post.sql` ERROR | build.py routes CHECK comments to `90-comments-grants.sql` (after `checks`); the selftest gained a CHECK comment + gate, and a mutant without the fix fails it |

## Incident during the session (staging, self-inflicted, 0.5 s)

Applying ADR-0065 P2 to `hist-gateway`: a heavy union check's client was killed (SSM session cap); its backend inside
the pg_duckdb gateway then died by **SIGPIPE**, and the postmaster reset all sessions (crash recovery 03:49:00.68 →
03:49:01.20 UTC). No restart, no data loss. Rule: stop a gateway query with `pg_cancel_backend()` (statement_timeout
cancels cleanly), never by killing its client; check with literal time bounds (postgres_fdw does not ship `now()`).
P2 was then applied: Bispharma's union identical before/after (3 days).

## Resources

All deleted the same session: instance `i-078f10a00ad4abaeb` (100 GB, delete-on-termination), SG
`sg-021fd5f429d82598f`, S3 `promotion-rehearsal/20261016/` (the extract held api keys), staging host temp files.
