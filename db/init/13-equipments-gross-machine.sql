-- 13-equipments-gross-machine.sql — split-instrumentation GROSS source for
-- line-from-lead OEE (oeecloud-worker internal/rollup/line_lead.go).
--
-- WHY (the split-instrumentation gap). The line-from-lead pass derives a tp=3
-- LINE's runtime from ONE designated machine — equipments.lead_machine — reading
-- gross, net, AND availability off that single machine's continuous aggregates.
-- That holds when one machine reports BOTH gross (ProdConsumedCount) and net
-- (ProdProcessedCount). It breaks on a SPLIT-INSTRUMENTATION line where the gross
-- counter is on the INPUT machine and the net counter is on a DIFFERENT OUTPUT
-- machine — no single machine carries both, so borrowing net+gross from one lead
-- yields gross=0 (net-only lead) or net=0 (gross-only lead) → oee_q collapses to 0.
-- Example: line L3 has gross on POLYTYPE/TEXA/RMH (net=0) and net ONLY on
-- L3-BREYER (gross=0).
--
-- THE COLUMN. gross_machine names the machine whose ProdConsumedCount is this
-- line's gross/input source. lead_machine stays the NET/output + availability
-- source (the output machine's productive cadence represents the line running).
--
--   NULL     — single-lead line (default): gross comes from lead_machine too,
--              behaviour is byte-identical to the pre-split pass.
--   <id_eq>  — split-instrumentation line: gross summed from this machine's
--              ca_agg_equipment_values_1hour, net summed from lead_machine's.
--
-- line_lead.go resolves it as COALESCE(eq.gross_machine, eq.lead_machine) so the
-- NULL case is a no-op. Availability sessionization is UNCHANGED — it always
-- reads lead_machine (see line_lead.go). Only the GROSS source moves.
--
-- Reference-plane table: equipments lives in `public` on BOTH the main DB and
-- packiot_shadow (RefSchema=public in flows.Standard), and refsync mirrors it
-- main->shadow via SELECT * so the new column propagates automatically once it
-- exists on both. Apply this ALTER to public.equipments on every DB that runs the
-- rollup (main + packiot_shadow). Idempotent — safe to re-run.
--
-- NOTE: db/init/ runs ONCE on a fresh local-dev Postgres boot (see README). For an
-- already-provisioned staging/prod/shadow DB this file does NOT auto-run; apply the
-- ALTER below manually (or via the edge-api/edge-node-red migration path) BEFORE a
-- line designates a gross_machine. The line_lead COALESCE keeps NULL == today, so
-- nothing breaks until a line opts in by setting the column.

ALTER TABLE public.equipments
    ADD COLUMN IF NOT EXISTS gross_machine bigint REFERENCES equipments(id_equipment);

COMMENT ON COLUMN public.equipments.gross_machine IS
    'Split-instrumentation GROSS source for line-from-lead OEE: the machine whose ProdConsumedCount is this line''s gross/input. NULL ⇒ use lead_machine for gross too (single-lead line). lead_machine remains the net/output + availability source.';
