#!/usr/bin/env bash
# capture-f3-snapshot.sh — produce the AUTHORITATIVE F3 schema DDL for greenfield
# prod by dumping the SCHEMA (data-free) of staging's live packiot_shadow and
# curating out the staging debris. Output → db/init-f3/snapshot/*.sql.
#
# ⚠ GATED. This is the one step that reads more than pure SELECT: pg_dump
# --schema-only takes AccessShareLocks (read-only in effect, no data extracted),
# on STAGING (never prod). It is intentionally NOT run automatically — invoke it
# deliberately, with USER sign-off, per the SELECT-only directive. It writes
# NOTHING to any database.
#
# Why a dump and not the fragment assemble.sh? Because a hand-assembly of the
# edge-node-red/db + migrations fragments does NOT reach schema parity with
# packiot_shadow (measured F3_MISSING=344 + EXTRA=377 — see db/init-f3/README.md
# §3). A schema-only dump FROM packiot_shadow matches it by construction.
#
# Transport: SSM start-session (PTY via `script`) → sudo bash on the staging DB
# EC2 → `docker exec timescaledb pg_dump`. The dump is written to a container
# temp file, gzip+base64'd, streamed back over the PTY session (no 24 KB
# send-command truncation), decoded + split locally.
#
# Usage (deliberate):
#   CONFIRM=yes ./scripts/capture-f3-snapshot.sh
set -euo pipefail

INSTANCE="${INSTANCE:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
DB="${DB:-packiot_shadow}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/db/init-f3/snapshot"

if [ "${CONFIRM:-}" != "yes" ]; then
  cat >&2 <<EOF
GATED. This reads staging packiot_shadow's SCHEMA (data-free, read-only-in-effect)
and writes db/init-f3/snapshot/*.sql. Re-run with CONFIRM=yes once approved.

It will run, inside the staging timescaledb container:
  pg_dump -d $DB --schema-only --no-owner --no-privileges --schema=public \\
     --exclude-table='ops_shadow_zombie_preimage_*' \\
     --exclude-table='report_*_enterprsie_*' \\
     --exclude-table='*_po_func_ret' --exclude-table='*_13_po_func_ret' \\
     --exclude-table='hasura_test' --exclude-table='dt5min_po_function_returns'
then split into ordered NN-*.sql and (manual follow-up) re-tune cagg
refresh/retention policies for prod. Prove with prod-f3-schema-parity-check.sh.
EOF
  exit 3
fi

# remote: run pg_dump in the container, gzip+base64 to stdout. Excludes the
# staging debris (mirrors db/init-f3/DEBRIS.exclude). NOTE: pg_dump CANNOT
# restore TimescaleDB continuous aggregates via plain psql (it dumps them as
# views over _timescaledb_internal._materialized_hypertable_NN). Those + the
# hypertables are recreated by the strict 05-*/10-* timescale layer, NOT here —
# see the post-process below and db/init-f3/README.md §3.
remote=$(cat <<'REMOTE'
set -e
docker exec -i timescaledb pg_dump -U postgres -d __DB__ \
  --schema-only --no-owner --no-privileges --schema=public \
  --exclude-table='ops_shadow_zombie_preimage_*' \
  --exclude-table='report_*_enterprsie_*' \
  --exclude-table='*_po_func_ret' \
  --exclude-table='*_13_po_func_ret' \
  --exclude-table='hasura_test' \
  --exclude-table='dt5min_po_function_returns' \
  --exclude-table='lab_equipment_values' \
  --exclude-table='*lab_equipment_values*' \
  | gzip -9 | base64 -w0
REMOTE
)
remote="${remote/__DB__/$DB}"
remote_b64=$(printf '%s' "$remote" | base64 -w0)

mkdir -p "$OUT"
echo "dumping $DB schema via SSM (this streams a gzipped dump back)..." >&2
script -qec "aws ssm start-session --target $INSTANCE \
  --document-name AWS-StartNonInteractiveCommand \
  --parameters 'command=[\"bash -c echo\${IFS}$remote_b64|base64\${IFS}-d|sudo\${IFS}bash\"]' \
  --region $REGION" /dev/null 2>/dev/null \
  | tr -d '\r' | grep -av -e '^Starting session' -e '^Exiting session' \
  | tr -d '\n' | base64 -d | gunzip > "$OUT/00-packiot_shadow-schema.sql"

echo "wrote $OUT/00-packiot_shadow-schema.sql ($(wc -l < "$OUT/00-packiot_shadow-schema.sql") lines)" >&2

# ── post-process: strip the object blocks a plain restore can't handle ─────────
# (cagg VIEW blocks over _timescaledb_internal, cross-schema refs, residual
# debris). The strict 05-*/10-* timescale layer recreates the real caggs. This
# is the exact strip proven to yield parity F3_MISSING=0 (README §3/§5).
python3 - "$OUT/00-packiot_shadow-schema.sql" <<'PY'
import re, sys
src=sys.argv[1]; text=open(src).read()
parts=re.split(r'(?m)^(?=--\n-- Name: )', text)
def drop(p):
    m=re.search(r'-- Name: (.+?); Type: (.+?); Schema:', p)
    name,typ=(m.group(1),m.group(2)) if m else ('','')
    body=p
    if typ in ('VIEW','MATERIALIZED VIEW') and ('_materialized_hypertable' in body or '_timescaledb_internal' in body): return True
    if typ in ('VIEW','MATERIALIZED VIEW','FUNCTION') and ('customer_reports.' in body or 'customer_dashboards.' in body): return True
    if re.search(r'\b(hasura_test|_po_func_ret|_po_function_returns|piot4_13_get_|c33_dashboard_|c35_dashboard_|report_[a-z]+_enterprsie_|equipment_boxes_cust_|agg_lab_|ca_lab_)', name): return True
    if 'lab_equipment_values' in name: return True
    return False
kept=[p for p in parts if not drop(p)]
open(src,'w').write(''.join(kept).replace('CREATE SCHEMA public;','CREATE SCHEMA IF NOT EXISTS public;'))
print(f"stripped {len(parts)-len(kept)} debris/cagg-view blocks; kept {len(kept)}", file=sys.stderr)
PY

echo "NEXT: ensure the strict timescale layer is present (committed):" >&2
echo "  05-f3-cagg-agg.sql          = docs/adr/reference/migrations/0012-f3-cagg-layer.sql" >&2
echo "  10-f3-timescale-supplement.sql = 3 raw hypertables + 5 ca_* caggs (introspected)" >&2
echo "Then prove: CANDIDATE_DSN=<fresh-db> scripts/prod-f3-schema-parity-check.sh gate" >&2
