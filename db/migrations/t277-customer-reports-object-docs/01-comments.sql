-- t277 — document the customer_reports OBJECTS (tables + cryptic/German columns).
-- t275 documented the schema; this documents the 4 external-ERP-contract tables so a
-- browser (pgweb/CloudBeaver) shows what each is. Idempotent (COMMENT). No data change.

-- ── boxes — internal source for the SAP transform ────────────────────────────
COMMENT ON TABLE customer_reports.boxes IS 'Internal box/production source feeding the SAP (sap_data_sync) transform — per-order net production + box qty by equipment/area/site. Not an external contract itself; consumed inside sap13_body.sql / boxes_bridge.go.';
COMMENT ON COLUMN customer_reports.boxes.net_production IS 'Net (good) production count for the order slice.';
COMMENT ON COLUMN customer_reports.boxes.qty IS 'Box count.';

-- ── production_data_sync — Montebello/Incoplast (cust-6) OEE report contract ──
COMMENT ON TABLE customer_reports.production_data_sync IS 'EXTERNAL CONTRACT — Montebello/Incoplast (customer_id=6) per-shift OEE report pool. Written by stream-engine sync06 writer (internal/reports/sync06_body.sql), read via serving.production_data_sync($enterprise) for the external OEE pull. Column names are the customer''s report shape — do NOT rename.';
COMMENT ON COLUMN customer_reports.production_data_sync.totalavailablehrsinmin IS 'Total available time for the shift, in MINUTES (despite the "hrs" name).';
COMMENT ON COLUMN customer_reports.production_data_sync.dtimehrsplannedinmin   IS 'Planned downtime, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.dtimehrsunplannedinmin IS 'Unplanned downtime, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.unplanneddt_proinmin   IS 'Unplanned downtime attributed to PROduction, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.unplanneddt_resinmin   IS 'Unplanned downtime attributed to RESources/material, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.unplanneddt_mntinmin   IS 'Unplanned downtime attributed to MaiNTenance, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.setuphoursinmin IS 'Setup/changeover time, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.runhoursinmin   IS 'Running (producing) time, in minutes.';
COMMENT ON COLUMN customer_reports.production_data_sync.presscnt IS 'Pressed/produced (gross) count.';
COMMENT ON COLUMN customer_reports.production_data_sync.packcnt  IS 'Packed (net/good) count.';
COMMENT ON COLUMN customer_reports.production_data_sync.indice_geral      IS 'Rolling general index (row sequence key for the external sync); prev_indice_geral holds the prior value.';
COMMENT ON COLUMN customer_reports.production_data_sync.trans_status      IS 'Transfer/sync status of the row to the external system (final_trans_status = terminal value).';
COMMENT ON COLUMN customer_reports.production_data_sync.supervisorapproval IS 'Supervisor sign-off flag for the shift record.';
COMMENT ON COLUMN customer_reports.production_data_sync.packiotid IS 'Packiot-side correlation id for the report row.';

-- ── sap_data_sync — Neopac SAP (cust-13) contract; GERMAN field names ─────────
COMMENT ON TABLE customer_reports.sap_data_sync IS 'EXTERNAL CONTRACT — Neopac SAP integration (customer_id=13). Written by stream-engine sap13 writer (internal/reports/sap13_body.sql); pulled by Neopac''s SAP system. Field names are GERMAN per the SAP contract — do NOT rename/translate in-place.';
COMMENT ON COLUMN customer_reports.sap_data_sync.linie                IS 'Line (Linie).';
COMMENT ON COLUMN customer_reports.sap_data_sync.tag                  IS 'Day/date (Tag).';
COMMENT ON COLUMN customer_reports.sap_data_sync.shicht               IS 'Shift (Schicht).';
COMMENT ON COLUMN customer_reports.sap_data_sync.shicht_nummer        IS 'Shift number (Schichtnummer).';
COMMENT ON COLUMN customer_reports.sap_data_sync.auftrag              IS 'Production order (Auftrag); auftrag_key = surrogate key.';
COMMENT ON COLUMN customer_reports.sap_data_sync.sum_labels           IS 'Total labels/units for the order.';
COMMENT ON COLUMN customer_reports.sap_data_sync.rumpfe               IS 'Bodies/blanks produced (Rümpfe — tube/sleeve bodies).';
COMMENT ON COLUMN customer_reports.sap_data_sync.gutmenge             IS 'Good quantity (Gutmenge) — net/OK output.';
COMMENT ON COLUMN customer_reports.sap_data_sync.rustzeit             IS 'Setup/changeover time (Rüstzeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.produktionszeit      IS 'Production (running) time (Produktionszeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.geplante_ausfallzeit   IS 'Planned downtime (geplante Ausfallzeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.ungeplante_ausfallzeit IS 'Unplanned downtime (ungeplante Ausfallzeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.matfehler_ausfallzeit  IS 'Downtime from material defects (Materialfehler-Ausfallzeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.auftrag_startzeit    IS 'Order start time (Auftrag-Startzeit).';
COMMENT ON COLUMN customer_reports.sap_data_sync.running_h            IS 'Running hours.';
COMMENT ON COLUMN customer_reports.sap_data_sync.data_type            IS 'Row type/discriminator within the SAP feed.';

-- ── shift — cust-6 shift report (ADR-0012 Wave 2) ────────────────────────────
COMMENT ON TABLE customer_reports.shift IS 'EXTERNAL CONTRACT — customer_id=6 per-shift report pool (ADR-0012 Wave 2). Written by the cust-6 shift writer (oeecloud-worker/main.go). Hours columns are in HOURS (h suffix).';
COMMENT ON COLUMN customer_reports.shift.turno_hrs        IS 'Shift hours window label (turno = shift, PT/ES).';
COMMENT ON COLUMN customer_reports.shift.shift_duration_h IS 'Shift duration, hours.';
COMMENT ON COLUMN customer_reports.shift.dt_duration_h    IS 'Total downtime, hours (dt_plan_h + dt_unplan_h).';
COMMENT ON COLUMN customer_reports.shift.setup_duration_h IS 'Setup/changeover, hours.';
COMMENT ON COLUMN customer_reports.shift.prss_qty  IS 'Pressed/produced (gross) quantity.';
COMMENT ON COLUMN customer_reports.shift.packed_qty IS 'Packed (net/good) quantity.';
COMMENT ON COLUMN customer_reports.shift.pro_h     IS 'Downtime attributed to PROduction, hours.';
COMMENT ON COLUMN customer_reports.shift.res_h     IS 'Downtime attributed to RESources/material, hours.';
COMMENT ON COLUMN customer_reports.shift.mnt_h     IS 'Downtime attributed to MaiNTenance, hours.';
COMMENT ON COLUMN customer_reports.shift.discart_h IS 'Discard/scrap-related time, hours.';
COMMENT ON COLUMN customer_reports.shift.index1 IS 'External-sync row key (text).';
COMMENT ON COLUMN customer_reports.shift.index2 IS 'External-sync auxiliary payload (jsonb).';
