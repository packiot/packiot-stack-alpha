#!/usr/bin/env bash
# packml-ratchet.sh — ADR-0061 D8 guard, ratchet form (until P5 deletes the rest).
#
# PackML / topic-derived identity is being removed from the cloud. Until the deletions land, existing references
# are frozen in a per-file baseline and may only SHRINK:
#   - a file not in the baseline that mentions packml        → FAIL (new topic-based identity)
#   - a baselined file whose count went UP                    → FAIL
#   - a baselined file whose count went DOWN, or that is gone → FAIL until the baseline is tightened, so the
#     gain is locked in (run with --update and commit the baseline)
# Scope: services/** and db/migrations/** (the superproject; submodules run the same script in their own CI).
# Markdown is out of scope (D8: historical docs are allowed). Count = matching lines, case-insensitive.
# Exceptions (e.g. the P5 migration that DROPS packml objects) go in scripts/ci/packml-allowlist.txt with a reason.
#
#   scripts/ci/packml-ratchet.sh            check (CI)
#   scripts/ci/packml-ratchet.sh --update   rewrite the baseline from the working tree
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
BASE=scripts/ci/packml-baseline.tsv
ALLOW=scripts/ci/packml-allowlist.txt

current() {
  git grep -i -c 'packml' -- services db/migrations ':(exclude)*.md' 2>/dev/null \
    | awk -F: '{n=$NF; sub(/:[0-9]+$/, ""); printf "%s\t%s\n", n, $0}' | sort -k2
}

if [ "${1:-}" = "--update" ]; then
  current > "$BASE"
  echo "baseline: $(wc -l < "$BASE") files, $(awk -F'\t' '{s+=$1} END{print s+0}' "$BASE") lines → $BASE"
  exit 0
fi

allowed() { [ -f "$ALLOW" ] && grep -v '^\s*#' "$ALLOW" | awk '{print $1}' | grep -qxF "$1"; }

fail=0; tighten=0
declare -A base
while IFS=$'\t' read -r n f; do base["$f"]=$n; done < "$BASE"
declare -A seen
while IFS=$'\t' read -r n f; do
  seen["$f"]=1
  b=${base["$f"]:-}
  if [ -z "$b" ]; then
    if allowed "$f"; then continue; fi
    echo "::error file=$f::new packml reference ($n line(s)) — ADR-0061: identity is declared at birth (id_equipment / device_key), not derived from a topic"
    fail=1
  elif [ "$n" -gt "$b" ]; then
    echo "::error file=$f::packml references grew $b → $n — ADR-0061 ratchet: this file may only shrink"
    fail=1
  elif [ "$n" -lt "$b" ]; then
    echo "tighten: $f $b → $n"; tighten=1
  fi
done < <(current)
for f in "${!base[@]}"; do
  [ -n "${seen[$f]:-}" ] || { echo "tighten: $f ${base[$f]} → 0 (gone)"; tighten=1; }
done

if [ $fail = 1 ]; then exit 1; fi
if [ $tighten = 1 ]; then
  echo "::error::packml references shrank — lock the gain: scripts/ci/packml-ratchet.sh --update && git add $BASE"
  exit 1
fi
echo "packml ratchet OK: $(wc -l < "$BASE") files, $(awk -F'\t' '{s+=$1} END{print s+0}' "$BASE") lines, nothing new"
