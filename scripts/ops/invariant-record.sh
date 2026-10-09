#!/usr/bin/env bash
# invariant-record.sh — append rows to ops.data_invariant_result (t-data-invariants) from a
# script outside the database (legacy-oracle checks, the historian integrity monitor), so
# they alert through the same exporter → Prometheus → Alertmanager path as the in-DB job.
# Usage: invariant-record.sh < rows.jsonl
#   one JSON object per line: {check_id, dimension, layer, severity, id_enterprise?, observed?,
#                              expected?, ok, detail?, source}
# Env: STACK_ENV (default: the stack checkout's .env) for POSTGRES_HOST/USER/PASSWORD.
set -euo pipefail
STACK_ENV="${STACK_ENV:-/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha/.env}"
# Read ONLY the needed keys — never `source` a .env (values may hold shell metacharacters).
envval() { grep -E "^$1=" "$STACK_ENV" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
POSTGRES_HOST="$(envval POSTGRES_HOST)"; POSTGRES_USER="$(envval POSTGRES_USER)"
POSTGRES_PASSWORD="$(envval POSTGRES_PASSWORD)"; POSTGRES_PORT="$(envval POSTGRES_PORT)"
sql="$(python3 -c '
import json, sys
def lit(v):
    if v is None or v == "": return "NULL"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    return "'"'"'" + str(v).replace("'"'"'", "'"'"''"'"'") + "'"'"'"
rows = [json.loads(l) for l in sys.stdin if l.strip()]
if not rows: sys.exit(0)
cols = ["check_id","dimension","layer","severity","id_enterprise","observed","expected","ok","detail","source"]
vals = ",\n".join("(now(), " + ", ".join(lit(r.get(c)) for c in cols) + ")" for r in rows)
print("INSERT INTO ops.data_invariant_result (run_at, " + ", ".join(cols) + ") VALUES\n" + vals + ";")
')"
[ -n "$sql" ] || exit 0
printf '%s\n' "$sql" | docker run --rm -i -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:16-alpine \
  psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "$POSTGRES_USER" -d packiot_analytics -v ON_ERROR_STOP=1 -q -f - \
  || { echo "invariant-record: insert failed" >&2; exit 1; }
