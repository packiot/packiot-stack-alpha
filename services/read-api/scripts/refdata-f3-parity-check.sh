#!/usr/bin/env bash
# refdata-f3-parity-check.sh — ADR-0032 Step 1 read-plane F1↔F3 parity GATE.
#
# WHAT IT DOES
# ────────────
# ADR-0032 re-points refdata-api's read plane from F1 (`packiot.public`) to F3
# (`packiot_shadow.public`). F3's schema is intentionally divergent (ADR-0014),
# so a connection swap is NOT enough — every Surface-1 dataset's backing objects
# must actually EXIST and RETURN the same shape+values from F3 before the flip.
# This script is that gate. It must be CLEAN (or every divergence explicitly
# accounted for) before REFDATA_FLOW=f3 is set in a real deploy.
#
# Sibling of scripts/refdata-contract-drift-check.sh: same contract source (the
# in-binary registry via `refdata-api --dump-contract`), same SELECT-only
# BEGIN READ ONLY discipline. The drift gate diffs the binary vs PROD-F1; THIS
# gate diffs STAGING-F1 (`packiot`) vs STAGING-F3 (`packiot_shadow`), the two
# databases the collapse moves reads between.
#
# TWO PHASES
# ──────────
#   PHASE A — OBJECT AVAILABILITY PARITY (shape).  For every native Surface-1
#     backing object (function name+argc, relation name+columns) in the contract,
#     does it EXIST in F1?  in F3?  Verdict per object:
#       SERVABLE_BOTH   present in both → the dataset can be served from F3.
#       F3_MISSING      present in F1, absent in F3 → dataset BLOCKED on F3 until
#                       packiot_shadow's read layer grows the object. THE BLOCKER.
#       F1_MISSING      present in F3 only (unexpected; flagged for review).
#     External-shim objects (source=external, the prod-only SAP/Montebello views)
#     are EXCLUDED — they are a prod-only surface (ADR-0032 §5.1), empty on staging.
#
#   PHASE B — VALUE PARITY (values) for STATIC reference/config datasets, ent 3 & 4.
#     Runs each probe against BOTH DBs and diffs row count + an order-stable
#     checksum.  Scope is deliberately the STATIC surface (production_targets,
#     enterprises, language_packs, the operator/entity config views): F1==F3 is a
#     genuine expectation there.  LIVE/DERIVED datasets (uns_*, equipment_runtime_*,
#     equipment_values) are EXCLUDED from the value-diff ON PURPOSE — F1's derived
#     compute is FROZEN (stale since 2026-07-08, ADR-0032 §2.5) while F3 is live,
#     so a value difference there is the migration WORKING, not a parity failure.
#     Their correctness is covered by ADR-0032 acceptance criterion (A), not here.
#
# INVENTORY (live census 2026-07-20, the expected Phase-A verdict — the map this
# gate re-verifies; SERVABLE unless noted):
#   Fixed /v1/* routes:
#     events-timeline            h_piot_get_events_timeline3_with_event_id        SERVABLE_BOTH
#     pending-downtime           h_piot_get_equipment_pending_downtime_with_event_id SERVABLE_BOTH
#     operator-po-list           v_operator_po_list_setup_4                       SERVABLE_BOTH
#     operator-po-details        v_operator_po_details_3                          SERVABLE_BOTH
#     operator-entities          v_operator_entities_2                            SERVABLE_BOTH
#     entities-per-user-role     v_entities_per_user_role_operator                SERVABLE_BOTH
#     language-packs             language_packs                                   SERVABLE_BOTH
#     downtime-reasons           equipments + packml_register                     SERVABLE_BOTH
#     shift-hours                piot_get_shift_hours_by_packml_topic_2           F3_MISSING (BLOCKER)
#     shift-hours-by-enterprise  piot_get_shift_hours_by_enterprise_packml_topic_2 F3_MISSING (BLOCKER)
#     day-week-begin             piot_get_day_week_begin_by_packml_topic          F3_MISSING (BLOCKER)
#   Datasets (/v1/query) — SERVABLE_BOTH:
#     live-equipment-{metrics,job,day,shift,month}  uns_equipment_current_*       SERVABLE (value: live, excluded from Phase B)
#     production-targets         production_targets                               SERVABLE_BOTH
#     enterprise-config          enterprises                                      SERVABLE_BOTH
#     oee-by-month               equipment_runtime_shift + equipments             SERVABLE (value: derived, excluded)
#     custom-target-{month,week,day}  equipment_runtime_1{month,week,day}         SERVABLE (value: derived, excluded)
#     suzano-analogs             equipment_values                                 SERVABLE (value: live, excluded)
#     site-by-equipment          sites + equipments                              SERVABLE_BOTH
#     equipment-downtime-reasons equipments                                       SERVABLE_BOTH
#   Datasets (/v1/query) — F3_MISSING (BLOCKERS, backing h_piot_* analytics fn absent in packiot_shadow):
#     oee-score-teams, oee-score-full, oee-progress, mission-control(-area,-timeline),
#     overview-* (job-info, events, events-legacy, production-chart, production-chart-legacy,
#       production-health, downtimes-by-category), downtimes-summary, downtimes-per-category,
#       downtimes-events(-legacy), total-production, single-period(-legacy), machine-speed,
#       production-flow, targets, home-uns, events-timeline-from-po, events-timeline-full,
#       production-orders-runtimes, production-orders-with-runtimes
#     users                      users            SERVABLE object BUT empty (0 rows ent 3/4) in F3 — value gap
#     user-roles                 user_roles                                       F3_MISSING (BLOCKER)
#     menu-per-user-role         v_menu_per_user_role                             F3_MISSING (BLOCKER)
#     entities-per-user-role(ds) v_entities_per_user_role                         F3_MISSING (BLOCKER; note: the
#                                  operator ROUTE reads v_entities_per_user_role_operator which IS present)
#     scrap-targets / oee-targets  scrap_targets / oee_targets                    F3_MISSING (BLOCKER)
#     report-downtimes           v_report_downtimes                               F3_MISSING (dba-owned view, prod-gated)
#   query.go metric catalog:  agg_equipment_values_{1min,10min,1hour}             SERVABLE_BOTH
#   query.go bespoke:  dashboard_config / user_screen_config                      F3_MISSING (refdata-owned tables,
#                        created by ensureSchema/28-refdata-tables.sql at F1 startup — must be created in F3 too)
#
# HARD RULES honored
# ──────────────────
#   - SELECT-only, ALWAYS. Every query runs inside BEGIN READ ONLY.
#   - Staging DBs only. Default target is the staging DB EC2 (i-064bb36d1c454d861,
#     10.10.10.89) via `docker exec timescaledb psql`. No prod access.
#
# USAGE (on the DB EC2 via SSM, or any host with psql reachability to both DBs)
# ────────────────────────────────────────────────────────────────────────────
#   # simplest — on the DB EC2 (uses the local timescaledb container):
#   bash services/refdata-api/scripts/refdata-f3-parity-check.sh
#
#   # or point at explicit psql connections:
#   PSQL='psql -h 10.10.10.89 -U postgres' PGPASSWORD=... \
#     bash services/refdata-api/scripts/refdata-f3-parity-check.sh
#
#   ENV: F1_DB (default packiot), F3_DB (default packiot_shadow),
#        PSQL (default 'docker exec -i timescaledb psql -U postgres'),
#        ENTERPRISES (default '3 4'),
#        CONTRACT_JSON (skip the go build — a pre-dumped `--dump-contract` file).
#
# EXIT CODES: 0 = clean (all objects SERVABLE_BOTH + value probes match),
#             1 = divergence (F3_MISSING blockers, or a static value mismatch),
#             2 = harness error.

set -euo pipefail

F1_DB="${F1_DB:-packiot}"
F3_DB="${F3_DB:-packiot_shadow}"
PSQL="${PSQL:-docker exec -i timescaledb psql -U postgres}"
ENTERPRISES="${ENTERPRISES:-3 4}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # services/refdata-api

fail() { echo "ERROR: $*" >&2; exit 2; }
command -v jq >/dev/null || fail "jq not found"

# run_sql <db> — feed stdin SQL to the target DB, tab-separated, quiet.
run_sql() { $PSQL -d "$1" -qtA -F$'\t' -v ON_ERROR_STOP=1; }

RC=0

# ── 1. Obtain the contract (same source as the drift gate) ───────────────────
CONTRACT_JSON="${CONTRACT_JSON:-}"
if [ -z "$CONTRACT_JSON" ]; then
  command -v go >/dev/null || fail "go not found and CONTRACT_JSON not set"
  echo "[1/4] extracting contract (go run --dump-contract)..." >&2
  CONTRACT_JSON="$(mktemp)"
  ( cd "$HERE" && go run ./cmd/refdata-api --dump-contract ) > "$CONTRACT_JSON"
else
  echo "[1/4] using supplied contract: $CONTRACT_JSON" >&2
fi

# ── 2. PHASE A — object availability parity (F1 vs F3) ───────────────────────
# Render existence VALUES from the NATIVE contract (drop external-shim objects,
# which are prod-only). One row per (kind,name). sq renders a SQL string literal.
echo "[2/4] PHASE A — object availability (F1=$F1_DB vs F3=$F3_DB)..." >&2
SQDEF='def sq: "'"'"'" + gsub("'"'"'"; "'"'"''"'"'") + "'"'"'";'

FN_VALUES=$(jq -r "$SQDEF"'
  [.[] | select(.source!="external" and .kind=="function")
   | "  ("+(.name|sq)+")"] | unique | join(",\n")' "$CONTRACT_JSON")
REL_VALUES=$(jq -r "$SQDEF"'
  [.[] | select(.source!="external" and .kind=="relation")
   | "  ("+(.name|sq)+")"] | unique | join(",\n")' "$CONTRACT_JSON")

# availability_sql emits "kind<TAB>name<TAB>present(t/f)" for one DB.
availability_sql() {
cat <<SQL
BEGIN READ ONLY;
SET LOCAL statement_timeout='60s';
WITH fns(name) AS (VALUES
${FN_VALUES}
), rels(name) AS (VALUES
${REL_VALUES}
)
SELECT 'FUNCTION', f.name,
  EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname=f.name)
FROM fns f
UNION ALL
SELECT 'RELATION', r.name,
  EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='public' AND c.relname=r.name AND c.relkind IN ('r','v','m','p','f'))
FROM rels r
ORDER BY 1,2;
COMMIT;
SQL
}

A_F1="$(availability_sql | run_sql "$F1_DB")" || fail "F1 availability query failed"
A_F3="$(availability_sql | run_sql "$F3_DB")" || fail "F3 availability query failed"

# Join F1 & F3 on kind+name; classify.
PHASE_A=$(join -t$'\t' -1 1 -2 1 \
  <(echo "$A_F1" | awk -F'\t' '{print $1"|"$2"\t"$3}' | sort) \
  <(echo "$A_F3" | awk -F'\t' '{print $1"|"$2"\t"$3}' | sort) \
  | awk -F'\t' '{
      split($1,a,"|"); kind=a[1]; name=a[2]; f1=$2; f3=$3;
      if (f1=="t" && f3=="t") v="SERVABLE_BOTH";
      else if (f1=="t" && f3=="f") v="F3_MISSING";
      else if (f1=="f" && f3=="t") v="F1_MISSING";
      else v="MISSING_BOTH";
      print v"\t"kind"\t"name;
    }' | sort)

N_BOTH=$(echo "$PHASE_A"   | grep -c '^SERVABLE_BOTH' || true)
N_F3MISS=$(echo "$PHASE_A" | grep -c '^F3_MISSING'    || true)
N_F1MISS=$(echo "$PHASE_A" | grep -c '^F1_MISSING'    || true)
N_NONE=$(echo "$PHASE_A"   | grep -c '^MISSING_BOTH'  || true)

echo
echo "=== PHASE A: object availability (native Surface-1) ==="
printf 'VERDICT\tKIND\tNAME\n'
echo "$PHASE_A"
echo
echo "  SERVABLE_BOTH=$N_BOTH  F3_MISSING=$N_F3MISS  F1_MISSING=$N_F1MISS  MISSING_BOTH=$N_NONE"
if [ "$N_F3MISS" -gt 0 ] || [ "$N_F1MISS" -gt 0 ] || [ "$N_NONE" -gt 0 ]; then
  echo "  ⚠ Phase A NOT clean — the F3_MISSING rows are the datasets BLOCKED on F3." >&2
  RC=1
else
  echo "  ✅ Phase A clean — every native Surface-1 object exists in both flows."
fi

# ── 3. PHASE B — value parity for STATIC reference/config datasets ───────────
# Each probe is a plain relation read scoped to one enterprise, safe to run
# identically on both DBs. We diff row count + an order-stable md5 of the row set
# (row → text, aggregated in a deterministic order). A shape difference (column
# set drift) surfaces here too, as a checksum mismatch.
echo "[3/4] PHASE B — value parity for static datasets, ent {$ENTERPRISES}..." >&2

# name|tier|scoped_sql_with_@ENT_placeholder.
#   tier=REF  truly-static reference/config; F1==F3 is a HARD expectation, a
#             DIVERGENT here is a real reference-data replication bug.
#   tier=OPS  operator/entity views derived from production_orders + entity
#             config. They ARE servable from F3, but their values track
#             OPERATOR/PO STATE, which reaches F1 via edge-api directly and F3
#             only via shadow-mirror replay (ADR-0032 criterion B). A DIVERGENT
#             here is EXPECTED-DERIVED — it measures operator-fidelity lag /
#             view-content drift, NOT a reference gap. Surfaced (not hidden) so
#             the flip owner sees exactly how far F3's operator state trails F1's.
read -r -d '' PROBES <<'PROBES' || true
production-targets|REF|SELECT * FROM production_targets WHERE id_enterprise=@ENT
enterprise-config|REF|SELECT id_enterprise,nm_enterprise,week_begin,day_begin,week_size,timezone,logo_url,active,basic_menu,custom_menu,language_packs,scrap_calc_type FROM enterprises WHERE id_enterprise=@ENT
equipment-metadata|REF|SELECT id_equipment,nm_equipment,id_enterprise,id_site,id_area,tp_equipment FROM equipments WHERE id_enterprise=@ENT
operator-po-list|OPS|SELECT * FROM v_operator_po_list_setup_4 WHERE id_enterprise=@ENT
operator-po-details|OPS|SELECT * FROM v_operator_po_details_3 WHERE id_enterprise=@ENT
operator-entities|OPS|SELECT * FROM v_operator_entities_2 WHERE id_enterprise=@ENT
entities-per-user-role-route|OPS|SELECT * FROM v_entities_per_user_role_operator WHERE id_enterprise=@ENT
PROBES

# checksum_sql <inner_select> — count + order-stable md5 over the row set.
checksum_sql() {
cat <<SQL
BEGIN READ ONLY;
SET LOCAL statement_timeout='60s';
SELECT count(*), coalesce(md5(string_agg(r, '|' ORDER BY r)), '<empty>')
FROM ( SELECT (x.*)::text AS r FROM ( $1 ) x ) s;
COMMIT;
SQL
}

REF_DIVERGENT=0; REF_TOTAL=0; OPS_DIVERGENT=0; OPS_TOTAL=0
echo
echo "=== PHASE B: value parity (ref=hard gate, ops=expected-derived; ent {$ENTERPRISES}) ==="
printf 'DATASET\tTIER\tENT\tF1(count/md5)\tF3(count/md5)\tVERDICT\n'
while IFS='|' read -r NAME TIER SQLTMPL; do
  [ -z "$NAME" ] && continue
  for ENT in $ENTERPRISES; do
    SQL="${SQLTMPL//@ENT/$ENT}"
    R1=$(checksum_sql "$SQL" | run_sql "$F1_DB" 2>/dev/null || echo "ERR")
    R3=$(checksum_sql "$SQL" | run_sql "$F3_DB" 2>/dev/null || echo "ERR")
    C1=$(echo "$R1" | cut -f1); H1=$(echo "$R1" | cut -f2)
    C3=$(echo "$R3" | cut -f1); H3=$(echo "$R3" | cut -f2)
    match=0
    if [ "$R1" != "ERR" ] && [ "$R3" != "ERR" ] && [ "$C1" = "$C3" ] && [ "$H1" = "$H3" ]; then match=1; fi
    if [ "$TIER" = "REF" ]; then
      REF_TOTAL=$((REF_TOTAL+1))
      if [ "$match" = 1 ]; then V="MATCH"; else V="DIVERGENT"; REF_DIVERGENT=$((REF_DIVERGENT+1)); RC=1; fi
    else
      OPS_TOTAL=$((OPS_TOTAL+1))
      # OPS divergence is EXPECTED-DERIVED (operator-fidelity lag) — reported, non-gating.
      if [ "$match" = 1 ]; then V="MATCH"; else V="DERIVED_DIFF"; OPS_DIVERGENT=$((OPS_DIVERGENT+1)); fi
    fi
    printf '%s\t%s\t%s\t%s/%s\t%s/%s\t%s\n' "$NAME" "$TIER" "$ENT" "$C1" "${H1:0:8}" "$C3" "${H3:0:8}" "$V"
  done
done <<< "$PROBES"
echo
echo "  Phase B REF (hard gate): $((REF_TOTAL - REF_DIVERGENT))/$REF_TOTAL match."
echo "  Phase B OPS (expected-derived, non-gating): $((OPS_TOTAL - OPS_DIVERGENT))/$OPS_TOTAL match;"
echo "    $OPS_DIVERGENT show operator/PO-state drift (F3 reaches operator state via shadow-mirror — criterion B)."

# ── 4. Verdict ───────────────────────────────────────────────────────────────
echo "[4/4] result:" >&2
echo
if [ "$RC" -eq 0 ]; then
  echo "✅ PARITY CLEAN — every native Surface-1 object is SERVABLE_BOTH and every"
  echo "   REF-tier value probe matches. The read plane can serve REFDATA_FLOW=f3."
  echo "   (OPS-tier operator/entity DERIVED_DIFFs, if any, are non-gating — they"
  echo "    reflect operator-fidelity lag, ADR-0032 criterion B, not a read gap.)"
else
  echo "❌ PARITY NOT CLEAN — F3 cannot yet serve the full Surface-1 read plane."
  echo "   Phase A F3_MISSING objects are BLOCKERS: the backing h_piot_* analytics"
  echo "   functions / config relations do not exist in $F3_DB. They must be PORTED"
  echo "   into packiot_shadow before REFDATA_FLOW=f3 can serve those datasets."
  echo "   (The switch defaults to f1, so this does NOT affect the current deploy.)"
fi
exit "$RC"
