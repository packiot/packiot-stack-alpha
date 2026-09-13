-- t273 — drop the dead SITE-DAY chain: gold.site_oee_daily + silver.site_live_day.
--
-- Necessity audit: site_live_day has ZERO readers (serving.home reads area_live_day, NOT
-- site; nothing else touches it). Its only source, gold.site_oee_daily, was in turn read
-- ONLY by current_rest.go → site_live_day (a dead-ended chain). The site SHIFT grains
-- (gold.site_oee_shift + serving.oee_progress) are LIVE and untouched — site DAY is
-- independent of them (shift rolls up area_oee_shift, not site_oee_daily).
--
-- Writers removed in #263 (feat/263-site-day-split): entity_grains.go SkipDay for site
-- (day rollup + day-flag cascade), provision.go piot_create_site_oee_daily, and
-- current_rest.go's site live-day leg. ⚠ APPLY ONLY AFTER that stream-engine change
-- deploys + soaks (both tables' writers confirmed stopped) — #186 discipline.
DROP TABLE IF EXISTS silver.site_live_day;
DROP TABLE IF EXISTS gold.site_oee_daily;
