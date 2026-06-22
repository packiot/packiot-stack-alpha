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
--   3. Isolation test — pause Node-RED for a controlled window and verify
--      the worker keeps writing at the same rate.
--
-- The /health endpoint on http://172.18.0.20:9101/health exposes the
-- worker's `delivered` and `acked` counters; subtracting two snapshots
-- gives the per-period throughput. Node-RED has no comparable counter
-- so we compare worker /health throughput vs DB row delta in the same
-- window — they should match within a few %.
--
-- Run on the DB EC2:
--   sudo docker exec -i timescaledb psql -U postgres -d packiot < parity-check.sql

-- ── A. equipment_values throughput (last 5 minutes, per minute) ──────────────
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

-- ── C. AMQP queue depths (sanity — neither should backlog) ──────────────────
-- Run on app EC2 instead:
--   sudo docker exec stack-rabbitmq-1 rabbitmqctl list_queues name messages consumers \
--     | grep -E 'oeecloud-(q|worker-q)'

-- ── D. Isolation test (decommission rehearsal) ─────────────────────────────────
-- 1. Snapshot the worker's /health counters:
--      curl http://172.18.0.20:9101/health
-- 2. Stop the Node-RED consumer (NOT the container — just unbind):
--      docker exec stack-rabbitmq-1 rabbitmqctl delete_queue oeecloud-q
--    (rebind on cancel; messages keep flowing only to oeecloud-worker-q)
-- 3. Wait 5 minutes. Re-run query A above.
-- 4. If write rate maintains (~ minutes-per-equipment same as before),
--    worker has full parity for the kinds it handles.
-- 5. Restore Node-RED's queue by restarting stack-oeecloud-1 (it reasserts).

-- ── E. Decommission gate ──────────────────────────────────────────────────────
-- Required conditions before stopping Node-RED permanently:
--   ✓ Worker /health: nacked_to_retry/delivered < 0.001 over 24h
--   ✓ A's write rate >= today's baseline (compare to a snapshot taken now)
--   ✓ uns_equipment_current_metrics staleness < 10s for every active equipment
--   ✓ No DLQ growth in oeecloud-worker-q-failed
--   ✓ Isolation test (D) successful
-- After all conditions hold:
--   1. Stop stack-oeecloud-1: docker compose -f compose.staging.yml stop oeecloud
--   2. Delete oeecloud-q + its 9 GB SQLite buffer: see task #29 description
--   3. Remove oeecloud-node-red from compose.staging.yml + push
--   4. Reclaim /var/lib/docker/volumes/stack_nr-oeecloud-data
