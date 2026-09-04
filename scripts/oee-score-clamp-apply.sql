-- oee-score-clamp-apply.sql
-- Two-OEE display clamp (ADR §5.3). Bounds every served OEE factor to [0,1] and
-- fixes h_piot_oee_score_fix1a's division-by-zero (bare `/(oee_a*oee_q)` -> NULLIF-guarded).
-- Transformation is derived from the LIVE catalog via replace()/regexp_replace() and
-- applied with \gexec (zero transcription risk). Run against packiot_analytics.
--   docker exec -i timescaledb psql -U postgres -d packiot_analytics -f oee-score-clamp-apply.sql
-- NOTE: clamps the DISPLAY only; the underlying net>ideal (OEE>1) config bug is tracked separately.
-- Idempotent: re-running is a no-op (already-clamped leaves no longer match the raw literals).

-- ===== h_piot_oee_score_full_3 =====
SELECT replace(replace(replace(replace(
  pg_get_functiondef('h_piot_oee_score_full_3'::regproc),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee'),
  'coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a',
  'GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a'),
  'coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q'),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p')
\gexec

-- ===== h_piot_oee_score_with_teams =====
SELECT replace(replace(replace(replace(
  pg_get_functiondef('h_piot_oee_score_with_teams'::regproc),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee'),
  'coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a',
  'GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a'),
  'coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q'),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p')
\gexec

-- ===== h_piot_oee_score_fix1 (0 read-api refs; also has a SEPARATE pre-existing
-- non-executability: oee_timeline array_agg returns float8[] vs declared text[].
-- Clamp applied for correctness; execution needs that unrelated type bug fixed.) =====
SELECT replace(replace(replace(replace(
  pg_get_functiondef('h_piot_oee_score_fix1'::regproc),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee'),
  'coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a',
  'GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a'),
  'coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q'),
  'coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p',
  'GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p')
\gexec

-- ===== h_piot_oee_score_fix1a (fixes the DIVISION-BY-ZERO: bare `/(a*q)` -> `/ nullif((a*q),0)` + clamp;
-- same separate pre-existing oee_timeline type bug as fix1) =====
SELECT regexp_replace(regexp_replace(replace(replace(replace(
  pg_get_functiondef('h_piot_oee_score_fix1a'::regproc),
  'coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee'),
  'coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a',
  'GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a'),
  'coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q'),
  'coalesce\(sum\(net\)::float/nullif\(sum\(ideal_production\),0\),0\)\s*/\s*\(coalesce\(sum\(running_time\)::float/nullif\(sum\(available_time\),0\),0\)\s*\*\s*coalesce\(sum\(net\)::float/nullif\(sum\(gross\),0\),0\)\)\s*as oee_p',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p','g'),
  'coalesce\(sum\(net\)::float/nullif\(sum\(ideal_production\),0\),0\)\s*/\s*nullif\(\(coalesce\(sum\(running_time\)::float/nullif\(sum\(available_time\),0\),0\)\s*\*\s*coalesce\(sum\(net\)::float/nullif\(sum\(gross\),0\),0\)\),\s*0\)\s*as oee_p',
  'GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p','g')
\gexec
