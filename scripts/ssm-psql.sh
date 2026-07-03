#!/bin/sh
# ssm-psql.sh — the proven stdin-safe pattern for running SQL files in
# the timescaledb container via SSM (encodes the docker-exec-without-i
# and heredoc-quoting lessons; see zettel docker-exec-stdin-gotcha).
# Usage on the instance: sh ssm-psql.sh <db> <base64-of-sql>
set -e
DB="$1"; B64="$2"
echo "$B64" | base64 -d > /tmp/ssm-psql-in.sql
docker cp /tmp/ssm-psql-in.sql timescaledb:/tmp/ssm-psql-in.sql
docker exec -i timescaledb psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f /tmp/ssm-psql-in.sql
