-- t-ent5-downtime-reason-catalog — seed ent5's downtime reason catalog (was empty).
--
-- ent5 (Bispharma) had 0 rows in core.downtime_reason, so operators had no reasons to
-- justify stops with and the Downtimes reason-Pareto could never populate (every stop
-- reads "unjustified"). This is legit onboarding config, not demo data — clone the
-- standard, proven catalog from CPACK (ent3): 18 active reasons across equipment failures,
-- planned downtime, process issues, and QA/material waits (pharma-appropriate). parent_id
-- is left NULL; grouping is via the `category` text column (EQUIP_FAIL / PLANNED / etc.).
-- id is a GENERATED ALWAYS identity, so it is omitted and auto-assigned.
-- Idempotent on (id_enterprise, code).
INSERT INTO core.downtime_reason
    (id_enterprise, code, label, label_i18n, category, parent_id,
     reason_level, planned_downtime, change_over, idle, active)
SELECT 5, r.code, r.label, r.label_i18n, r.category, NULL,
       r.reason_level, r.planned_downtime, r.change_over, r.idle, true
  FROM core.downtime_reason r
 WHERE r.id_enterprise = 3 AND r.active
   AND NOT EXISTS (SELECT 1 FROM core.downtime_reason d
                    WHERE d.id_enterprise = 5 AND d.code = r.code);
