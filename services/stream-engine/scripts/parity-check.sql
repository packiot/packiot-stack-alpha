-- parity-check.sql — observation queries for the worker-vs-Node-RED transition.
--
-- BOTH consumers (oeecloud-node-red via oeecloud-q, oeecloud-worker via
-- oeecloud-worker-q) bind to the same `oee` exchange and UPSERT into the
-- same equipment_values + uns_equipment_current_metrics rows. They overwrite
-- each other on conflict, so we can't tell *which* writer wrote a given row
-- just by querying these tables.
--
-- Parity is therefore measured indirectly:
--   1. Volume comparison — count rows written per minute over a sliding
--      window. If the worker's write rate matches Node-RED's, both are
--      seeing the same input.
--   2. Freshness comparison — MAX(ts_value) should be within ~1s of NOW()
--      from either consumer's perspective.
--   3. Isolation test — stop Node-RED (non-destructively) and verify the
--      worker keeps writing at the same rate.
--
-- The /health endpoint on http://172.18.0.20:9101/health exposes the
-- worker's `delivered` and `acked` counters. Use the DELTA between two
-- snapshots (now vs 24h later) to size throughput — the cumulative
-- counters reset on every redeploy, so absolute ratios are misleading
-- if the worker has been restarted in the window.
--
-- Run on the DB EC2:
--   sudo docker exec -i timescaledb psql -U postgres -d packiot < parity-check.sql

-- ── A. equipment_values throughput (last 5 minutes, per minute) ──────────────
-- Quick sanity check. For the 24h decommission gate (Section E) swap
-- '5 minutes' for '24 hours' and bump LIMIT 5 to LIMIT 60 (or remove).
SELECT date_trunc('minute', ts_value) AS minute,
       COUNT(*)                          AS rows_written,
       COUNT(*) FILTER (WHERE state IS NOT NULL)                  AS state_set,
       COUNT(*) FILTER (WHERE mode IS NOT NULL)                   AS mode_set,
       COUNT(*) FILTER (WHERE net_production_incr   IS NOT NULL)  AS net_set,
       COUNT(*) FILTER (WHERE gross_production_incr IS NOT NULL)  AS gross_set,
       COUNT(*) FILTER (WHERE scrap_incr            IS NOT NULL)  AS scrap_set,
       COUNT(*) FILTER (WHERE ideal_production_speed IS NOT NULL) AS ideal_speed_set
  FROM public.equipment_values
 WHERE id_enterprise = 3
   AND ts_value > NOW() - interval '5 minutes'
 GROUP BY date_trunc('minute', ts_value)
 ORDER BY minute DESC
 LIMIT 5;

-- ── B. uns_equipment_current_metrics freshness ──────────────────────────────
-- Worker writes here for CurMachSpeed. updated_at should be fresh for every
-- equipment currently sending data.
SELECT id_equipment,
       speed,
       updated_at,
       NOW() - updated_at AS staleness
  FROM public.uns_equipment_current_metrics
 WHERE id_enterprise = 3
   AND updated_at > NOW() - interval '5 minutes'
 ORDER BY updated_at DESC
 LIMIT 20;

-- ── C. AMQP queue depths — neither should backlog ──────────────────────────
-- Run on app EC2 instead:
--   sudo docker exec stack-rabbitmq-1 rabbitmqctl list_queues name messages consumers \
--     | grep -E 'oeecloud-(q|worker-q)'
--
-- Also check the failed-queue depth — if it has grown since the worker
-- started, something is silently going to terminal failure:
--   sudo docker exec stack-rabbitmq-1 rabbitmqctl list_queues name messages \
--     | grep 'oeecloud-worker-q-failed'
-- Expected: 0. Non-zero means investigate via:
--   sudo docker exec stack-rabbitmq-1 rabbitmqadmin get queue=oeecloud-worker-q-failed count=5

-- ── D. Isolation test (decommission rehearsal — NON-DESTRUCTIVE) ────────────
-- 1. Snapshot the worker's /health counters:
--      curl http://172.18.0.20:9101/health > /tmp/health-before.json
-- 2. Stop the Node-RED CONTAINER (not the queue — queue stays so messages
--    buffer for Node-RED while it's down, and Node-RED drains them on restart):
--      sudo docker compose -f compose.staging.yml stop oeecloud
-- 3. Wait 5 minutes. Re-run query A above; throughput should be unchanged
--    because the worker handles everything the operator UI / Grafana
--    surface needs (state, mode, counters, speed).
-- 4. Snapshot /health again:
--      curl http://172.18.0.20:9101/health > /tmp/health-after.json
--    Compute delta(delivered) and delta(acked); they should match within
--    a few % and grow at the expected ~25 msg/s × 5 min ≈ 7,500.
-- 5. Restart Node-RED — it drains its buffered queue on reconnect:
--      sudo docker compose -f compose.staging.yml start oeecloud

-- ── E. Decommission gate (24-hour observation window) ──────────────────────
-- Required conditions before stopping Node-RED permanently. ALL must hold
-- over a continuous 24-hour window WITHOUT a worker redeploy (redeploy
-- resets the worker's cumulative counters).
--
--   ✓ delta(worker.delivered) over the window ≈ expected message count
--     (snapshot /health at start + end of window, subtract)
--   ✓ delta(worker.nacked_to_retry) ≈ 0 over the window
--   ✓ delta(worker.published_to_failed) == 0 over the window
--   ✓ oeecloud-worker-q-failed queue depth has not grown
--   ✓ A's write rate over the window matches today's baseline
--   ✓ uns_equipment_current_metrics staleness < 10s for every active
--     equipment continuously
--   ✓ Isolation test (D) passed
--
-- After all conditions hold:
--   1. Stop stack-oeecloud-1: docker compose -f compose.staging.yml stop oeecloud
--   2. (Wait 5 more minutes to confirm worker keeps writing.)
--   3. Delete oeecloud-q + its 9 GB SQLite buffer: see task #29 description
--   4. Remove oeecloud-node-red from compose.staging.yml + push
--   5. Reclaim /var/lib/docker/volumes/stack_nr-oeecloud-data
