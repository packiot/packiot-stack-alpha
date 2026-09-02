#!/usr/bin/env bash
#
# build-wiki.sh — assemble the two Packiot doc sets into one static site.
#
# WHAT IT DOES
#   1. Assembles a build-staging tree (wiki/build/staging/docs) from TWO sources
#      that live in different git trees:
#        - docs/guide/*   (the polished Guide, on the mainline branch / working tree)
#        - docs/wiki/*    (the commissioned Stack Wiki; on origin/staging when not
#                          present in the working tree)
#      plus docs/adr/**   (copied so the Guide's ../adr cross-refs resolve)
#      plus the generated Home + Onboarding pages under wiki/pages/.
#   2. Runs mkdocs-material against wiki/mkdocs.yml.
#   3. Emits self-contained static HTML to dist/wiki/  (this is what gets synced
#      to /var/www/wiki on the box).
#
# IDEMPOTENT: the staging + dist dirs are wiped and rebuilt each run.
# NETWORK: none needed at serve time. The only network use is (a) `git fetch`
#   of the wiki ref if it isn't available locally, and (b) a one-time `pip install`
#   into a local venv if mkdocs isn't already on PATH.
#
# USAGE
#   scripts/build-wiki.sh              # build using $WIKI_REF (default origin/staging)
#   WIKI_REF=staging scripts/build-wiki.sh
#
# ENV
#   WIKI_REF   git ref that carries docs/wiki when it's not in the working tree
#              (default: origin/staging)
#   NO_VENV=1  do not auto-create a venv; require mkdocs already on PATH (CI uses this)

set -euo pipefail

# --- locate repo root (this script lives in <root>/scripts) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

WIKI_REF="${WIKI_REF:-origin/staging}"
STAGING="$ROOT/wiki/build/staging/docs"
DIST="$ROOT/dist/wiki"
MKDOCS_CFG="$ROOT/wiki/mkdocs.yml"

log() { printf '\033[1;34m[build-wiki]\033[0m %s\n' "$*"; }

# --- 1. clean + create the staging tree -----------------------------------
log "resetting staging tree: $STAGING"
rm -rf "$ROOT/wiki/build/staging"
mkdir -p "$STAGING/guide" "$STAGING/wiki" "$STAGING/adr" "$STAGING/onboarding"

# --- 2. Home + Onboarding pages (committed, generated content) -------------
log "copying assembled pages (Home + Onboarding)"
cp "$ROOT/wiki/pages/index.md"                "$STAGING/index.md"
cp "$ROOT/wiki/pages/first-time-box-setup.md" "$STAGING/onboarding/first-time-box-setup.md"

# --- 3. Guide (always from the working tree) -------------------------------
if [ ! -d "$ROOT/docs/guide" ]; then
  echo "ERROR: docs/guide not found in the working tree" >&2
  exit 1
fi
log "copying Guide from docs/guide/"
cp "$ROOT"/docs/guide/*.md "$STAGING/guide/"

# --- 4. Stack Wiki (working tree if present, else from $WIKI_REF) ----------
if [ -d "$ROOT/docs/wiki" ] && ls "$ROOT"/docs/wiki/*.md >/dev/null 2>&1; then
  log "copying Stack Wiki from working tree docs/wiki/"
  cp "$ROOT"/docs/wiki/*.md "$STAGING/wiki/"
else
  log "docs/wiki not in working tree — extracting from $WIKI_REF"
  if ! git rev-parse --verify --quiet "$WIKI_REF" >/dev/null; then
    # e.g. origin/staging not fetched yet
    remote="${WIKI_REF%%/*}"; branch="${WIKI_REF#*/}"
    log "ref $WIKI_REF unavailable locally — git fetch $remote $branch"
    git fetch --depth=1 "$remote" "$branch"
  fi
  # list + extract every markdown file under docs/wiki at that ref
  git ls-tree -r --name-only "$WIKI_REF" -- docs/wiki/ \
    | grep '\.md$' \
    | while read -r f; do
        git show "$WIKI_REF:$f" > "$STAGING/wiki/$(basename "$f")"
      done
fi

# sanity: the wiki README is the section landing — it must be present
if [ ! -f "$STAGING/wiki/README.md" ]; then
  echo "ERROR: Stack Wiki README.md missing after assembly (check WIKI_REF=$WIKI_REF)" >&2
  exit 1
fi

# --- 5. ADRs (for the Guide's ../adr cross-refs) ---------------------------
# Only the top-level NNNN-*.md ADRs — those are what the Guide's Decision Log
# indexes. The adr/reference/ subtree is intentionally NOT vendored (it carries
# its own cross-refs to non-doc paths). Not in nav; link-resolution only.
if compgen -G "$ROOT/docs/adr/*.md" >/dev/null; then
  log "copying top-level ADRs from docs/adr/ (link-resolution only, not in nav)"
  cp "$ROOT"/docs/adr/*.md "$STAGING/adr/"
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
"$MKDOCS" build --config-file "$MKDOCS_CFG" --clean

log "done. Static site at: $DIST"
log "  entry:  $DIST/index.html"
log "  sync to box:  aws s3 sync '$DIST/' s3://<bucket>/wiki/  (see docs/wiki-deploy.md)"
