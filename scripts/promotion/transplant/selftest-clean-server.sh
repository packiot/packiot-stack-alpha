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
# 2026-10-16: the fixture is staging's TimescaleDB-FREE shape (ADR-0063 end state; see the fixture comment) and the gates
# add: no timescaledb in the target DB, ops.pc_state + staging's retention catalog travel (hot_raw → forever), staging's
# cold-tier manifest and `__old` objects do not, catch-all rows survive, partitions exist ahead, 0 ERRORs in any phase.
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
docker exec "$SRC" psql -U postgres -Xqc 'CREATE DATABASE packiot_analytics TEMPLATE template0'
# staging's search_path (= xplant.sh `create`): catalog.sql prints regclass text, which depends on it
docker exec "$SRC" psql -U postgres -Xqc "ALTER DATABASE packiot_analytics SET search_path = \"\$user\", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public"
# TS-FREE staging (ADR-0063 end state, 2026-10-16): no timescaledb in the database (the image still ships it, like both real
# servers; template1 carries it, hence TEMPLATE template0 — as xplant.sh `create` does on prod), native RANGE partitions
# with catch-alls + ops.pc_state, former caggs as plain tables the rollup tick writes, a view over one of them, staging's
# own retention catalog (kinds 'plain', cold_copy) and cold-tier manifest, and a staging-only `__old` table with indexes.
psrc -q <<'SQL'
CREATE SCHEMA core; CREATE SCHEMA silver; CREATE SCHEMA ops; CREATE SCHEMA serving;
CREATE ROLE readapi_ro LOGIN;                       -- a role build.py already knew (control)
CREATE TABLE core.enterprises (id_enterprise integer PRIMARY KEY, nm_enterprise text NOT NULL, api_key text, active boolean DEFAULT true);
CREATE TABLE core.equipments (id_equipment serial PRIMARY KEY, id_enterprise integer NOT NULL REFERENCES core.enterprises,
                              nm_equipment text, production_speed numeric CHECK (production_speed >= 0));
CREATE TABLE ops.retention_policy (relation text PRIMARY KEY, kind text NOT NULL CHECK (kind IN ('hypertable','cagg','plain')),
  time_expr text NOT NULL, keep interval, tier text NOT NULL CHECK (tier IN ('hot_raw','hot_agg','business','ops')),
  purge_order int NOT NULL DEFAULT 100, cold_copy text, rationale text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
SQL
for m in t-ts-c3-partition-tooling t-ts-c4-ts-optional t-adr0065-p0-cold-export-gate; do   # the real partition tooling
  psrc -q < "$REPO/db/migrations/$m/01-up.sql" || fail "migration $m did not apply to the fixture"
done
psrc -q <<'SQL'
-- native partitions as ops.pc_swap leaves them: parent + regular partitions + [MINVALUE, first) / [last, MAXVALUE)
CREATE TABLE silver.equipment_events (ts_event timestamptz NOT NULL, id_equipment integer NOT NULL, id_enterprise integer,
  status integer CHECK (status >= 0), PRIMARY KEY (id_equipment, ts_event)) PARTITION BY RANGE (ts_event);
CREATE TABLE silver.equipment_values (ts_value timestamptz NOT NULL, id_equipment integer NOT NULL, id_enterprise integer,
  net_production_incr real, PRIMARY KEY (id_equipment, ts_value)) PARTITION BY RANGE (ts_value);
CREATE INDEX equipment_values_ent_ts ON silver.equipment_values (id_enterprise, ts_value);
SELECT ops.pc_add_partitions('silver.equipment_events', interval '1 month', now() - interval '60 days', now() + interval '60 days');
SELECT ops.pc_add_partitions('silver.equipment_values', interval '7 days', now() - interval '30 days', now() + interval '60 days');
CREATE TABLE silver.equipment_events_pmin PARTITION OF silver.equipment_events FOR VALUES FROM (MINVALUE) TO ('2000-01-01');
INSERT INTO ops.pc_state (rel, twin, capture, time_col, key_cols, step, swapped_at, old_name) VALUES
  ('silver.equipment_events', 'silver.equipment_events__p', 'silver.equipment_events__cc', 'ts_event', '{id_equipment,ts_event}', '1 month', now(), 'silver.equipment_events__ts'),
  ('silver.equipment_values', 'silver.equipment_values__p', 'silver.equipment_values__cc', 'ts_value', '{id_equipment,ts_value}', '7 days', now(), 'silver.equipment_values__ts');
-- a former cagg (ADR-0063 B2: plain table the rollup tick writes) + the ADR-0065 P3a view over it + its staging-only __old
CREATE TABLE silver.equipment_categorical_1min (ts_value timestamptz NOT NULL, id_equipment integer NOT NULL, id_enterprise integer,
  n integer, max_speed real, PRIMARY KEY (id_equipment, ts_value));
CREATE VIEW silver.equipment_metrics_1min AS SELECT ts_value AS bucket, id_equipment, id_enterprise, max_speed FROM silver.equipment_categorical_1min;
CREATE TABLE silver.equipment_metrics_1min__old (bucket timestamptz, id_equipment integer, id_enterprise integer, max_speed real);
CREATE INDEX equipment_metrics_1min_b ON silver.equipment_metrics_1min__old (bucket);   -- keeps its pre-rename name
INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, tier, cold_copy, rationale) VALUES
  ('silver.equipment_values', 'plain', 'ts_value', '90 days', 'hot_raw', 'historian equipment_values (daily cold copy)', 'raw'),
  ('silver.equipment_events', 'plain', 'ts_event', '5 years', 'hot_agg', 'historian equipment_events', 'events'),
  ('silver.equipment_categorical_1min', 'plain', 'ts_value', '90 days', 'hot_raw', NULL, 'minute rollup');
INSERT INTO ops.cold_export (relation, id_enterprise, period_lo, period_hi, uri, rows, verified_at)
  VALUES ('silver.equipment_values', 5, date_trunc('day', now()) - interval '3 days', date_trunc('day', now()) - interval '2 days', 's3://staging/x', 24, now());
-- the two housekeeping procedures the `policies` phase calls (real bodies live in their migrations)
CREATE PROCEDURE serving.job_refresh_downtime_events_resolved(job_id int, config jsonb) LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE PROCEDURE ops.job_data_invariants(job_id int DEFAULT NULL, config jsonb DEFAULT NULL) LANGUAGE plpgsql AS $$ BEGIN END $$;
GRANT USAGE ON SCHEMA core, silver TO readapi_ro;
GRANT SELECT ON core.enterprises, core.equipments, silver.equipment_events, silver.equipment_values,
                silver.equipment_categorical_1min, silver.equipment_metrics_1min TO readapi_ro;
INSERT INTO core.enterprises VALUES (3, 'CPACK', 'k3'), (5, 'Bispharma-Staging', 'k5'), (1000000, 'Packiot Admin', 'ka');
INSERT INTO core.equipments (id_enterprise, nm_equipment, production_speed) VALUES (5, 'L1', 110), (5, 'L2', 90), (3, 'C1', 50);
INSERT INTO silver.equipment_events SELECT now() - make_interval(hours => g), 1 + g % 3, CASE WHEN g % 3 = 2 THEN 3 ELSE 5 END, g % 4 FROM generate_series(1, 200) g;
INSERT INTO silver.equipment_events VALUES ('1999-06-01', 1, 5, 1);   -- lands in the lower catch-all
INSERT INTO silver.equipment_values SELECT now() - make_interval(hours => g), 1 + g % 3, CASE WHEN g % 3 = 2 THEN 3 ELSE 5 END, 1.5 FROM generate_series(1, 500) g;
INSERT INTO silver.equipment_categorical_1min SELECT date_trunc('minute', now()) - make_interval(mins => g), 1 + g % 3, CASE WHEN g % 3 = 2 THEN 3 ELSE 5 END, 1, 100 FROM generate_series(1, 300) g;
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
(XPLANT_DIR="$W/out" PGC="$TGT" TENANT_DIR="$W/tenant5" bash "$W/out/xplant.sh" roles create pre hyper views tload post checks data logic grants tverify policies) \
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
# ── TS-free gates (ADR-0063 end state) ───────────────────────────────────────────────────────────────────────────────
got=$(ptgt -c "SELECT count(*) FROM pg_extension WHERE extname = 'timescaledb'"); [ "$got" = 0 ] || fail "target database has timescaledb"
got=$(ptgt -c "SELECT string_agg(rel || ':' || step, ',' ORDER BY rel) FROM ops.pc_state WHERE swapped_at IS NOT NULL")
[ "$got" = 'silver.equipment_events:1 mon,silver.equipment_values:7 days' ] || fail "ops.pc_state on target: $got"
got=$(ptgt -c "SELECT string_agg(relation || '=' || coalesce(keep::text, 'forever') || ':' || kind, ',' ORDER BY relation) FROM ops.retention_policy")
[ "$got" = 'silver.equipment_categorical_1min=forever:plain,silver.equipment_events=5 years:plain,silver.equipment_values=forever:plain' ] \
  || fail "retention catalog on target (want staging's, hot_raw forever): $got"
got=$(ptgt -c "SELECT count(*) FROM ops.cold_export"); [ "$got" = 0 ] || fail "staging's cold-tier manifest travelled ($got rows)"
got=$(ptgt -c "SELECT count(*) FROM pg_class WHERE relname LIKE '%\_\_old' OR relname = 'equipment_metrics_1min_b'"); [ "$got" = 0 ] || fail "staging-only __old objects on target ($got)"
got=$(ptgt -c "SELECT count(*) FROM silver.equipment_values_pmax"); [ "$got" = 0 ] || fail "rows in the upper catch-all ($got)"
got=$(ptgt -c "SELECT count(*) FROM silver.equipment_events WHERE ts_event < '2000-01-01'"); [ "$got" = 1 ] || fail "lower catch-all row lost ($got)"
got=$(ptgt -c "SELECT count(*) FROM silver.equipment_metrics_1min WHERE id_enterprise <> 5"); [ "$got" = 0 ] || fail "view sees other tenants ($got)"
grep -qE 'partitioned relations without a future partition \(want 0\) *\| *0$' "$W/out/10-policies.sql.out" || { cat "$W/out/10-policies.sql.out"; fail 'policies: partitions ahead'; }
grep -qE 'raw partitioned relations with a keep \(want 0\) *\| *0$' "$W/out/10-policies.sql.out" || fail 'policies: raw retention still armed'
for f in pre post 04t-tenant-load 06-checks 07-data 08-logic 10-policies 12t-tenant-verify; do
  e=$(grep -c 'ERROR:' "$W/out/$f.sql.out" 2>/dev/null || true); [ "${e:-0}" = 0 ] || { grep 'ERROR:' "$W/out/$f.sql.out" | head -5; fail "$f had $e errors"; }
done
echo "SELFTEST OK — TS-free clean-server build: roles, catalog, ACL, tenant fingerprints, partitions, retention, no timescaledb"
