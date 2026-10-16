#!/usr/bin/env bash
# analytics-housekeeping.sh <job> — the analytics DB's housekeeping on a server WITHOUT pg_cron (the production DB host:
# the D2 TimescaleDB image has no pg_cron, and the new TimescaleDB-free database schedules nothing itself — ADR-0063).
# Staging runs the same statements from pg_cron (scripts/ops/adr0063-c2-pgcron-jobs.sql). Run by
# systemd/analytics-housekeeping@<job>.timer; install with scripts/ops/install-analytics-housekeeping.sh.
#   partition-maintain   SELECT * FROM ops.partition_maintain()  partitions 60 days ahead; drops only past retention keep
#   downtime-resolved    CALL serving.job_refresh_downtime_events_resolved(NULL, NULL)
#   data-invariants      CALL ops.job_data_invariants(NULL, NULL)        (commits per check — must be a top-level CALL)
# purge_analytics_plain is deliberately absent: it deletes data, and prod has no cold tier (decided 2026-10-09).
# Env: PGC (container, default timescaledb), DB (default packiot).
set -euo pipefail
PGC=${PGC:-timescaledb}
DB=${DB:-packiot}
case "${1:-}" in
  partition-maintain) SQL='SELECT * FROM ops.partition_maintain()';;
  downtime-resolved)  SQL='CALL serving.job_refresh_downtime_events_resolved(NULL, NULL)';;
  data-invariants)    SQL='CALL ops.job_data_invariants(NULL, NULL)';;
  *) echo "usage: $0 partition-maintain|downtime-resolved|data-invariants" >&2; exit 2;;
esac
U=$(docker exec "$PGC" printenv POSTGRES_USER 2>/dev/null || echo postgres)
# one statement via -c = autocommit, so the procedures may COMMIT; a crash/timeout is a non-zero exit → unit failed
exec docker exec "$PGC" psql -U "$U" -d "$DB" -X -At -v ON_ERROR_STOP=1 -c "SET application_name = 'housekeeping:$1'" -c "$SQL" < /dev/null
