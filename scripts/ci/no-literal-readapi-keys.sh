#!/usr/bin/env bash
# no-literal-readapi-keys.sh — guard against read-api keys being committed again.
#
# read-api's QUERY_API_KEYS map (and the operators' REFDATA_API_KEY) authenticate the
# PUBLIC refdata vhost: a committed value means repo access == tenant data. Until
# 2026-10 staging shipped them as compose literals (now burned, see
# docs/runbooks/rotate-readapi-keys.md). Rules, for every tracked file outside dev/
# (dev/ uses dev-only fakes against an anonymized seed):
#   1. compose/YAML: `QUERY_API_KEYS:` / `REFDATA_API_KEY:` must be a bare ${VAR},
#      ${VAR:?msg} or ${VAR:-} (empty default) — no literal, no literal default.
#   2. no file may contain the burned staging key shape `stg-<name>-key`.
# Why not a gitleaks rule: gitleaks.yml scans FULL history, which still holds the old
# literals — a rule would fail forever. This checks the tree, which is what can be fixed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0

# 1. Literal values / literal defaults on the key variables in YAML.
#    Allowed RHS: ${VAR} | ${VAR:?anything} | ${VAR:-} | ${VAR?anything}
bad=$(git grep -n -E '^\s*(QUERY_API_KEYS|REFDATA_API_KEY)\s*:' -- '*.yml' '*.yaml' ':!dev/**' \
  | grep -v -E ':\s*(QUERY_API_KEYS|REFDATA_API_KEY)\s*:\s*"?\$\{[A-Z0-9_]+(:?\?[^}]*|:-)?\}"?\s*(#.*)?$' || true)
if [ -n "$bad" ]; then
  echo "::error::read-api key variables must come from the environment (\${VAR:?...}), never a literal or literal default:"
  echo "$bad" | cut -d: -f1,2 | sed 's/^/  /'   # file:line only — never echo the value
  fail=1
fi

# 2. Burned staging key values anywhere outside dev/ (docs and tests included).
burned=$(git grep -l -E 'stg-[a-z0-9]+-key' -- ':!dev/**' ':!scripts/ci/no-literal-readapi-keys.sh' || true)
if [ -n "$burned" ]; then
  echo "::error::files still reference the burned staging read keys (stg-<name>-key); use a placeholder like <cpack-read-key>:"
  echo "$burned" | sed 's/^/  /'
  fail=1
fi

[ "$fail" -eq 0 ] && echo "OK: no literal read-api keys in the tree (dev/ excluded)"
exit "$fail"
