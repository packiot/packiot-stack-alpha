#!/bin/sh
# First-boot hook (docker-entrypoint-initdb.d, after the seed loader 50-devseed.sh): create operator-gateway's
# least-privilege login (db/migrations/t-operator-gateway-role) with the dev password "dev". Needed while the
# published seed predates the role; once staging has it, the seed carries it (dev/seed/extract.sh copies roles,
# load.sh sets "dev") and this is a no-op re-run of an idempotent migration. Skipped on a non-seed DEVDB_IMAGE.
set -eu
q() { psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"; }
if [ "$(q -tAc "SELECT to_regclass('core.topic_routing') IS NOT NULL")" = t ]; then
  q -q -f /devseed-migrations/t-operator-gateway-role/01-up.sql
  q -q -c "ALTER ROLE operator_gateway PASSWORD 'dev'"
  echo "70-operator-gateway-role: operator_gateway ready (password dev)"
else
  echo "70-operator-gateway-role: no core.topic_routing (not a seed image) — skipped"
fi
