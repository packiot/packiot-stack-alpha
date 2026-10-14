#!/bin/sh
# First-boot hook (docker-entrypoint-initdb.d, after the seed loader 50-devseed.sh): create each Go service's
# least-privilege login (db/migrations/t-<service>-role) with the dev password "dev". Needed while the published
# seed predates a role; once staging has it, the seed carries it (dev/seed/extract.sh copies roles, load.sh sets
# "dev") and this is a no-op re-run of an idempotent migration. Skipped on a non-seed DEVDB_IMAGE.
# Add a service here when its t-<service>-role migration lands (role name = service with - → _).
set -eu
SERVICES="operator-gateway barcode-service stream-engine legacy-replicator"
q() { psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"; }
if [ "$(q -tAc "SELECT to_regclass('core.equipments') IS NOT NULL")" != t ]; then
  echo "70-service-roles: no core.equipments (not a seed image) — skipped"
  exit 0
fi
for svc in $SERVICES; do
  role=$(echo "$svc" | tr - _)
  q -q -f "/devseed-migrations/t-$svc-role/01-up.sql"
  q -q -c "ALTER ROLE $role PASSWORD 'dev'"
  echo "70-service-roles: $role ready (password dev)"
done
