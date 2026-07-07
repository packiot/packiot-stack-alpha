# Backup & restore runbook — decision memo + PITR drill (B5 prep)

- **Status**: PREPARED 2026-07-07 (Phase B5 / G-track). The tool
  decision below is a recommendation for the decider; the drill is
  ready to execute on any scratch instance. ADR-0017 §3: *"a restore
  drill is part of the definition of done — an untested backup is a
  hope, not a backup."*
- **Scope**: the consolidated DB (`packiot_shadow`, promoted at flip)
  on DB EC2 `i-064bb36d1c454d861` (timescaledb container, single node).

## 1. What we have today (and why it is not enough)

| Layer | Exists | Gap |
|---|---|---|
| EBS snapshots (daily, from the 2026-06-22 disk incident) | ✅ | crash-consistent volume images: RPO = up to 24h, no point-in-time, restore = whole volume |
| Docker named volume for pgdata | ✅ | not a backup at all |
| WAL archiving / PITR | ❌ | **the gap**: any logical corruption (bad migration, runaway DELETE) between snapshots is unrecoverable-to-the-minute |

## 2. Tool decision: **pgBackRest** (recommended) vs wal-g

| Criterion | pgBackRest | wal-g |
|---|---|---|
| TimescaleDB blessing | official Timescale self-hosted docs use it | works, less documented |
| Restore ergonomics | delta restore (only changed files), parallel | full-fetch oriented |
| Backup types | full + differential + incremental | full + delta |
| Config surface | one INI, runs fine in a sidecar container | env-var driven, simpler but thinner |
| Verification | `pgbackrest verify` built in | manual |
| S3 target | native | native |

**Recommendation: pgBackRest.** The deciding factors are delta restore
(matters at our 40GB+ and growing) and built-in verify (G-track wants
scheduled verification, not just scheduled backup). wal-g would also
work; do not relitigate without a new constraint. Industry note: both
are standard; the anti-pattern would be hand-rolled `pg_dump` cron —
pg_dump is a logical export, not PITR, and is already blocked on prod.

## 3. Target architecture (single-node, sidecar pattern)

- `pgbackrest` sidecar container sharing the pgdata volume + a config
  mount; repo target = S3 bucket `packiot-db-backups` (new, versioned,
  same-region), `repo1-retention-full=2`, `repo1-retention-diff=7`.
- postgres container gains: `archive_mode=on`,
  `archive_command='pgbackrest --stanza=packiot archive-push %p'`
  (requires ONE postgres restart — schedule with a deploy, not mid-bake).
- Cadence: weekly full (Sun 03:00 UTC), daily diff, WAL continuous.
  RPO target: ≤5 min (WAL). RTO target: ≤60 min to last-diff + WAL.
- EBS snapshots STAY (belt: volume-level DR for instance loss;
  pgBackRest is the suspenders: PITR for logical damage).

## 4. The restore drill (quarterly; first run = B5 exit criterion)

1. Launch a scratch EC2 (same AZ, t3.large is fine) or a second
   compose project on the DB EC2 if disk allows (42% used — check).
2. `pgbackrest --stanza=packiot restore --type=time
   "--target=<T-15min>" --target-action=promote` into an empty pgdata.
3. Start postgres on it; verify: (a) `SELECT max(ts_value) FROM
   equipment_values` lands within 5 min of the target time; (b) the
   TimescaleDB extension version matches; (c) one CAgg refreshes
   (`CALL refresh_continuous_aggregate(...)`); (d) row counts on the
   5 core tables vs the source at target time (±ingest window).
4. Record: wall-clock RTO, restored size, surprises → this file's
   changelog. Destroy the scratch instance.
5. FAILURE = a G-track P0. A drill that "mostly worked" did not work.

## 5. Timing constraints (respect the clocks)

- The postgres restart for `archive_mode` must NOT land during a bake
  window (it prints an ingest gap on the comparison surfaces). Slot it
  with the flip deploy or immediately after soak start.
- Everything else here (bucket, sidecar image, stanza config, drill on
  a scratch instance) touches nothing being baked — safe anytime.

## 6. Cost note

S3 (IA after 30d) at current DB size ≈ single-digit $/month; the
scratch-instance drill ≈ $1/run. Cheap insurance against the only
failure class the whole differential-bake program cannot catch:
losing the database itself.
