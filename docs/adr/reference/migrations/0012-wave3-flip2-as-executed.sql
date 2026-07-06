BEGIN;
DROP FUNCTION IF EXISTS get_report_shift_enterprsie_06();
DROP FUNCTION IF EXISTS get_report_shift_enterprsie_06b(date,date);
DROP FUNCTION get_report_shift_enterprsie_06c(date,date);
\i /tmp/06c-new.sql
DROP TABLE public.report_shift_enterprsie_06;
CREATE VIEW public.report_shift_enterprsie_06 AS
  SELECT line, shift, turno_hrs, day, job, shift_duration_h, dt_duration_h,
         setup_duration_h, running, prss_qty, packed_qty, shift_number,
         job_sequence, dt_plan_h, dt_unplan_h, shift_start_time, index1,
         id_equipment, pro_h, res_h, mnt_h, discart_h, index2
    FROM customer_reports.shift WHERE customer_id = 6;
COMMIT;
