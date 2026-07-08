#!/usr/bin/env bash
# test-customization-lint.sh — self-test for scripts/lint-customization-flows.py
#
# Asserts:
#   - the GOOD fixture passes (exit 0)
#   - each BAD fixture fails (exit 1) AND emits its expected rule tag
#   - an empty glob is a clean pass (exit 0) — the CI "no flows yet" case
#
# Stdlib/bash only, no deps. Run from anywhere; paths resolve off the repo root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="${REPO_ROOT}/scripts/lint-customization-flows.py"
FIX="${REPO_ROOT}/scripts/test/customization-flows"

pass=0
fail=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

# expect_pass <fixture>
expect_pass() {
    local file="$1" out rc
    out="$(python3 "$LINT" "$file" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        green "PASS  clean exit(0)         $(basename "$file")"; pass=$((pass+1))
    else
        red   "FAIL  expected exit 0, got $rc   $(basename "$file")"; echo "$out"; fail=$((fail+1))
    fi
}

# expect_fail <fixture> <expected-rule-tag>
expect_fail() {
    local file="$1" tag="$2" out rc
    out="$(python3 "$LINT" "$file" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -q "\[$tag\]" <<<"$out"; then
        green "PASS  exit($rc) + [$tag]    $(basename "$file")"; pass=$((pass+1))
    else
        red   "FAIL  expected exit 1 + [$tag], got exit $rc   $(basename "$file")"
        echo "$out"; fail=$((fail+1))
    fi
}

echo "== customization-flow lint self-test =="

expect_pass "${FIX}/good-customization-flow.json"

expect_fail "${FIX}/bad-secret-value.json"       SECRET_VALUE
expect_fail "${FIX}/bad-exec-node.json"          FORBIDDEN_NODE
expect_fail "${FIX}/bad-file-node.json"          FORBIDDEN_NODE
expect_fail "${FIX}/bad-ingest-node.json"        INGEST_NODE
expect_fail "${FIX}/bad-dbwrite-core.json"       DBWRITE_CORE
expect_fail "${FIX}/bad-oversized-function.json" OVERSIZED_FUNCTION
expect_fail "${FIX}/bad-deprecated-egress.json"  DEPRECATED_EGRESS

# empty-glob case: a glob that matches nothing must exit 0 (CI "no flows yet").
out="$(python3 "$LINT" "${REPO_ROOT}/clients/__none__/customizations/*.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    green "PASS  empty glob exits 0     (CI no-flows-yet case)"; pass=$((pass+1))
else
    red   "FAIL  empty glob expected exit 0, got $rc"; echo "$out"; fail=$((fail+1))
fi

echo
echo "results: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
green "all customization-lint self-tests green"
