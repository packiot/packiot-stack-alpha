#!/usr/bin/env bash
#
# build-wiki.sh — build the layered Packiot wiki into one static site.
#
# WHAT IT DOES
#   1. Copies the layered wiki tree docs/wiki/ (index, glossary, architecture/,
#      subsystems/, components/, reference/, operations/) into a build-staging
#      tree (wiki/build/staging/docs), plus docs/adr/*.md into /adr so
#      reference/adr-index.md links resolve. Writing rules: docs/WIKI-STYLE.md.
#   2. Runs mkdocs-material against wiki/mkdocs.yml.
#   3. Emits self-contained static HTML to dist/wiki/ (synced to /var/www/wiki
#      on the box; see docs/wiki/components/wiki-pipeline.md).
#
# IDEMPOTENT: the staging + dist dirs are wiped and rebuilt each run.
# NETWORK: none at serve time; a one-time `pip install` into a local venv if
#   mkdocs isn't already on PATH.
#
# USAGE
#   scripts/build-wiki.sh
#   STRICT=1 scripts/build-wiki.sh     # fail on any warning (broken links etc.)
#
# ENV
#   NO_VENV=1  do not auto-create a venv; require mkdocs already on PATH (CI uses this)
#   STRICT=1   pass --strict to mkdocs

set -euo pipefail

# --- locate repo root (this script lives in <root>/scripts) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

STAGING="$ROOT/wiki/build/staging/docs"
DIST="$ROOT/dist/wiki"
MKDOCS_CFG="$ROOT/wiki/mkdocs.yml"

log() { printf '\033[1;34m[build-wiki]\033[0m %s\n' "$*"; }

# --- 1. clean + create the staging tree -----------------------------------
log "resetting staging tree: $STAGING"
rm -rf "$ROOT/wiki/build/staging"
mkdir -p "$STAGING/adr"

# The wiki is ONE layered tree (docs/wiki/: index, glossary, architecture/,
# subsystems/, components/, reference/, operations/) — see docs/WIKI-STYLE.md.
# It replaced the two flat sets (old numbered Stack Wiki + Guide), now archived
# under docs/archive/wiki-v1/ and not published.
if [ ! -f "$ROOT/docs/wiki/index.md" ]; then
  echo "ERROR: docs/wiki/index.md not found in the working tree" >&2
  exit 1
fi
log "copying the layered wiki tree from docs/wiki/"
cp -R "$ROOT"/docs/wiki/. "$STAGING/"

# --- 5. ADRs (linked from reference/adr-index.md) --------------------------
# Only the top-level NNNN-*.md ADRs. The adr/reference/ subtree is intentionally NOT vendored (it carries
# its own cross-refs to non-doc paths). Not in nav; link-resolution only.
if compgen -G "$ROOT/docs/adr/*.md" >/dev/null; then
  log "copying top-level ADRs from docs/adr/ (link-resolution only, not in nav)"
  cp "$ROOT"/docs/adr/*.md "$STAGING/adr/"
  # ADRs link to repo files outside the site; point those at GitHub so --strict passes.
  python3 "$ROOT/scripts/wiki-rewrite-adr-links.py" "$STAGING/adr" "$ROOT"
fi

# --- 6. resolve mkdocs (venv bootstrap if needed) --------------------------
if command -v mkdocs >/dev/null 2>&1; then
  MKDOCS="mkdocs"
elif [ "${NO_VENV:-0}" = "1" ]; then
  echo "ERROR: mkdocs not on PATH and NO_VENV=1 set. Install wiki/requirements.txt first." >&2
  exit 1
else
  VENV="$ROOT/wiki/.venv-wiki"
  if [ ! -x "$VENV/bin/mkdocs" ]; then
    log "mkdocs not found — bootstrapping venv at $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet -r "$ROOT/wiki/requirements.txt"
  fi
  MKDOCS="$VENV/bin/mkdocs"
fi

# --- 7. build ---------------------------------------------------------------
log "building site → $DIST"
rm -rf "$DIST"
"$MKDOCS" build --config-file "$MKDOCS_CFG" --clean ${STRICT:+--strict}

log "done. Static site at: $DIST"
log "  entry:  $DIST/index.html"
log "  sync to box:  aws s3 sync '$DIST/' s3://<bucket>/wiki/  (see docs/wiki/components/wiki-pipeline.md)"
