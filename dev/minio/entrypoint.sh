#!/bin/sh
# MinIO + bucket bootstrap in ONE container, so "minio healthy" means "the
# historian bucket exists" and `docker compose up --wait` works (a separate
# one-shot init container that exits 0 makes `up --wait` fail).
#
# Mirrors terraform/staging/historian.tf: one historian bucket, versioning on.
# Idempotent: --ignore-existing, and re-enabling versioning is a no-op.
set -eu

: "${MINIO_ROOT_USER:?}" "${MINIO_ROOT_PASSWORD:?}" "${HISTORIAN_BUCKET:?}"
rm -f /tmp/bucket-ready

minio server /data --console-address ":9001" &
pid=$!
# sh as PID 1 does not forward signals; do it so `docker stop` is graceful.
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

until mc alias set dev http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  kill -0 "$pid" 2>/dev/null || { echo "minio exited during startup" >&2; exit 1; }
  sleep 1
done
mc mb --ignore-existing "dev/$HISTORIAN_BUCKET"
mc version enable "dev/$HISTORIAN_BUCKET"
touch /tmp/bucket-ready
echo "historian bucket ready: $HISTORIAN_BUCKET"

wait "$pid"
