-- analytics-rename UP — runtime rollup tables -> oee rollup tables (meaningful names)
-- Expand phase: ALTER RENAME + security_invoker compat view at old name.
-- Proven safe 2026-09-04: code writers UPDATE-only, procs use column/bare ON CONFLICT
-- (traverses auto-updatable view), 2 RLS-forced tables preserved via security_invoker.
-- Reversible via down.sql. RAW (equipment_values/_events) + agg_* caggs untouched.
BEGIN;
ALTER TABLE public.equipment_runtime_shift RENAME TO equipment_oee_shift;
CREATE VIEW public.equipment_runtime_shift WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_shift;
COMMENT ON VIEW public.equipment_runtime_shift IS 'compat shim — renamed to equipment_oee_shift on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_1hour RENAME TO equipment_oee_hourly;
CREATE VIEW public.equipment_runtime_1hour WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_hourly;
COMMENT ON VIEW public.equipment_runtime_1hour IS 'compat shim — renamed to equipment_oee_hourly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_1day RENAME TO equipment_oee_daily;
CREATE VIEW public.equipment_runtime_1day WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_daily;
COMMENT ON VIEW public.equipment_runtime_1day IS 'compat shim — renamed to equipment_oee_daily on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_1week RENAME TO equipment_oee_weekly;
CREATE VIEW public.equipment_runtime_1week WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_weekly;
COMMENT ON VIEW public.equipment_runtime_1week IS 'compat shim — renamed to equipment_oee_weekly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_1month RENAME TO equipment_oee_monthly;
CREATE VIEW public.equipment_runtime_1month WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_monthly;
COMMENT ON VIEW public.equipment_runtime_1month IS 'compat shim — renamed to equipment_oee_monthly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_shift_1week RENAME TO equipment_oee_shift_weekly;
CREATE VIEW public.equipment_runtime_shift_1week WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_shift_weekly;
COMMENT ON VIEW public.equipment_runtime_shift_1week IS 'compat shim — renamed to equipment_oee_shift_weekly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.equipment_runtime_shift_1month RENAME TO equipment_oee_shift_monthly;
CREATE VIEW public.equipment_runtime_shift_1month WITH (security_invoker=true) AS SELECT * FROM public.equipment_oee_shift_monthly;
COMMENT ON VIEW public.equipment_runtime_shift_1month IS 'compat shim — renamed to equipment_oee_shift_monthly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.area_runtime_shift RENAME TO area_oee_shift;
CREATE VIEW public.area_runtime_shift WITH (security_invoker=true) AS SELECT * FROM public.area_oee_shift;
COMMENT ON VIEW public.area_runtime_shift IS 'compat shim — renamed to area_oee_shift on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.area_runtime_1hour RENAME TO area_oee_hourly;
CREATE VIEW public.area_runtime_1hour WITH (security_invoker=true) AS SELECT * FROM public.area_oee_hourly;
COMMENT ON VIEW public.area_runtime_1hour IS 'compat shim — renamed to area_oee_hourly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.area_runtime_1day RENAME TO area_oee_daily;
CREATE VIEW public.area_runtime_1day WITH (security_invoker=true) AS SELECT * FROM public.area_oee_daily;
COMMENT ON VIEW public.area_runtime_1day IS 'compat shim — renamed to area_oee_daily on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.area_runtime_1week RENAME TO area_oee_weekly;
CREATE VIEW public.area_runtime_1week WITH (security_invoker=true) AS SELECT * FROM public.area_oee_weekly;
COMMENT ON VIEW public.area_runtime_1week IS 'compat shim — renamed to area_oee_weekly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.area_runtime_1month RENAME TO area_oee_monthly;
CREATE VIEW public.area_runtime_1month WITH (security_invoker=true) AS SELECT * FROM public.area_oee_monthly;
COMMENT ON VIEW public.area_runtime_1month IS 'compat shim — renamed to area_oee_monthly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.site_runtime_shift RENAME TO site_oee_shift;
CREATE VIEW public.site_runtime_shift WITH (security_invoker=true) AS SELECT * FROM public.site_oee_shift;
COMMENT ON VIEW public.site_runtime_shift IS 'compat shim — renamed to site_oee_shift on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.site_runtime_1hour RENAME TO site_oee_hourly;
CREATE VIEW public.site_runtime_1hour WITH (security_invoker=true) AS SELECT * FROM public.site_oee_hourly;
COMMENT ON VIEW public.site_runtime_1hour IS 'compat shim — renamed to site_oee_hourly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.site_runtime_1day RENAME TO site_oee_daily;
CREATE VIEW public.site_runtime_1day WITH (security_invoker=true) AS SELECT * FROM public.site_oee_daily;
COMMENT ON VIEW public.site_runtime_1day IS 'compat shim — renamed to site_oee_daily on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.site_runtime_1week RENAME TO site_oee_weekly;
CREATE VIEW public.site_runtime_1week WITH (security_invoker=true) AS SELECT * FROM public.site_oee_weekly;
COMMENT ON VIEW public.site_runtime_1week IS 'compat shim — renamed to site_oee_weekly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
ALTER TABLE public.site_runtime_1month RENAME TO site_oee_monthly;
CREATE VIEW public.site_runtime_1month WITH (security_invoker=true) AS SELECT * FROM public.site_oee_monthly;
COMMENT ON VIEW public.site_runtime_1month IS 'compat shim — renamed to site_oee_monthly on 2026-09-04 (analytics meaningful-names cutover); drop in contract phase once consumers repointed';
COMMIT;
