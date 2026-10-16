-- 15-equipments-net-machine.sql — line NET/output source for line-from-lead OEE
-- (stream-engine internal/rollup/line_lead.go, compute.go).
--
-- lead_machine is the line's availability source and, by default, its net source.
-- When the lead is the INFEED (CPACK: BREYER) and output is counted on the last
-- machine (TEXA), net_machine names that outfeed. NULL ⇒ net from lead_machine.
-- Rollups resolve it as COALESCE(net_machine, lead_machine). Idempotent.
-- Staging/prod: db/migrations/t-line-lead-net-machine.

ALTER TABLE public.equipments
    ADD COLUMN IF NOT EXISTS net_machine bigint REFERENCES equipments(id_equipment);

COMMENT ON COLUMN public.equipments.net_machine IS
    'LINE NET/output source for line-from-lead OEE when it is not lead_machine. NULL ⇒ net from lead_machine.';
