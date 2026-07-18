#!/usr/bin/env bash
# refdata-contract-drift-check.sh — the pre-prod-flip drift GATE (task #71).
#
# WHAT IT DOES
# ────────────
# Diffs the LIVE prod pg_proc / pg_catalog surface against the positional
# contract baked into refdata-api (datasets.go + the /v1/* routes in main.go).
# If prod has drifted from what the binary assumes — a function renamed _3→_4,
# an arity change, a dropped view column — this FAILS with a diff report so the
# flip is blocked BEFORE reads break in prod.
#
#   function → must EXIST and accept the argc we bind (min_args ≤ argc ≤ nargs,
#              honoring DEFAULTs and overloads)
#   relation → must EXIST and every explicitly-projected column must exist
#              (existence-only when the dataset SELECT *'s)
#
# This productizes the dba's one-time manual "zero drift" check into a
# repeatable gate. Sibling of scripts/powerbi-evidence-prod-read.sh.
#
# HARD RULES honored
# ──────────────────
#   - Prod is SELECT-only, ALWAYS. Every query runs inside one BEGIN READ ONLY
#     transaction (a write attempt aborts the tx); the role is awslambda-scoped.
#   - Prod DB credentials NEVER enter CI. This runs OUT-OF-BAND on the staging
#     app EC2 (i-06c9547a2c7091ab7) via SSM Session Manager — that host has the
#     IAM role for Secrets Manager + network reachability to prod. Embedding
#     prod DB creds in deploy CI was explicitly rejected (PRs #161–167).
#
# USAGE (on the app EC2, via SSM)
# ───────────────────────────────
#   # from a checkout of packiot-stack-alpha on the instance:
#   AWS_REGION=us-east-1 bash services/refdata-api/scripts/refdata-contract-drift-check.sh
#
# It needs: jq, aws CLI, and EITHER psql OR docker (falls back to
# postgres:15-alpine). Go is only needed if CONTRACT_JSON is not supplied — set
# CONTRACT_JSON to a pre-generated `refdata-api --dump-contract` file to skip the
# build entirely (handy when Go isn't installed on the runner).
#
# EXIT CODES: 0 = no drift (clean), 1 = drift detected, 2 = harness error.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="${DB_SECRET_ID:-databaseCredentials}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # services/refdata-api

fail() { echo "ERROR: $*" >&2; exit 2; }
command -v jq  >/dev/null || fail "jq not found"
command -v aws >/dev/null || fail "aws CLI not found"

# ── 1. Obtain the contract (JSON from `refdata-api --dump-contract`) ─────────
CONTRACT_JSON="${CONTRACT_JSON:-}"
if [ -z "$CONTRACT_JSON" ]; then
  command -v go >/dev/null || fail "go not found and CONTRACT_JSON not set — supply a pre-dumped contract"
  echo "[1/4] extracting contract from source (go run --dump-contract)..." >&2
  CONTRACT_JSON="$(mktemp)"
  ( cd "$HERE" && go run ./cmd/refdata-api --dump-contract ) > "$CONTRACT_JSON"
else
  echo "[1/4] using supplied contract: $CONTRACT_JSON" >&2
fi
N_TOTAL=$(jq 'length' "$CONTRACT_JSON")
N_FN=$(jq '[.[]|select(.kind=="function")]|length' "$CONTRACT_JSON")
N_REL=$(jq '[.[]|select(.kind=="relation")]|length' "$CONTRACT_JSON")
echo "      contract: $N_TOTAL objects ($N_FN functions, $N_REL relations)" >&2

# ── 2. Render the drift-detection SQL from the contract ─────────────────────
# Each VALUES row is a SQL tuple. `sq` renders a SINGLE-quoted SQL string
# literal (double-quotes would be read as identifiers), escaping any embedded
# quote by doubling it. argc is an integer literal (unquoted).
echo "[2/4] rendering drift SQL..." >&2
SQDEF='def sq: "'"'"'" + gsub("'"'"'"; "'"'"''"'"'") + "'"'"'";'

FN_VALUES=$(jq -r "$SQDEF"'
  [.[] | select(.kind=="function")
   | "  (" + (.ref|sq) + "," + (.name|sq) + "," + (.argc|tostring) + ")"]
  | join(",\n")' "$CONTRACT_JSON")

REL_VALUES=$(jq -r "$SQDEF"'
  [.[] | select(.kind=="relation")
   | "  (" + (.ref|sq) + "," + (.name|sq) + ")"]
  | unique | join(",\n")' "$CONTRACT_JSON")

COL_VALUES=$(jq -r "$SQDEF"'
  [.[] | select(.kind=="relation" and (.columns|length>0))
   | .ref as $r | .name as $n | .columns[]
   | "  (" + ($r|sq) + "," + ($n|sq) + "," + (.|sq) + ")"]
  | unique | join(",\n")' "$CONTRACT_JSON")

# COL_VALUES may be empty in principle; keep the CTE valid with a typed dummy
# row and a NOT-NULL guard so the placeholder never reports as drift.
if [ -z "$COL_VALUES" ]; then
  COL_VALUES="  (NULL::text, NULL::text, NULL::text)"; COL_COND="ec.rel IS NOT NULL AND "
else
  COL_COND=""
fi

SQL=$(cat <<SQL
BEGIN READ ONLY;
SET LOCAL statement_timeout = '60s';

WITH
expected_fns(ref, fn, argc) AS (VALUES
${FN_VALUES}
),
-- pronargs counts IN/INOUT args (exactly what we bind positionally); defaults
-- give the minimum required. Overloads = multiple rows per name; a fit against
-- ANY overload passes.
prod_fns AS (
  SELECT p.proname,
         p.pronargs AS total_args,
         p.pronargs - p.pronargdefaults AS min_args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
),
fn_drift AS (
  SELECT e.ref, e.fn AS object,
    CASE
      WHEN NOT EXISTS (SELECT 1 FROM prod_fns pf WHERE pf.proname = e.fn)
        THEN 'MISSING_FUNCTION'
      WHEN NOT EXISTS (SELECT 1 FROM prod_fns pf
                       WHERE pf.proname = e.fn
                         AND e.argc BETWEEN pf.min_args AND pf.total_args)
        THEN 'ARITY_MISMATCH(want ' || e.argc || ')'
    END AS detail
  FROM expected_fns e
),
-- pg_catalog (not information_schema) so MATERIALIZED VIEWS are covered too.
prod_rels AS (
  SELECT c.oid, c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r','v','m','p','f')
),
expected_rels(ref, rel) AS (VALUES
${REL_VALUES}
),
rel_drift AS (
  SELECT er.ref, er.rel AS object, 'MISSING_RELATION' AS detail
  FROM expected_rels er
  WHERE NOT EXISTS (SELECT 1 FROM prod_rels pr WHERE pr.relname = er.rel)
),
expected_cols(ref, rel, col) AS (VALUES
${COL_VALUES}
),
col_drift AS (
  SELECT ec.ref, ec.rel || '.' || ec.col AS object, 'MISSING_COLUMN' AS detail
  FROM expected_cols ec
  WHERE ${COL_COND}NOT EXISTS (
    SELECT 1 FROM pg_attribute a
    JOIN prod_rels pr ON pr.oid = a.attrelid
    WHERE pr.relname = ec.rel AND a.attname = ec.col
      AND a.attnum > 0 AND NOT a.attisdropped
  )
)
SELECT kind, ref, object, detail FROM (
  SELECT 'FUNCTION' AS kind, ref, object, detail FROM fn_drift WHERE detail IS NOT NULL
  UNION ALL
  SELECT 'RELATION', ref, object, detail FROM rel_drift
  UNION ALL
  SELECT 'COLUMN', ref, object, detail FROM col_drift
) d
ORDER BY kind, ref, object;

COMMIT;
SQL
)

# DRY_RUN: render + print the SQL and exit, WITHOUT any AWS/prod access. Used by
# the per-PR CI self-check to validate the SQL renders from the contract.
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "[dry-run] rendered drift SQL (no prod access):" >&2
  printf '%s\n' "$SQL"
  exit 0
fi

# ── 3. Fetch prod creds (Secrets Manager) and run SELECT-only on prod ────────
echo "[3/4] reading prod surface (BEGIN READ ONLY, secret=$SECRET_ID)..." >&2
SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
    --region "$REGION" --query SecretString --output text) || fail "cannot read secret $SECRET_ID"
export PGHOST=$(jq -r .DB_HOST <<<"$SECRET")
export PGPORT=$(jq -r '.DB_PORT // "5432"' <<<"$SECRET")
export PGUSER=$(jq -r .DB_USER <<<"$SECRET")
export PGPASSWORD=$(jq -r .DB_PASSWORD <<<"$SECRET")
export PGDATABASE=$(jq -r .DB_NAME <<<"$SECRET")

run_psql() {
  if command -v psql >/dev/null; then
    psql -tA -F$'\t' -v ON_ERROR_STOP=1
  else
    docker run --rm -i --network host \
      -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE \
      postgres:15-alpine psql -tA -F$'\t' -v ON_ERROR_STOP=1
  fi
}
DRIFT=$(printf '%s\n' "$SQL" | run_psql) || fail "prod query failed"

# ── 4. Report ────────────────────────────────────────────────────────────────
echo "[4/4] result:" >&2
if [ -z "$(echo "$DRIFT" | tr -d '[:space:]')" ]; then
  echo "✅ CLEAN — no drift. All $N_FN functions + $N_REL relation refs match prod ($PGDATABASE)."
  exit 0
fi
echo "❌ DRIFT DETECTED — prod ($PGDATABASE) diverges from the refdata-api contract:"
echo
printf 'KIND\tREF\tOBJECT\tDETAIL\n'
echo "$DRIFT"
echo
echo "A prod flip would break the listed reads. Reconcile datasets.go/main.go with prod"
echo "(or fix the prod object), refresh the golden (UPDATE_GOLDEN=1 go test ...), re-run."
exit 1
