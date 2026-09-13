-- t266 Phase A rollback — recreate the two dropped objects.
CREATE TABLE IF NOT EXISTS ops.function_execution_log (
  ts_value      timestamp with time zone,
  function_name text
);

CREATE OR REPLACE VIEW serving.v_po_box_totals AS
  SELECT box_scans.id_production_order,
     box_scans.id_enterprise,
     count(*) FILTER (WHERE box_scans.scan_type = 'production'::text) AS box_count,
     COALESCE(max(box_scans.label_seq) FILTER (WHERE box_scans.scan_type = 'production'::text), 0::bigint) AS last_label_seq,
     COALESCE(sum(box_scans.qty) FILTER (WHERE box_scans.counts_toward_total), 0::bigint) AS total_qty
    FROM box_scans
   GROUP BY box_scans.id_production_order, box_scans.id_enterprise;
