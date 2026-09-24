#!/usr/bin/env bash
# apply-hardening.sh — T3 historian hardening for a RUNNING hist-gateway (idempotent).
#
# 10-historian-gateway.sh only runs on a FRESH volume; this script brings an existing
# gateway to the same state (and the init script carries the same block for fresh boots).
#
# WHAT: a least-privilege SERVICE identity for read-api + Superset, replacing the
# gateway superuser `postgres`:
#   * historian_readers — NOLOGIN group; set as duckdb.postgres_role, the ONLY way a
#     non-superuser may run pg_duckdb read_parquet (the cold archive). Postmaster-context
#     → persisted via ALTER SYSTEM (postgresql.auto.conf in the data volume) and needs ONE
#     restart. cloudbeaver_histro is deliberately NOT a member (keeps heavy S3 scans off
#     the browser role — the original t282 decision stands).
#   * historian_svc — LOGIN NOSUPERUSER, member of historian_readers; SELECT on the
#     serving schemas (silver, gold, cold, live, public) + default privileges; live_pg FDW
#     user mapping → remote histgw_ro (least-privilege; see
#     db/migrations/t-historian-svc-hardening/01-analytics-histgw-ro.sql), credentials
#     copied SERVER-SIDE from the existing cloudbeaver_histro mapping (never via shell).
#
# Usage (app box, root):  HIST_GW_SVC_PASSWORD=... services/historian-gateway/apply-hardening.sh
#   RESTART=1 (default) restarts hist-gateway when duckdb.postgres_role changed.
set -euo pipefail
: "${HIST_GW_SVC_PASSWORD:?set HIST_GW_SVC_PASSWORD}"
C="${HIST_GW_CONTAINER:-hist-gateway}"; DB="${HIST_GW_DB:-packiot_historian}"
psqlg(){ docker exec -i "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 "$@"; }

psqlg -v svc_pw="$HIST_GW_SVC_PASSWORD" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'historian_readers') THEN
    CREATE ROLE historian_readers NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'historian_svc') THEN
    CREATE ROLE historian_svc LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
  END IF;
END $$;
ALTER ROLE historian_svc PASSWORD :'svc_pw';
GRANT historian_readers TO historian_svc;
COMMENT ON ROLE historian_svc IS
  'Service identity for read-api + Superset historian reads (T3). NOSUPERUSER; cold read_parquet via duckdb.postgres_role=historian_readers; hot via live_pg FDW -> remote histgw_ro.';
GRANT USAGE ON SCHEMA silver, gold, cold, live, public TO historian_svc;
GRANT SELECT ON ALL TABLES IN SCHEMA silver, gold, cold, live, public TO historian_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO historian_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON TABLES TO historian_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA cold   GRANT SELECT ON TABLES TO historian_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA live   GRANT SELECT ON TABLES TO historian_svc;
GRANT USAGE ON FOREIGN SERVER live_pg TO historian_svc;
-- User mappings are PER ROLE (not inherited via historian_readers), for BOTH servers the
-- service needs; cloned SERVER-SIDE (all options, verbatim) so no credential passes the shell:
--   live_pg          <- cloudbeaver_histro's mapping (remote least-privilege histgw_ro)
--   simple_s3_secret <- postgres's mapping (pg_duckdb keeps its S3 secret as a per-role
--                       user mapping; without it read_parquet 403s "No credentials")
DO $$
DECLARE src record; opts text;
BEGIN
  FOR src IN SELECT * FROM (VALUES ('live_pg', 'cloudbeaver_histro'), ('simple_s3_secret', 'postgres')) v(srv, from_role) LOOP
    SELECT string_agg(format('%I %L', split_part(o, '=', 1), substr(o, strpos(o, '=') + 1)), ', ')
      INTO opts
      FROM pg_user_mappings m, unnest(m.umoptions) o
     WHERE m.srvname = src.srv AND m.usename = src.from_role;
    IF opts IS NULL THEN
      RAISE EXCEPTION 'no % mapping on server % to clone', src.from_role, src.srv;
    END IF;
    IF src.srv = 'live_pg' AND opts NOT LIKE '%histgw_ro%' THEN
      RAISE EXCEPTION 'live_pg source mapping is not histgw_ro — provision HISTGW_RO first';
    END IF;
    EXECUTE format('DROP USER MAPPING IF EXISTS FOR historian_svc SERVER %I', src.srv);
    EXECUTE format('CREATE USER MAPPING FOR historian_svc SERVER %I OPTIONS (%s)', src.srv, opts);
  END LOOP;
END $$;
SQL

CUR=$(psqlg -At -c "SELECT coalesce(setting,'') FROM pg_settings WHERE name='duckdb.postgres_role'")
PENDING=$(psqlg -At -c "SELECT coalesce((SELECT setting FROM pg_file_settings WHERE name='duckdb.postgres_role' AND applied IS NOT NULL ORDER BY seqno DESC LIMIT 1),'')")
if [ "$CUR" != "historian_readers" ]; then
  psqlg -c "ALTER SYSTEM SET duckdb.postgres_role = 'historian_readers'"
  echo "[apply-hardening] duckdb.postgres_role '$CUR' -> historian_readers (pending restart; file=$PENDING)"
  if [ "${RESTART:-1}" = 1 ]; then
    docker restart "$C" >/dev/null
    for _ in $(seq 1 60); do
      docker exec "$C" pg_isready -U postgres -q && break; sleep 2
    done
  fi
fi
echo "[apply-hardening] duckdb.postgres_role now: $(psqlg -At -c 'SHOW duckdb.postgres_role')"
