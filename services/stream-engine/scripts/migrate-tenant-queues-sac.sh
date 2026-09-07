#!/usr/bin/env bash
#
# migrate-tenant-queues-sac.sh — one-time migration to enable RabbitMQ
# single-active-consumer (SAC) on oeecloud-worker per-tenant MAIN queues.
#
# WHY THIS EXISTS
#   Queue arguments are IMMUTABLE in RabbitMQ. The per-tenant main queues
#   (oeecloud-worker-q-<tenant>) were originally declared WITHOUT the
#   `x-single-active-consumer` argument. You cannot add it by redeclaring —
#   RabbitMQ answers with 406 PRECONDITION_FAILED and closes the channel.
#   The only way to add an immutable arg is to DELETE and RECREATE the queue.
#
#   The worker re-declares its topology on every (re)connect and on discovering
#   a new tenant, so once the old queues are gone it will recreate them WITH the
#   SAC arg automatically (provided WORKER_POOL_SAC_ENABLED=true is set). This
#   script just does the destructive delete safely and in the right order.
#
# SAFETY
#   - Deleting a queue drops any messages still sitting in it. Run this in a
#     LOW-TRAFFIC window. The worker's ingest is at-least-once and every writer
#     is idempotent (UPSERT by natural key); the edge-transformer Calc re-seeds
#     counter baselines on first observation after a gap, so a brief queue
#     absence heals — but do NOT run this during a backlog drain.
#   - Only the MAIN queue needs SAC. The -retry-30s / -failed queues have NO
#     active consumer (retry is TTL→DLX, failed is human-inspection), so this
#     script leaves them untouched.
#   - Idempotent: deleting an already-absent queue is a no-op (the mgmt CLI
#     returns non-zero which we tolerate).
#
# USAGE
#   RABBITMQ_CONTAINER=stack-rabbitmq-1 \
#   WORKER_QUEUE=oeecloud-worker-q \
#     ./migrate-tenant-queues-sac.sh cpack acme foo
#
#   # or auto-detect tenant queues from the broker (no explicit list):
#   RABBITMQ_CONTAINER=stack-rabbitmq-1 ./migrate-tenant-queues-sac.sh
#
# THEN
#   1. Set WORKER_POOL_SAC_ENABLED=true (+ OEECLOUD_WORKER_REPLICAS=N) and
#      redeploy the worker pool. The worker recreates each main queue WITH the
#      SAC arg on its next topology declaration.
#   2. Verify: the worker log line `amqp topology declared` shows
#      single_active_consumer=true, and `rabbitmqctl list_queues name
#      arguments` shows x-single-active-consumer on each main queue.
#
set -euo pipefail

RABBITMQ_CONTAINER="${RABBITMQ_CONTAINER:-stack-rabbitmq-1}"
WORKER_QUEUE="${WORKER_QUEUE:-oeecloud-worker-q}"
VHOST="${RABBITMQ_VHOST:-/}"

rmq() { sudo docker exec "$RABBITMQ_CONTAINER" "$@"; }

# Resolve the tenant list: explicit args, else discover MAIN queues on the
# broker (exclude -retry-30s / -failed and the bare legacy queue).
tenants=("$@")
if [[ ${#tenants[@]} -eq 0 ]]; then
  echo "No tenants given — discovering main queues matching ${WORKER_QUEUE}-<tenant> ..."
  mapfile -t tenants < <(
    rmq rabbitmqctl list_queues -p "$VHOST" name --no-table-headers \
      | awk -v p="${WORKER_QUEUE}-" '
          index($1, p) == 1 \
          && $1 !~ /-retry-30s$/ \
          && $1 !~ /-failed$/ { sub(p, "", $1); print $1 }'
  )
fi

if [[ ${#tenants[@]} -eq 0 ]]; then
  echo "No tenant queues found. Nothing to migrate."
  exit 0
fi

echo "About to DELETE these MAIN tenant queues (retry/failed left intact):"
for t in "${tenants[@]}"; do echo "  - ${WORKER_QUEUE}-${t}"; done
echo
read -r -p "Proceed? messages in these queues will be dropped. [yes/NO] " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }

for t in "${tenants[@]}"; do
  q="${WORKER_QUEUE}-${t}"
  echo "Deleting ${q} ..."
  # delete_queue is idempotent enough for our purposes; tolerate 'not found'.
  rmq rabbitmqctl delete_queue "$q" -p "$VHOST" || echo "  (already absent — ok)"
done

echo
echo "Done. Now set WORKER_POOL_SAC_ENABLED=true (+ OEECLOUD_WORKER_REPLICAS=N)"
echo "and redeploy the worker — it recreates each main queue WITH"
echo "x-single-active-consumer on its next topology declaration."
