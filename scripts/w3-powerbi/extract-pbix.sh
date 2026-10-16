#!/usr/bin/env bash
# extract-pbix.sh — decompile a .pbix into a diffable source tree for W3 migration.
#
# PREP STUB: runnable the moment you have a .pbix. Does the OS-agnostic parts
# (ZIP peek) always; runs pbi-tools if it's on PATH (Windows-first — see
# docs/plans/w3-powerbi-migration-readiness.md §3).
#
# A .pbix is a ZIP:
#   Report/Layout   -> the visual tree (rebuild targets)
#   DataMashup      -> Power Query (M) source + data-source bindings
#   Connections     -> connection strings
#   DataModel       -> VertiPaq tabular model (measures live here; use pbi-tools/DAX Studio)
#
# Usage: extract-pbix.sh <report.pbix> [outdir]
# Output: <outdir>/{zip/,pbi-tools/}  + a manifest of parts.
#
# NOTE: .pbix files embed cached data + connection strings (historically secrets).
#       Keep <outdir> private; never commit .pbix or its extract to git.

set -euo pipefail

PBIX="${1:?usage: extract-pbix.sh <report.pbix> [outdir]}"
OUT="${2:-./extract/$(basename "${PBIX%.pbix}")}"

[[ -f "$PBIX" ]] || { echo "no such .pbix: $PBIX" >&2; exit 1; }
mkdir -p "$OUT/zip"

echo "[1/3] listing .pbix parts (it's a ZIP)…"
unzip -l "$PBIX" | tee "$OUT/parts.txt"

echo "[2/3] extracting ZIP parts → $OUT/zip …"
unzip -o "$PBIX" -d "$OUT/zip" >/dev/null
echo "  Report/Layout : $( [[ -e "$OUT/zip/Report/Layout" ]] && echo present || echo MISSING )"
echo "  DataMashup    : $( [[ -e "$OUT/zip/DataMashup" ]]   && echo present || echo MISSING )"
echo "  DataModel     : $( [[ -e "$OUT/zip/DataModel" ]]    && echo 'present (use pbi-tools/DAX Studio to read)' || echo MISSING )"

echo "[3/3] pbi-tools decompile (model + layout as JSON/TMDL)…"
if command -v pbi-tools >/dev/null 2>&1; then
  pbi-tools extract "$PBIX" -extractFolder "$OUT/pbi-tools"
  echo "  -> $OUT/pbi-tools/Model/  (tables, measures[DAX], relationships)"
  echo "  -> $OUT/pbi-tools/Report/ (pages + visuals)"
else
  cat <<'EOF'
  pbi-tools NOT on PATH — skipped. Install from https://github.com/pbi-tools/pbi-tools
  (Windows-first; run under .NET6 build or a Windows CI runner). Meanwhile:
    - DAX measures : open the .pbix in PowerBI Desktop → DAX Studio → Export Metrics
    - Model shape  : Tabular Editor (free v2) → export TMSL
    - Inventory/.pbix at scale : PowerBI REST API (see §3.4)
EOF
fi

echo "DONE. Next: fill docs/plans/w3-powerbi/per-report-migration-template.md from $OUT"
