#!/usr/bin/env bash
# Transplant pipeline (rehearsal): rebuild packiot_next from staging's schema. Phases are idempotent by rebuild.
# Usage: [PGC=<container>] xplant.sh [phases...]   default: schema   (schema = create pre hyper views)
# 2026-10-14 rehearsal: `refresh` runs after the swap, when packiot_next no longer exists → XPLANT_DB=packiot.
# PGC = the Postgres container: rehearsal-pg on a clone (default), `timescaledb` on the prod DB host.
# Server-level phases (`roles`, `joblog`) run against the `postgres` DB and touch the whole server (see build.py § 0).
cd "${XPLANT_DIR:-/root/xplant}" || exit 1
PGC=${PGC:-rehearsal-pg}
# XPLANT_DB: the target DB. packiot_next until the swap; AFTER the swap (`refresh`, runbook §5 step 6) it is `packiot`.
XPLANT_DB=${XPLANT_DB:-packiot_next}
PSN="docker exec -i $PGC psql -U postgres -X -d $XPLANT_DB"
run() { f=$1; docker exec -i $PGC sh -c "cat > /tmp/$f" < $f; t0=$(date +%s); $PSN -f /tmp/$f > $f.out 2>&1 < /dev/null; rc=$?; e=$(grep -c 'ERROR:' $f.out)
        echo "== $f: ${e} errors, rc=$rc, $(( $(date +%s)-t0 ))s"; grep 'ERROR:' $f.out | sed 's/psql:[^:]*:[0-9]*: //' | sort | uniq -c | sort -rn | head -${2:-8} | cut -c1-200
        if [ $rc -gt 1 ] || grep -q -E 'connection to server was lost|server closed the connection|terminated abnormally' $f.out; then
          echo "!! ABORT: server crash / connection lost in $f"; grep -E 'lost|closed|abnormally' $f.out | head -3; exit 2; fi; }
runsrv() { f=$1; docker exec -i $PGC sh -c "cat > /tmp/$f" < $f; t0=$(date +%s); docker exec -i $PGC psql -U postgres -X -d postgres -f /tmp/$f > $f.out 2>&1 < /dev/null; rc=$?
        echo "== $f (server-level): rc=$rc, $(( $(date +%s)-t0 ))s"; grep -E 'ERROR:|^role|job_logging' $f.out | cut -c1-200; [ $rc -eq 0 ] || { echo "!! ABORT: $f failed"; exit 2; }; }
for ph in ${@:-create pre hyper views}; do case $ph in
 roles)  runsrv 00-roles.sql;;
 joblog) runsrv 00-joblog.sql;;
 create) docker exec -i $PGC psql -U postgres -X -d postgres -q < /dev/null -c "DROP DATABASE IF EXISTS packiot_next" -c "CREATE DATABASE packiot_next" \
           -c "ALTER DATABASE packiot_next SET search_path = \"\$user\", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public" \
           -c "ALTER DATABASE packiot_next SET track_functions = 'pl'"
         $PSN -q -c "CREATE EXTENSION IF NOT EXISTS timescaledb" < /dev/null 2>&1 | grep -v -E 'WARNING|^$'; echo "== create: ok";;
 pre)    run pre.sql 4;;
 hyper)  run 02-hypertables-caggs.sql; run 03-hyper-keys.sql;;
 views)  run views.sql;;
 copy)   run 04-data-copy.sql 20;;
 post)   run post.sql 20;;
 repair) run 05-repairs.sql 10; grep -E "still inconsistent|overlapping" 05-repairs.sql.out;;
 checks) run 06-checks.sql 30;;
 data)   run 07-data.sql 30;;
 cpack-diff) run 07b-cpack-config-diff.sql 10; grep -vE '^\(|^$' 07b-cpack-config-diff.sql.out | head -200;;   # READ ONLY report
 cpack)  run 07b-cpack-config.sql 10; grep -E 'updated|inserted|deactivated|links|identity|SKIPPED|UNMAPPED' 07b-cpack-config.sql.out;;
 logic)  run 08-logic.sql 20;;
 grants) run 90-comments-grants.sql 10;;
 policies) run 10-policies.sql 10; tail -2 10-policies.sql.out;;
 hasura) docker exec $PGC sh -c "pg_dump -U postgres -d packiot -n hdb_catalog | psql -U postgres -d packiot_next -X -q -v ON_ERROR_STOP=1" < /dev/null > hasura.out 2>&1; echo "== hasura: rc=$?, $(grep -c ERROR hasura.out) errors";;
 refresh) run 11-refresh.sql 10; grep -E "refresh (start|end)|resolved rows" 11-refresh.sql.out;;
 *) echo "unknown phase $ph";;
esac; done
