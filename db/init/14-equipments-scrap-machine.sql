-- 14-equipments-scrap-machine.sql — split-instrumentation SCRAP source for
-- line-from-lead OEE (oeecloud-worker internal/rollup/line_lead.go).
--
-- WHY (the counter-role matrix). The line-from-lead pass derives a tp=3 LINE's
-- runtime from its designated machines, reconciling the three production counters
-- via the identity gross = net + scrap (ProdConsumedCount = ProdProcessedCount +
-- ProdDefectiveCount). gross_machine (migration 13) already names the gross/input
-- source; this column names the SCRAP/defect source so a line that reports only
-- two of the three counters can have the missing one filled:
--   N+S (net + scrap, no gross) → gross = net + scrap
--   G+S (gross + scrap, no net) → net   = gross - scrap
-- Without a scrap counter the reconciliation collapses to the pre-scrap G+N /
-- net-only behaviour, so nothing changes for existing lines.
--
-- THE COLUMN. scrap_machine names the machine whose ProdDefectiveCount is this
-- line's scrap/defect source. lead_machine stays the NET/output + availability
-- source; gross_machine (or lead) is the gross source.
--
--   NULL     — no scrap counter (default): scrap sums to 0, quality defaults to
--              1.0 unless both gross and net are independently reported.
--   <id_eq>  — scrap summed from this machine's ca_agg_equipment_values_1hour
--              (scrap_incr), same time bounds as gross/net.
--
-- line_lead.go reads it as eq.scrap_machine AS scrap_id (no COALESCE): a NULL id
-- matches no cagg rows ⇒ scrap = 0 ⇒ the identity CASEs reduce to today's logic.
-- Availability sessionization is UNCHANGED — it always reads lead_machine.
--
-- Reference-plane table: equipments lives in `public` on BOTH the main DB and
-- packiot_analytics (RefSchema=public in flows.Standard), and refsync mirrors it
-- main->shadow via SELECT * so the new column propagates automatically once it
-- exists on both. Apply this ALTER to public.equipments on every DB that runs the
-- rollup (main + packiot_analytics). Idempotent — safe to re-run.
--
-- NOTE: db/init/ runs ONCE on a fresh local-dev Postgres boot (see README). For an
-- already-provisioned staging/prod/shadow DB this file does NOT auto-run; apply the
-- ALTER below manually (or via the edge-api/edge-node-red migration path) BEFORE a
-- line designates a scrap_machine. The scrap_id NULL default keeps NULL == today, so
-- nothing breaks until a line opts in by setting the column.

ALTER TABLE public.equipments
    ADD COLUMN IF NOT EXISTS scrap_machine bigint REFERENCES equipments(id_equipment);

COMMENT ON COLUMN public.equipments.scrap_machine IS
    'Split-instrumentation SCRAP source for line-from-lead OEE: the machine whose ProdDefectiveCount is this line''s scrap/defect stream. NULL ⇒ no scrap counter (scrap 0). Feeds the gross = net + scrap identity so a line reporting only two of the three counters gets the third filled.';
