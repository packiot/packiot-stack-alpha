#!/usr/bin/env bash
# ADR-0065 P0 gate test on plain postgres:15 with the real C3 partition tooling. Usage: bash run.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
docker rm -f p0gate >/dev/null 2>&1 || true
docker run -d --name p0gate -e POSTGRES_PASSWORD=x postgres:15-alpine >/dev/null
until docker exec p0gate pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
P() { docker exec -i p0gate psql -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
P <<'SQL'
CREATE SCHEMA ops; CREATE SCHEMA silver;
CREATE TABLE ops.retention_policy (relation text PRIMARY KEY, kind text, time_expr text, keep interval, tier text,
  purge_order int, cold_copy text, rationale text, updated_at timestamptz DEFAULT now());
SQL
P < migrations/t-ts-c3-partition-tooling/01-up.sql >/dev/null
P <<'SQL'
-- fixture: built by the real tooling — aligned weekly partitions 125 days back .. 70 days ahead + catch-alls
CREATE TABLE silver.ev (id_enterprise int NOT NULL, ts timestamptz NOT NULL, v int, PRIMARY KEY (id_enterprise, ts)) PARTITION BY RANGE (ts);
SELECT ops.pc_add_partitions('silver.ev', '7 days', now() - interval '125 days', now() + interval '70 days');
DO $$ DECLARE lo timestamptz; BEGIN
  SELECT min(b.lo) INTO lo FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b WHERE i.inhparent = 'silver.ev'::regclass AND NOT b.hi_max;
  EXECUTE format('CREATE TABLE silver.ev_pmin PARTITION OF silver.ev FOR VALUES FROM (MINVALUE) TO (%L)', lo);
END $$;
INSERT INTO silver.ev SELECT e, g, 1 FROM unnest(ARRAY[3, 5, 2000003]) e,
  generate_series((SELECT min(b.lo) FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b WHERE i.inhparent = 'silver.ev'::regclass AND NOT b.lo_min AND NOT b.hi_max) + interval '1 hour', now() - interval '1 hour', interval '1 day') g;
INSERT INTO ops.pc_state (rel, twin, capture, time_col, key_cols, step, copied, prepared_at, swapped_at)
VALUES ('silver.ev', 'silver.ev__p', 'silver.ev__cc', 'ts', ARRAY['id_enterprise','ts'], '7 days', '{}', now(), now());
INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, cold_copy) VALUES ('silver.ev', 'plain', 'ts', '90 days', 'historian ev');
SQL
P < migrations/t-adr0065-p0-cold-export-gate/01-up.sql >/dev/null
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; P -c "SELECT '  blocked: ' || part || ' ' || coalesce(lo::date::text,'-') || '..' || hi::date || ' unc=' || uncovered FROM ops.partition_drop_blocked ORDER BY lo NULLS FIRST"; FAILED=1; fi; }
FAILED=0
ROWS0=$(P -c "SELECT count(*) FROM silver.ev")
ok "T0 lower catch-all starts empty" "$(P -c "SELECT count(*) FROM silver.ev_pmin")" "0"
# T1: no exports → oldest partition blocked, nothing dropped, rows intact
ok "T1 no export blocks" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "0/1"
ok "T1 rows intact" "$(P -c "SELECT count(*) FROM silver.ev")" "$ROWS0"
O1=$(P -c "SELECT c.oid::regclass FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid, LATERAL ops.pc_bounds(c.oid) b WHERE i.inhparent='silver.ev'::regclass AND NOT b.lo_min AND NOT b.hi_max ORDER BY b.lo LIMIT 1")
O2=$(P -c "SELECT c.oid::regclass FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid, LATERAL ops.pc_bounds(c.oid) b WHERE i.inhparent='silver.ev'::regclass AND NOT b.lo_min AND NOT b.hi_max ORDER BY b.lo OFFSET 1 LIMIT 1")
O1_LO=$(P -c "SELECT lo FROM ops.pc_bounds('$O1'::regclass)"); O1_HI=$(P -c "SELECT hi FROM ops.pc_bounds('$O1'::regclass)")
UNC=$(P -c "SELECT count(DISTINCT (id_enterprise, (ts AT TIME ZONE 'UTC')::date)) FROM $O1 WHERE id_enterprise <> 2000003")
ok "T1 blocked row = oldest partition, all its non-exempt tenant-days" "$(P -c "SELECT part||':'||uncovered FROM ops.partition_drop_blocked")" "$O1:$UNC"
# T2: an UNVERIFIED export does not open the gate
P -c "INSERT INTO ops.cold_export (relation, id_enterprise, period_lo, period_hi, uri, rows) SELECT 'silver.ev', e, '$O1_LO', '$O1_HI', 's3://x', 7 FROM unnest(ARRAY[3,5]) e"
ok "T2 unverified keeps blocking" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "0/1"
# T3: verify ent 3 only → still blocked (ent 5 uncovered); sandbox never counts
P -c "UPDATE ops.cold_export SET verified_at = now() WHERE id_enterprise = 3"
ok "T3 one tenant missing" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "0/1"
ok "T3 uncovered = ent 5's days only" "$(P -c "SELECT uncovered FROM ops.partition_drop_blocked")" "$(P -c "SELECT count(DISTINCT (ts AT TIME ZONE 'UTC')::date) FROM $O1 WHERE id_enterprise = 5")"
# T4: verify ent 5 → old1 dropped, old2 blocked (stops there), catch-all re-seated (it was empty)
P -c "UPDATE ops.cold_export SET verified_at = now() WHERE id_enterprise = 5"
ok "T4 drop then block" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "1/1"
ok "T4 oldest gone" "$(P -c "SELECT to_regclass('$O1') IS NULL")" "t"
ok "T4 pmin re-seated at the next partition" "$(P -c "SELECT hi = (SELECT lo FROM ops.pc_bounds('$O2'::regclass)) FROM ops.pc_bounds('silver.ev_pmin'::regclass)")" "t"
ok "T4 blocked row moved to the next partition" "$(P -c "SELECT string_agg(part, ',') FROM ops.partition_drop_blocked")" "$O2"
ok "T4 inserting an old row still lands (pmin)" "$(P -c "INSERT INTO silver.ev VALUES (5, now() - interval '200 days', 1) RETURNING 1")" "1"
# T5: cold_copy NULL → drops like before (old2), pmin now has a row but no gate → re-seated (row dropped by design)
P -c "UPDATE ops.retention_policy SET cold_copy = NULL"
NOLD=$(P -c "SELECT count(*) FROM pg_inherits i, LATERAL ops.pc_bounds(i.inhrelid) b WHERE i.inhparent='silver.ev'::regclass AND NOT b.lo_min AND NOT b.hi_max AND b.hi <= now() - interval '90 days'")
ok "T5 no cold copy by design: all old partitions drop" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "$NOLD/0"
# T6: gated again; a row in the lower catch-all without an export must survive the next re-seat
P -c "UPDATE ops.retention_policy SET cold_copy = 'historian ev'"
P -c "INSERT INTO silver.ev VALUES (5, now() - interval '400 days', 1)"
P -c "UPDATE ops.retention_policy SET keep = '60 days'"
O3=$(P -c "SELECT c.oid::regclass FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid, LATERAL ops.pc_bounds(c.oid) b WHERE i.inhparent='silver.ev'::regclass AND NOT b.lo_min AND NOT b.hi_max ORDER BY b.lo LIMIT 1")
P -c "INSERT INTO ops.cold_export (relation, id_enterprise, period_lo, period_hi, uri, rows, verified_at) SELECT 'silver.ev', e, lo, hi, 's3://y', 1, now() FROM ops.pc_bounds('$O3'::regclass), unnest(ARRAY[3,5]) e"
ok "T6 next partition drops, catch-all blocked" "$(P -c "SELECT dropped||'/'||blocked FROM ops.partition_maintain() WHERE rel='silver.ev'")" "1/2"
ok "T6 the old catch-all row is kept" "$(P -c "SELECT count(*) FROM silver.ev WHERE ts < now() - interval '300 days'")" "1"
ok "T6 blocked rows: catch-all + next partition" "$(P -c "SELECT count(*) FROM ops.partition_drop_blocked")" "2"
docker rm -f p0gate >/dev/null
[ "$FAILED" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
