#!/usr/bin/env bash
# test-powerbi-compatibility.sh — the ADR-0012/0016 PowerBI gate harness
# (the follow-up deliverable promised in docs/guides/powerbi-compatibility-test-plan.md).
#
# Compares every object in docs/guides/powerbi-gate-objects.txt between
# a SOURCE db (default: staging packiot — the truth PowerBI reads today)
# and a TARGET db (default: packiot_refactor — the refactored façades),
# both inside the timescaledb container on staging DB EC2, via SSM.
#
# Dimensions (from the test plan):
#   T1 presence        — to_regclass + relkind, both sides
#   T2 column shape    — md5 of (name:type ordered by ordinal), both sides
#   T3 row counts      — COUNT(*), both sides (advisory where target unseeded)
#   T4 planner inlining— EXPLAIN on target façades: customer_id filter
#                        must appear inside the scan node (POC-proven)
#   T5 row sample      — md5 of one deterministic row where both sides
#                        have data and shapes match (advisory)
#
# Cross-DB access: dblink from TARGET to SOURCE over the local socket
# (same instance). Emits docs/powerbi-compat-report.md + exit code
# (0 = no hard failures; T3/T5 advisories don't fail the gate — the
# plan's row-parity acceptance runs after the prod-read harness seeds
# the pools).
#
# Note on "37+1": the plan's headline predates the writer inventory;
# the enumerated set is 29 named objects + production_data_sync_
# enterprise_06 (ADR-0016 §gate) = 30. The list file is canonical.

set -euo pipefail

DB_EC2="${DB_EC2:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
CONTAINER="${CONTAINER:-timescaledb}"
SOURCE_DB="${SOURCE_DB:-packiot}"
TARGET_DB="${TARGET_DB:-packiot_refactor}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OBJECTS_FILE="${REPO_ROOT}/docs/guides/powerbi-gate-objects.txt"
REPORT="${REPO_ROOT}/docs/powerbi-compat-report.md"

[ -f "$OBJECTS_FILE" ] || { echo "objects list not found: $OBJECTS_FILE" >&2; exit 2; }

ssm_run() {
    local cmd="$1" params_file cid status
    params_file=$(mktemp)
    python3 -c "import json,sys; print(json.dumps({'commands':[sys.argv[1]]}))" "$cmd" > "$params_file"
    cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_EC2" \
        --document-name AWS-RunShellScript --parameters "file://$params_file" \
        --query "Command.CommandId" --output text)
    rm -f "$params_file"
    while true; do
        status=$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cid" --instance-id "$DB_EC2" --query Status --output text 2>&1)
        [ "$status" != "InProgress" ] && [ "$status" != "Pending" ] && break
        sleep 2
    done
    aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$DB_EC2" \
        --query 'StandardOutputContent' --output text
    [ "$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
        --instance-id "$DB_EC2" --query Status --output text)" = "Success" ] || {
        echo "[error] SSM command failed" >&2; return 1; }
}

# ── build the comparison SQL (runs in TARGET, dblinks to SOURCE) ──────
NAMES_ARRAY=$(sed "s/.*/'&'/" "$OBJECTS_FILE" | paste -sd,)
SQL=$(mktemp)
cat > "$SQL" <<EOF
CREATE EXTENSION IF NOT EXISTS dblink;
SELECT 'GATEROW ' || o.name
  || ' | ' || COALESCE(tgt.kind, 'MISSING')
  || ' | ' || COALESCE(src.kind, 'MISSING')
  || ' | ' || CASE WHEN tgt.sig IS NULL OR src.sig IS NULL THEN 'n/a'
                   WHEN tgt.sig = src.sig THEN 'MATCH' ELSE 'DIFF' END
  || ' | ' || COALESCE(tgt.rows::text, '-')
  || ' | ' || COALESCE(src.rows::text, '-')
FROM unnest(ARRAY[${NAMES_ARRAY}]) AS o(name)
LEFT JOIN LATERAL (
  SELECT CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
              WHEN 'm' THEN 'matview' ELSE c.relkind::text END AS kind,
         (SELECT md5(string_agg(column_name || ':' || udt_name, ',' ORDER BY ordinal_position))
            FROM information_schema.columns
           WHERE table_schema = 'public' AND table_name = o.name) AS sig,
         (SELECT (xpath('/row/c/text()', query_to_xml(
             format('SELECT count(*) AS c FROM public.%I', o.name), false, true, '')))[1]::text::bigint) AS rows
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = o.name
) tgt ON true
LEFT JOIN LATERAL (
  SELECT r.kind, r.sig, r.rows
    FROM dblink('host=/var/run/postgresql dbname=${SOURCE_DB}',
      format(\$q\$
        SELECT CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'matview' ELSE c.relkind::text END,
               (SELECT md5(string_agg(column_name || ':' || udt_name, ',' ORDER BY ordinal_position))
                  FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = %L),
               (SELECT (xpath('/row/c/text()', query_to_xml(
                   format('SELECT count(*) AS c FROM public.%%I', %L), false, true, '')))[1]::text::bigint)
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname = %L
      \$q\$, o.name, o.name, o.name)
    ) AS r(kind text, sig text, rows bigint)
) src ON true
ORDER BY o.name;

-- T4: planner inlining — façades over pool schemas in TARGET
SELECT 'PLANROW ' || v.relname || ' | ' ||
       CASE WHEN plan.txt ~ 'customer_id = \d+' THEN 'INLINED' ELSE 'NOT-INLINED' END
FROM pg_class v
JOIN pg_namespace n ON n.oid = v.relnamespace AND n.nspname = 'public'
JOIN pg_rewrite rw ON rw.ev_class = v.oid
JOIN LATERAL (
  SELECT string_agg(line, ' ') AS txt
    FROM (SELECT unnest AS line FROM unnest(string_to_array(
      (SELECT string_agg(p, E'\n') FROM (
         SELECT unnest((SELECT array_agg("QUERY PLAN") FROM (
           SELECT * FROM json_array_elements_text('[]'::json)) x("QUERY PLAN"))) p) y),
      E'\n'))) z
) plan ON false  -- placeholder; real EXPLAIN below via DO block
WHERE false;

DO \$plan\$
DECLARE v record; l text; agg text;
BEGIN
  FOR v IN
    SELECT c.relname FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    WHERE c.relkind = 'v'
      AND pg_get_viewdef(c.oid) ~ '(customer_dashboards|customer_reports)\.'
      AND c.relname = ANY (ARRAY[${NAMES_ARRAY}])
  LOOP
    agg := '';
    FOR l IN EXECUTE format('EXPLAIN (COSTS OFF) SELECT * FROM public.%I', v.relname)
    LOOP agg := agg || l || ' '; END LOOP;
    RAISE INFO 'PLANROW % | %', v.relname,
      CASE WHEN agg ~ 'customer_id = \d+' THEN 'INLINED' ELSE 'NOT-INLINED' END;
  END LOOP;
END \$plan\$;
EOF

# strip the placeholder block (kept the DO version only)
python3 - "$SQL" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"-- T4: planner inlining.*?WHERE false;\n\n", "-- T4 via DO block below\n", s, flags=re.S)
open(p, "w").write(s)
PYEOF

echo "[1/3] running gate comparison (${TARGET_DB} vs ${SOURCE_DB})..."
B64=$(gzip -9 -c "$SQL" | base64 -w0)
[ "${#B64}" -le 8000 ] || { echo "SQL exceeds SSM limit" >&2; exit 2; }
RAW=$(ssm_run "echo '$B64' | base64 -d | gunzip > /tmp/pbi_gate.sql && docker cp /tmp/pbi_gate.sql $CONTAINER:/tmp/pbi_gate.sql && docker exec $CONTAINER psql -U postgres -d $TARGET_DB -v ON_ERROR_STOP=1 -qAX -f /tmp/pbi_gate.sql 2>&1")
rm -f "$SQL"

echo "[2/3] parsing + writing report..."
RAW_FILE=$(mktemp)
printf '%s' "$RAW" > "$RAW_FILE"
python3 - "$REPORT" "$OBJECTS_FILE" "$SOURCE_DB" "$TARGET_DB" "$RAW_FILE" <<'PYEOF'
import sys, datetime
report, objfile, src_db, tgt_db, raw_file = sys.argv[1:6]
raw = open(raw_file).read()
gate, plans = {}, {}
for line in raw.splitlines():
    line = line.strip()
    if line.startswith("GATEROW "):
        name, tk, sk, shape, tr, sr = [f.strip() for f in line[8:].split("|")]
        gate[name] = dict(tgt_kind=tk, src_kind=sk, shape=shape, tgt_rows=tr, src_rows=sr)
    elif "PLANROW " in line:
        seg = line.split("PLANROW ", 1)[1]
        name, verdict = [f.strip() for f in seg.split("|")]
        plans[name] = verdict
names = [l.strip() for l in open(objfile) if l.strip()]
hard_fail = []
rows = []
for n in names:
    g = gate.get(n, dict(tgt_kind="?", src_kind="?", shape="?", tgt_rows="-", src_rows="-"))
    t1 = "PASS" if g["tgt_kind"] not in ("MISSING", "?") else "FAIL"
    t2 = {"MATCH": "PASS", "DIFF": "FAIL", "n/a": "n/a"}.get(g["shape"], "?")
    t3 = "PASS" if (g["tgt_rows"] == g["src_rows"] and g["tgt_rows"] not in ("-",)) else ("advisory" if g["tgt_rows"] != g["src_rows"] else "n/a")
    t4 = plans.get(n, "n/a")
    if t1 == "FAIL": hard_fail.append((n, "T1 missing in target"))
    if t2 == "FAIL": hard_fail.append((n, "T2 shape diff"))
    if t4 == "NOT-INLINED": hard_fail.append((n, "T4 planner"))
    rows.append((n, g["tgt_kind"], g["src_kind"], t1, t2, t3, t4))
status = "BLOCKED" if hard_fail else "PROMOTABLE (pending row-parity seed + human sign-off)"
with open(report, "w") as f:
    f.write(f"# PowerBI compatibility gate report\n\n")
    f.write(f"- Generated: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%MZ')} by scripts/test-powerbi-compatibility.sh\n")
    f.write(f"- Source (truth): `{src_db}` · Target (façades): `{tgt_db}`\n")
    f.write(f"- Objects: {len(names)} (see docs/guides/powerbi-gate-objects.txt)\n")
    f.write(f"- **Gate status: {status}**\n\n")
    f.write("| object | kind (tgt/src) | T1 presence | T2 shape | T3 rows | T4 planner |\n|---|---|---|---|---|---|\n")
    for n, tk, sk, t1, t2, t3, t4 in rows:
        f.write(f"| `{n}` | {tk}/{sk} | {t1} | {t2} | {t3} | {t4} |\n")
    if hard_fail:
        f.write("\n## Hard failures\n\n")
        for n, why in hard_fail:
            f.write(f"- `{n}` — {why}\n")
    f.write("\n## Notes\n\n- T3 row parity is advisory until the prod-read report harness seeds the pools (test-plan §Preconditions).\n- T5 byte-sample runs at sign-off time on the seeded objects.\n- '37+1' headline vs 30 enumerated: reconciled in the harness header.\n")
print(f"gate status: {status}")
sys.exit(1 if hard_fail else 0)
PYEOF
RC=$?
rm -f "$RAW_FILE"

echo "[3/3] report at $REPORT"
exit $RC
