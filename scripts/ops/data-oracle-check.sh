#!/usr/bin/env bash
# data-oracle-check.sh — data invariants that need the LEGACY oracle (packiot40, a separate
# DB), recorded into ops.data_invariant_result via invariant-record.sh so they alert like the
# in-DB checks (t-data-invariants). Run hourly by data-oracle-check.timer on the app box.
#
#   OR1_feed_silent_vs_oracle   (critical, CPACK 3): an equipment topic produced in legacy in
#       the last 2 h but sent NOTHING to staging in that time — a broken feed (2026-10-01: the
#       factory tee stopped publishing L8/L10 PTH at 09-29 22:59 while legacy kept counting;
#       found only by a manual audit 46 h later).
#   OR2_line_daily_net_vs_oracle (warn, CPACK 3): yesterday's (UTC) line net, staging gold vs
#       legacy, outside [0.85, 1.25] (legacy undercounts its totalizers 2-9 %, so staging is
#       normally slightly above). FLEXO is excluded (edge feed, user decision 2026-09).
#   EXCLUDE_FEEDS: equipment staging deliberately does not receive (OR1 skips them).
#
# Read-only on legacy. Env: STACK_ENV (staging creds), LEGACY_SECRET_ID (default databaseCredentials).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ENV="${STACK_ENV:-/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha/.env}"
LEGACY_SECRET_ID="${LEGACY_SECRET_ID:-databaseCredentials}"
EXCLUDE_LINES="${EXCLUDE_LINES:-FLEXO}"
# Feeds staging deliberately does not receive (user decision 2026-09: edge-side feeds
# FLEXO, L10-TEXA and the L3 line topic stay on legacy only). Equipment names, exact match.
EXCLUDE_FEEDS="${EXCLUDE_FEEDS:-FLEXO,L10-TEXA,L3}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Read ONLY the needed keys — never `source` a .env (values may hold shell metacharacters).
envval() { grep -E "^$1=" "$STACK_ENV" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
POSTGRES_HOST="$(envval POSTGRES_HOST)"; POSTGRES_USER="$(envval POSTGRES_USER)"
POSTGRES_PASSWORD="$(envval POSTGRES_PASSWORD)"; POSTGRES_PORT="$(envval POSTGRES_PORT)"
S=$(aws secretsmanager get-secret-value --region us-east-1 --secret-id "$LEGACY_SECRET_ID" --query SecretString --output text)
eval "$(echo "$S" | python3 -c 'import json,sys,shlex; d=json.load(sys.stdin); [print(f"L_{k}={shlex.quote(str(v))}") for k,v in d.items() if k in ("DB_HOST","DB_PORT","DB_USER","DB_NAME","DB_PASSWORD")]')"

# SQL on stdin (psql -c prints only the LAST statement's result — here that would be COMMIT).
# -q silences the SET/BEGIN/COMMIT command tags; only the query rows are printed.
legacy() { printf "SET statement_timeout='120s';\nBEGIN READ ONLY;\n%s\nCOMMIT;\n" "$1" | docker run --rm -i -e PGPASSWORD="$L_DB_PASSWORD" postgres:16-alpine psql -h "$L_DB_HOST" -p "${L_DB_PORT:-5432}" -U "$L_DB_USER" -d "$L_DB_NAME" -q -At -F'|' -v ON_ERROR_STOP=1 -f -; }
staging() { printf "SET statement_timeout='120s';\n%s\n" "$1" | docker run --rm -i -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:16-alpine psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "$POSTGRES_USER" -d packiot_analytics -q -At -F'|' -v ON_ERROR_STOP=1 -f -; }

# OR1 inputs: equipment-level topics (no /Admin or /Status leaf) with their 2 h production / last value.
legacy "SELECT replace(r.packml_topic, 'C-PACK/', 'CPACK/'), round(coalesce(sum(v.net_production_incr), 0) + coalesce(sum(v.gross_production_incr), 0))
          FROM packml_register r JOIN equipments e ON e.id_equipment = r.id_equipment
          LEFT JOIN equipment_values v ON v.id_equipment = r.id_equipment AND v.ts_value > now() - interval '2 hours'
         WHERE e.id_enterprise = 1 AND r.active AND r.packml_topic NOT LIKE '%/Admin/%' AND r.packml_topic NOT LIKE '%/Status/%'
         GROUP BY 1;" > "$WORK/leg_topics" || true
staging "SELECT t.packml_topic, e.nm_equipment, (SELECT count(*) FROM silver.equipment_values v WHERE v.id_equipment = t.id_equipment AND v.ts_value > now() - interval '2 hours')
           FROM core.topic_routing t JOIN core.equipments e ON e.id_equipment = t.id_equipment
          WHERE t.id_enterprise = 3 AND t.active AND t.packml_topic NOT LIKE '%/Admin/%' AND t.packml_topic NOT LIKE '%/Status/%';" > "$WORK/stg_topics"
# OR2 inputs: yesterday (UTC) line net.
legacy "SELECT e.nm_equipment, round(sum(v.net_production_incr)) FROM equipment_values v JOIN equipments e USING (id_equipment)
         WHERE e.id_enterprise = 1 AND e.tp_equipment = 3 AND v.ts_value >= current_date - 1 AND v.ts_value < current_date GROUP BY 1;" > "$WORK/leg_lines" || true
staging "SELECT e.nm_equipment, round(sum(h.net)) FROM gold.equipment_oee_hourly h JOIN core.equipments e USING (id_equipment)
          WHERE e.id_enterprise = 3 AND e.tp_equipment = 3 AND h.ts_value >= current_date - 1 AND h.ts_value < current_date GROUP BY 1;" > "$WORK/stg_lines"

python3 - "$WORK" "$EXCLUDE_LINES" "$EXCLUDE_FEEDS" > "$WORK/rows.jsonl" <<'PY'
import json, sys, os
w, excl = sys.argv[1], set(x for x in sys.argv[2].split(',') if x)
excl_feeds = set(x for x in sys.argv[3].split(',') if x)
def rd(n):
    p = os.path.join(w, n)
    return [l.rstrip('\n').split('|') for l in open(p) if l.strip()] if os.path.exists(p) else []
leg = {r[0]: float(r[1] or 0) for r in rd('leg_topics') if len(r) == 2}
stg = {r[0]: (r[1], int(r[2] or 0)) for r in rd('stg_topics') if len(r) == 3}
out = []
if leg and stg:
    silent = sorted(set(f"{stg[t][0]} (legacy +{int(leg[t])})" for t in stg
                        if t in leg and leg[t] > 100 and stg[t][1] == 0 and stg[t][0] not in excl_feeds))
    out.append(dict(check_id='OR1_feed_silent_vs_oracle', dimension='completeness', layer='source', severity='critical',
                    id_enterprise=3, observed=len(silent), expected='0', ok=not silent, detail=', '.join(silent)[:900], source='oracle'))
else:
    out.append(dict(check_id='OR1_feed_silent_vs_oracle', dimension='completeness', layer='source', severity='critical',
                    id_enterprise=3, observed=None, expected='0', ok=False, detail='oracle query returned nothing (legacy or staging unreachable)', source='oracle'))
ll = {r[0]: float(r[1] or 0) for r in rd('leg_lines') if len(r) == 2}
sl = {r[0]: float(r[1] or 0) for r in rd('stg_lines') if len(r) == 2}
bad = []
for n, lv in sorted(ll.items()):
    if n in excl or n not in sl or lv < 1000: continue
    ratio = sl[n] / lv
    if not (0.85 <= ratio <= 1.25): bad.append(f"{n} {ratio:.2f} ({int(sl[n])}/{int(lv)})")
out.append(dict(check_id='OR2_line_daily_net_vs_oracle', dimension='accuracy', layer='gold', severity='warn',
                id_enterprise=3, observed=len(bad), expected='0', ok=not bad, detail=', '.join(bad)[:900], source='oracle'))
for r in out: print(json.dumps(r))
PY
cat "$WORK/rows.jsonl"
"$HERE/invariant-record.sh" < "$WORK/rows.jsonl"
