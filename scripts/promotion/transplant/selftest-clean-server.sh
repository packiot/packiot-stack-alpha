#!/usr/bin/env bash
# selftest-clean-server.sh — rehearsal-style check of the CLEAN-server go-live build (build.py TRANSPLANT_MODE=tenant +
# bispharma/tenant_extract.py + xplant.sh) on two throwaway local containers. Touches no real database.
#
#   scripts/promotion/transplant/selftest-clean-server.sh        (needs docker, git with origin/staging; ~1 min)
#
# WHY (2026-10-15): build.py stops ("staging grants/owners reference roles the target lacks") when staging's schema dump
# GRANTs to a role the target server lacks and phase `roles` does not create. db/migrations/t-prod-reflector-roles
# (ADR-0064) adds two such roles on staging; t-enterprise-codes adds core.enterprises.code (NOT NULL, UNIQUE, CHECK,
# immutable trigger). This builds a MINI staging (real migrations applied on top of a small fixture), dumps it, builds,
# and runs the window's phases on a CLEAN server, then the same gates as the go-live:
#   build succeeds, 00-roles.sql creates prod_reflector_ro + prod_reflector with the migration's shape;
#   no phase reports "role … does not exist"; compare-catalog TOTAL 0; compare-acl TOTAL 0;
#   tenant 5 extract → load → verify fingerprints identical (fingerprint-diff.py) and ent 5 keeps code 'bispharma'.
# Data lives under ${SELFTEST_DIR:-/var/tmp}; KEEP=1 keeps it (and prints the path). Containers are always removed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel)
IMG=${SELFTEST_IMAGE:-timescale/timescaledb:2.25.2-pg16}
W=$(mktemp -d "${SELFTEST_DIR:-/var/tmp}/xplant-selftest.XXXXXX")
SRC=xplant-selftest-src-$$ TGT=xplant-selftest-tgt-$$
cleanup() { docker rm -f "$SRC" "$TGT" >/dev/null 2>&1 || true; if [ -n "${KEEP:-}" ]; then echo "kept $W"; else rm -rf "$W"; fi; }
trap cleanup EXIT
fail() { echo "SELFTEST FAIL: $*"; exit 1; }

for c in "$SRC" "$TGT"; do docker run -d --name "$c" -e POSTGRES_PASSWORD=selftest "$IMG" >/dev/null; done
for c in "$SRC" "$TGT"; do   # TCP only answers after initdb's temporary socket-only server is gone
  for _ in $(seq 60); do docker exec "$c" psql -U postgres -h 127.0.0.1 -Atqc 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
done
psrc() { docker exec -i "$SRC" psql -U postgres -X -v ON_ERROR_STOP=1 -d packiot_analytics "$@"; }

# ── mini staging: fixture + the REAL migrations under test ───────────────────────────────────────────────────────────
docker exec "$SRC" psql -U postgres -Xqc 'CREATE DATABASE packiot_analytics'
# staging's search_path (= xplant.sh `create`): catalog.sql prints regclass text, which depends on it
docker exec "$SRC" psql -U postgres -Xqc "ALTER DATABASE packiot_analytics SET search_path = \"\$user\", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public"
psrc -q <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE SCHEMA core; CREATE SCHEMA silver; CREATE SCHEMA ops;
CREATE ROLE readapi_ro LOGIN;                       -- a role build.py already knew (control)
CREATE TABLE core.enterprises (id_enterprise integer PRIMARY KEY, nm_enterprise text NOT NULL, api_key text, active boolean DEFAULT true);
CREATE TABLE core.equipments (id_equipment serial PRIMARY KEY, id_enterprise integer NOT NULL REFERENCES core.enterprises,
                              nm_equipment text, production_speed numeric CHECK (production_speed >= 0));
CREATE TABLE silver.equipment_events (ts_event timestamptz NOT NULL, id_equipment integer NOT NULL, status integer);
SELECT FROM create_hypertable('silver.equipment_events', 'ts_event', chunk_time_interval => INTERVAL '1 day');
CREATE MATERIALIZED VIEW silver.ca_events_1h WITH (timescaledb.continuous) AS
  SELECT time_bucket('1 hour', ts_event) AS bucket, id_equipment, count(*) AS n FROM silver.equipment_events GROUP BY 1, 2 WITH NO DATA;
CREATE TABLE ops.retention_policy (relation text PRIMARY KEY, tier text, keep interval);
GRANT USAGE ON SCHEMA core, silver TO readapi_ro;
GRANT SELECT ON core.enterprises, core.equipments, silver.equipment_events, silver.ca_events_1h TO readapi_ro;
INSERT INTO core.enterprises VALUES (3, 'CPACK', 'k3'), (5, 'Bispharma-Staging', 'k5'), (1000000, 'Packiot Admin', 'ka');
INSERT INTO core.equipments (id_enterprise, nm_equipment, production_speed) VALUES (5, 'L1', 110), (5, 'L2', 90), (3, 'C1', 50);
INSERT INTO silver.equipment_events SELECT now() - make_interval(hours => g), 1 + g % 3, g % 4 FROM generate_series(1, 200) g;
SQL
for m in t-enterprise-codes t-prod-reflector-roles; do
  psrc -q < "$REPO/db/migrations/$m/01-up.sql" || fail "migration $m did not apply to the fixture"
done
[ "$(psrc -Atc "SELECT count(*) FROM information_schema.role_table_grants WHERE grantee IN ('prod_reflector','prod_reflector_ro')")" -gt 0 ] \
  || fail 'fixture has no GRANTs to the prod-reflector roles (the case under test)'

# ── inputs, exactly as the window collects them ──────────────────────────────────────────────────────────────────────
psrc -At < "$HERE/catalog.sql" > "$W/cat-stg.json"
docker exec -i "$TGT" psql -U postgres -X -At -d postgres < "$HERE/catalog.sql" > "$W/cat-prod.json"   # the clean server
docker exec "$SRC" pg_dump -U postgres --schema-only -Fc -d packiot_analytics -f /tmp/stg-schema.dump
docker cp "$SRC:/tmp/stg-schema.dump" "$W/stg-schema.dump" >/dev/null
grep -q 'prod_reflector_ro' <(docker exec "$SRC" pg_restore -f - /tmp/stg-schema.dump) || fail 'dump carries no prod_reflector_ro GRANT'

# ── build (the step that used to stop) + tenant generator ────────────────────────────────────────────────────────────
(cd "$REPO" && TRANSPLANT_MODE=tenant python3 "$HERE/build.py" "$W") > "$W/build.log" 2>&1 || { cat "$W/build.log"; fail 'build.py failed'; }
python3 "$REPO/scripts/promotion/bispharma/tenant_extract.py" "$W" --enterprise 5 --dir /tmp/tenant5 > "$W/tenant.log" || fail 'tenant_extract.py failed'
for r in prod_reflector_ro prod_reflector; do grep -q "CREATE ROLE $r NOLOGIN" "$W/out/00-roles.sql" || fail "00-roles.sql does not create $r"; done

# ── extract on the mini staging, then the window's phases on the clean server ────────────────────────────────────────
psrc -q -f - < "$W/tenant/extract.sql" > "$W/extract.out" || fail 'extract failed'
docker cp "$SRC:/tmp/tenant5" "$W/tenant5" >/dev/null
(XPLANT_DIR="$W/out" PGC="$TGT" TENANT_DIR="$W/tenant5" bash "$W/out/xplant.sh" roles create pre hyper views tload post checks logic grants tverify) \
  | tee "$W/xplant.log"
grep -h 'ERROR:' "$W"/out/*.out | grep -i 'role .* does not exist' && fail 'a phase hit a missing role'
grep -q '!! ABORT' "$W/xplant.log" && fail 'xplant aborted'

# ── gates ────────────────────────────────────────────────────────────────────────────────────────────────────────────
ptgt() { docker exec -i "$TGT" psql -U postgres -X -At -d packiot_next "$@"; }
ptgt < "$HERE/catalog.sql" > "$W/cat-next.json"
psrc -At < "$HERE/acl.sql" > "$W/acl-stg.json"; ptgt < "$HERE/acl.sql" > "$W/acl-next.json"
python3 "$HERE/compare-catalog.py" "$W/cat-stg.json" "$W/cat-next.json" | tee "$W/catalog.diff" | tail -1
grep -q 'TOTAL missing+different .* = 0$' "$W/catalog.diff" || { cat "$W/catalog.diff"; fail 'catalog gate'; }
python3 "$HERE/compare-acl.py" "$W/acl-stg.json" "$W/acl-next.json" | tee "$W/acl.diff" | tail -1
grep -q '= 0$' "$W/acl.diff" && grep -q '^rolesettings equal' "$W/acl.diff" || { cat "$W/acl.diff"; fail 'ACL gate'; }
python3 "$REPO/scripts/promotion/bispharma/fingerprint-diff.py" "$W/extract.out" "$W/out/12t-tenant-verify.sql.out" || fail 'tenant fingerprints differ'
got=$(ptgt -c "SELECT string_agg(id_enterprise || '=' || code, ',' ORDER BY id_enterprise) FROM core.enterprises")
[ "$got" = '5=bispharma,1000000=packiot-admin' ] || fail "enterprise codes on target: $got"
got=$(ptgt -c "SELECT rolname || ':' || rolcanlogin || ':' || (rolpassword IS NULL) || ':' || rolinherit || ':' || rolconnlimit || ':' ||
                      coalesce((SELECT array_to_string(setconfig, ';') FROM pg_db_role_setting s WHERE s.setrole = a.oid AND s.setdatabase = 0), '')
                 FROM pg_authid a WHERE rolname LIKE 'prod_reflector%' ORDER BY 1" | tr '\n' ' ')
[ "$got" = 'prod_reflector:true:true:false:8: prod_reflector_ro:true:true:false:6:default_transaction_read_only=on;statement_timeout=120s ' ] || fail "role shape: $got"
got=$(ptgt -c "SELECT has_table_privilege('prod_reflector_ro', 'core.enterprises', 'SELECT'), has_table_privilege('prod_reflector_ro', 'core.enterprises', 'UPDATE'),
                      has_column_privilege('prod_reflector', 'core.enterprises', 'api_key', 'UPDATE')")
[ "$got" = 't|f|f' ] || fail "prod_reflector grants on target: $got"
echo "SELFTEST OK — clean-server build with prod-reflector GRANTs + enterprise codes: roles, catalog, ACL and tenant gates pass"
