#!/usr/bin/env bash
# prod-knex-f3-reconcile-check.sh — ROADMAP W1.5 CORRECTNESS GATE.
#
# Proves edge-api's knex migrations (`db-migrate`) did NOT rebuild the legacy F1
# schema over the proven F3-as-`public` schema (`db-schema-f3`). It is the
# post-knex companion to scripts/prod-f3-schema-parity-check.sh:
#
#   prod-f3-schema-parity-check.sh   → F3 == public  (run AFTER db-schema-f3,
#                                       BEFORE knex; exact column fingerprints).
#   prod-knex-f3-reconcile-check.sh  → knex didn't CLOBBER F3 (run AFTER
#                                       db-migrate; column-SUBSET + classification).
#
# Why a second gate? The prod schema is the UNION  F3 ∪ edge-api-operational
# objects: knex legitimately ADDS a few columns/tables F3 lacks but edge-api
# needs at runtime (production_orders.id_label, users.operator_pw_hash, labels,
# sample_boxes, scanned_boxes, idempotency_keys, mirror_replay_dlq). The md5
# fingerprint gate cannot tell an ADDED column (benign) from a DROPPED/CHANGED
# one (a real F1 rebuild) — both just change the hash. This gate compares at
# COLUMN granularity and asserts the load-bearing property:
#
#   CLOBBER = 0   ⇔  every (table, column, type) in the F3 target still exists,
#                    unchanged, in the candidate.  Additive columns are allowed.
#
# Two independent checks:
#   (A) CLASSIFICATION  — every edge-api migration is either fake-baselined
#       (db/init-f3/knex-baseline.sql) or in the expected RUN allowlist below.
#       A new, unclassified migration FAILS the gate (forces a human decision).
#   (B) COLUMN-INTEGRITY — F3 target column-set ⊆ candidate column-set, per table
#       (+ the RUN-set edge-api tables are present in the candidate).
#
# READ-ONLY. Both DSNs are SELECT-only in effect (only \d-style catalog reads).
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   # (A) classification only (no DB needed):
#   MIGRATIONS_DIR=./edge-api/migrations ./scripts/prod-knex-f3-reconcile-check.sh classify
#
#   # (B) column-integrity: F3 target vs the post-knex candidate:
#   F3_TARGET_DSN='postgresql://postgres:postgres@localhost:5604/packiot' \
#   CANDIDATE_DSN='postgresql://postgres:postgres@localhost:5599/packiot' \
#     ./scripts/prod-knex-f3-reconcile-check.sh columns
#
#   # both (the gate):
#   MIGRATIONS_DIR=./edge-api/migrations F3_TARGET_DSN=... CANDIDATE_DSN=... \
#     ./scripts/prod-knex-f3-reconcile-check.sh gate
#
# F3_TARGET_DSN = a DB carrying the pure F3 column shape (db-schema-f3 output, or
# a plain-postgres apply of db/init-f3/snapshot/00-*.sql — the base-table columns
# are the entire knex-clobber surface). CANDIDATE_DSN = the DB after db-schema-f3
# THEN db-migrate.
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-./edge-api/migrations}"
BASELINE_SQL="${BASELINE_SQL:-$(dirname "$0")/../db/init-f3/knex-baseline.sql}"
F3_TARGET_DSN="${F3_TARGET_DSN:-}"
CANDIDATE_DSN="${CANDIDATE_DSN:-}"

# Migrations knex is EXPECTED to apply on top of F3 (everything not fake-baselined).
# Kept explicit so classify() can prove FAKE ∪ RUN == every migration file.
RUN_ALLOWLIST="$(cat <<'EOF'
20260409000001_create_labels.ts
20260409000002_create_sample_boxes.ts
20260409000003_create_scanned_boxes.ts
20260413000001_add_id_label_to_production_orders.ts
20260413000002_fix_scanned_boxes.ts
20260413000003_production_orders_equipment_run_idx.ts
20260413000004_add_id_plc_to_equipments.ts
20260414000001_add_active_to_sites_and_areas.ts
20260414000002_create_shifts.ts
20260414000003_add_active_to_equipments.ts
20260420000001_create_pages.ts
20260611000001_add_nm_production_order.ts
20260626000001_mirror_replay_dlq_add_retry_columns.ts
20260630235959_create_uns_equipment_current_metrics.ts
20260707120000_add_operator_pw_hash_to_users.ts
20260707180000_create_idempotency_keys.ts
EOF
)"

# Tables the RUN set must materialise in the candidate (F3 lacks them).
RUN_NEW_TABLES="labels sample_boxes scanned_boxes idempotency_keys mirror_replay_dlq"

# ── Column manifest: one "<table>\t<col>\t<type>" line per user column ─────────
read -r -d '' COLS_SQL <<'SQL' || true
\pset pager off
\pset tuples_only on
\pset format unaligned
\pset fieldsep '\t'
WITH ext_objs AS (SELECT objid FROM pg_depend WHERE deptype='e')
SELECT c.relname||chr(9)||a.attname||chr(9)||format_type(a.atttypid,a.atttypmod)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_attribute a ON a.attrelid=c.oid
 WHERE n.nspname='public' AND c.relkind='r'
   AND a.attnum>0 AND NOT a.attisdropped
   AND c.oid NOT IN (SELECT objid FROM ext_objs)
   AND c.relname NOT IN ('knex_migrations','knex_migrations_lock')
 ORDER BY c.relname, a.attname;
SQL

psql_cols() { printf '%s' "$COLS_SQL" | psql "$1" -v ON_ERROR_STOP=1 2>/dev/null | grep -aP '\t' || true; }

fake_set() {
  # migration filenames seeded by knex-baseline.sql (the fake-apply set)
  grep -oE "'[0-9]{14}_[a-z0-9_]+\.ts'" "$BASELINE_SQL" | tr -d "'" | sort -u
}

classify() {
  local rc=0 files fake run
  files=$(cd "$MIGRATIONS_DIR" && ls -1 *.ts | sort -u)
  fake=$(fake_set)
  run=$(printf '%s\n' "$RUN_ALLOWLIST" | sed '/^$/d' | sort -u)
  echo "=== CLASSIFICATION (every migration must be FAKE xor RUN) ==="
  echo "  files=$(printf '%s\n' "$files" | wc -l | tr -d ' ')  fake=$(printf '%s\n' "$fake" | wc -l | tr -d ' ')  run=$(printf '%s\n' "$run" | wc -l | tr -d ' ')"
  local overlap; overlap=$(comm -12 <(printf '%s\n' "$fake") <(printf '%s\n' "$run"))
  if [ -n "$overlap" ]; then echo "  FAIL: in BOTH fake and run:"; echo "$overlap" | sed 's/^/    /'; rc=1; fi
  local unclassified; unclassified=$(comm -23 <(printf '%s\n' "$files") <(printf '%s\n' "$fake" "$run" | sort -u))
  if [ -n "$unclassified" ]; then echo "  FAIL: UNCLASSIFIED migration(s) — classify in knex-baseline.sql or RUN_ALLOWLIST:"; echo "$unclassified" | sed 's/^/    /'; rc=1; fi
  local ghost; ghost=$(comm -13 <(printf '%s\n' "$files") <(printf '%s\n' "$fake" "$run" | sort -u))
  if [ -n "$ghost" ]; then echo "  FAIL: classified name not on disk:"; echo "$ghost" | sed 's/^/    /'; rc=1; fi
  [ "$rc" -eq 0 ] && echo "  PASS — all $(printf '%s\n' "$files" | wc -l | tr -d ' ') migrations classified, no overlap."
  return $rc
}

columns() {
  [ -n "$F3_TARGET_DSN" ] && [ -n "$CANDIDATE_DSN" ] || { echo "F3_TARGET_DSN + CANDIDATE_DSN required" >&2; exit 2; }
  local t c; t=$(mktemp); c=$(mktemp)
  psql_cols "$F3_TARGET_DSN" | sort -u > "$t"
  psql_cols "$CANDIDATE_DSN" | sort -u > "$c"
  echo "=== COLUMN-INTEGRITY (F3 target columns ⊆ candidate columns) ==="
  echo "  target_cols=$(wc -l < "$t" | tr -d ' ')  candidate_cols=$(wc -l < "$c" | tr -d ' ')"
  local clobber; clobber=$(comm -23 "$t" "$c")
  local nclob; nclob=$(printf '%s' "$clobber" | grep -c . || true)
  echo
  echo "  --- CLOBBER (F3 column DROPPED or TYPE-CHANGED by knex = F1 rebuild) ---"
  if [ "$nclob" -gt 0 ]; then printf '%s\n' "$clobber" | sed 's/^/    LOST  /'; fi
  echo "  --- ADDITIVE (edge-api columns/tables added on top of F3 — expected) ---"
  comm -13 "$t" "$c" | sed 's/^/    ADD   /' | head -80
  echo
  local rc=0
  echo "  --- RUN-set edge-api tables present in candidate? ---"
  for tbl in $RUN_NEW_TABLES; do
    if grep -qP "^${tbl}\t" "$c"; then echo "    OK    $tbl"; else echo "    MISS  $tbl (expected from RUN set)"; rc=1; fi
  done
  echo
  echo "  CLOBBER = $nclob"
  if [ "$nclob" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "  PASS — no F3 column lost/changed; edge-api tables present. F3 intact under knex."
    rm -f "$t" "$c"; return 0
  else
    echo "  FAIL — knex clobbered F3 or an edge-api table is missing."
    rm -f "$t" "$c"; return 1
  fi
}

cmd="${1:-help}"
case "$cmd" in
  classify) classify ;;
  columns)  columns ;;
  gate)     classify && columns ;;
  *) sed -n '2,45p' "$0" ;;
esac
