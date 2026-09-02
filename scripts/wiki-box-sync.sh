#!/usr/bin/env bash
#
# wiki-box-sync.sh — runs ON the box (i-02d255a1c21fb1da3). Pulls the built wiki
# site from S3 into /var/www/wiki, where the nginx wiki.packiot.app vhost serves
# it (that vhost is owned by a separate agent / terraform+nginx change).
#
# This is the PULL half of the delivery model: CI pushes dist/wiki/ to S3
# (see .github/workflows/build-wiki.yml), the box pulls on a systemd timer / cron.
# Pull decouples delivery from user_data — the box has ignore_changes=[user_data]
# so it never rebuilds from user_data; this sync is how new docs land.
#
# Requires: awscli on the box + the box's instance profile granting
#   s3:ListBucket + s3:GetObject on the wiki bucket/prefix (read-only).
#
# Install: see docs/wiki-deploy.md (systemd timer or cron every 5 min).

set -euo pipefail

BUCKET="${WIKI_S3_BUCKET:?set WIKI_S3_BUCKET to the docs bucket name}"
PREFIX="${WIKI_S3_PREFIX:-wiki}"
DEST="${WIKI_WWW_ROOT:-/var/www/wiki}"

mkdir -p "$DEST"

# --delete makes the local tree an exact mirror of S3 (removes stale pages).
aws s3 sync "s3://${BUCKET}/${PREFIX}/" "$DEST/" --delete --only-show-errors

echo "[wiki-box-sync] synced s3://${BUCKET}/${PREFIX}/ -> ${DEST} at $(date -Is)"
