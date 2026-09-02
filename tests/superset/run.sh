#!/usr/bin/env bash
# W2 Superset per-tenant isolation GATE — see docs/plans/w2-embedded-superset.md §8.
# Spins an ephemeral Postgres (docker), applies db/superset/*.sql, proves 2-tenant
# isolation + the no-view-without-a-rule guard. Blocking check: no tenant sees a
# chart until this is green on staging.
#
#   ./tests/superset/run.sh                 # ephemeral docker Postgres
#   SUPERSET_TEST_PG_DSN=postgresql://...  ./tests/superset/run.sh   # throwaway server
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -m pip install -q -r "$here/requirements.txt"
# -p no:cacheprovider keeps it hermetic in CI; rootdir pinned to this dir so the
# module's local conftest.py (ephemeral-PG harness) is the one that loads.
exec python3 -m pytest "$here" -q -o cache_dir=/tmp/superset-gate-cache "$@"
