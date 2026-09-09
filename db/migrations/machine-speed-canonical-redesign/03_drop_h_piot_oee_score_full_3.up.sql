-- Task #221 (bundled cleanup) — drop legacy public.h_piot_oee_score_full_3.
-- Freed by #218 (PR #1135, merged to staging): the read-api `oee-score-full`
-- dataset is REPOINTED to serving.oee_score($1,$2,$3); front4 TotalProductionUNS
-- consumes the dataset by NAME (unchanged), so it no longer reaches this function.
-- Gated on ZERO consumers:
--   * deployed runner-checkout datasets.go: oee-score-full -> serving.oee_score
--     (only residual `h_piot_oee_score_full_3` occurrence is a code comment).
--   * DB scan: 0 views/matviews reference it; pg_depend depcount = 0.
-- No CASCADE. Reversible via 03_drop_h_piot_oee_score_full_3.down.sql.
DROP FUNCTION IF EXISTS public.h_piot_oee_score_full_3(integer,text,text,text,text,timestamptz,timestamptz,text,text,boolean);
