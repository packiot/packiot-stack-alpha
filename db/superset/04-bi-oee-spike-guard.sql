-- db/superset/04-bi-oee-spike-guard.sql
-- W2 embedded-Superset — data-quality guard on the curated OEE views.
-- Apply by hand, staging-first (idempotent CREATE OR REPLACE). Companion to
-- 01-superset-ro-role.sql (which defines the bi.* surface) and 02-tenant-rls.sql.
--
-- ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
-- gold.equipment_oee_shift carries a handful of TOTALIZER-SPIKE rows for CPACK
-- (id_enterprise = 3): a PLC counter reset / first-boot delta produced non-physical
-- gross/net values (observed magnitudes 1e15 – 1e23, both signs) on machines FLEXO
-- (id_equipment 103), SLEEVE1/2, L5/L10, dated 2026-06-29 .. 2026-07-04. This is the
-- same first-boot totalizer-spike class fixed FORWARD in edge-transformer/oeecloud-worker
-- (commit b60804c, ADR-0045 P1); those historical gold rows predate the fix and remain.
--
-- gross/net are `real` (float4). Superset's KPI metrics SUM(gross)/SUM(net)/
-- SUM(gross-net) therefore accumulate in float4 and OVERFLOW ("value out of range:
-- overflow", psycopg2.errors.NumericValueOutOfRange) the moment a spike row is in
-- scope — hard-erroring the "Total gross/net production", "Production by machine",
-- and scrap charts. The all-tenant super-admin view (app.tenant_id = -1) and CPACK's
-- own tenant view both hit it (the spikes are CPACK rows). SANDBOX-CPACK (2000003)
-- and Bispharma (5) are clean.
--
-- ── THE GUARD ────────────────────────────────────────────────────────────────
-- NULL out gross/net when |value| exceeds a physically-implausible ceiling so the
-- SUM/AVG metrics skip the garbage instead of erroring — the OEE ratio columns
-- (oee/oee_a/oee_p/oee_q, already clamped to [0,1] upstream) are LEFT INTACT so the
-- shift row still contributes its availability/performance/quality to the OEE charts;
-- only its poisoned production COUNTS drop out of the production/scrap totals.
--
-- CEILING = 1e8 units per equipment-shift. Justification (not a magic number):
--   * the hourly grain (gold.equipment_oee_hourly) is spike-free and caps at
--     2,624,221 units/hour across ALL tenants; a shift <= ~24h therefore tops out
--     near ~6.3e7 in the worst plausible case;
--   * the clean tenants' shift grain caps at 5,113,082 (SANDBOX) and 32,034
--     (Bispharma);
--   * 1e8 sits ~20x above the largest legitimate observed shift value and >=10^7x
--     below the smallest true spike — a wide, safe separation gap.
-- The guard is applied to BOTH oee_shift and oee_hourly (hourly is spike-free today;
-- the guard is defensive + keeps the two grains consistent should a future first-boot
-- spike land on the hourly rollup before the forward-fix catches it).
--
-- CASE returns `real` (NULL::real / rs.gross::real), so the view column TYPE is
-- unchanged → CREATE OR REPLACE VIEW is legal and ownership (bi_owner) + grants
-- (superset_ro) are preserved. Tables are schema-qualified (medallion: gold.*, core.*)
-- so this applies correctly regardless of the applying role's search_path.
--
-- REVERSIBLE: re-running 01-superset-ro-role.sql's view bodies (without the CASE)
-- restores the raw pass-through.

CREATE OR REPLACE VIEW bi.oee_shift AS
SELECT
    eq.id_enterprise,
    rs.id_equipment,
    eq.nm_equipment,
    rs.id_shift,
    rs.cd_shift,
    rs.ts_value,
    rs.ts_end,
    rs.oee,
    rs.oee_a,
    rs.oee_p,
    rs.oee_q,
    CASE WHEN abs(rs.gross::double precision) > 1e8 THEN NULL ELSE rs.gross END AS gross,
    CASE WHEN abs(rs.net::double precision)   > 1e8 THEN NULL ELSE rs.net   END AS net,
    rs.running_time,
    eq.nm_equipment::text ||
        CASE eq.tp_equipment
            WHEN 3 THEN ' (line)'::text
            WHEN 1 THEN ' (machine)'::text
            WHEN 2 THEN ' (sector)'::text
            ELSE ''::text
        END AS equipment_label
FROM gold.equipment_oee_shift rs
JOIN core.equipments eq ON eq.id_equipment = rs.id_equipment
WHERE rs.ts_value <= now() AND rs.running_time > 0;

CREATE OR REPLACE VIEW bi.oee_hourly AS
SELECT
    eq.id_enterprise,
    rh.id_equipment,
    eq.nm_equipment,
    rh.ts_value,
    rh.oee,
    rh.oee_a,
    rh.oee_p,
    rh.oee_q,
    CASE WHEN abs(rh.gross::double precision) > 1e8 THEN NULL ELSE rh.gross END AS gross,
    CASE WHEN abs(rh.net::double precision)   > 1e8 THEN NULL ELSE rh.net   END AS net,
    rh.running_time,
    eq.nm_equipment::text ||
        CASE eq.tp_equipment
            WHEN 3 THEN ' (line)'::text
            WHEN 1 THEN ' (machine)'::text
            WHEN 2 THEN ' (sector)'::text
            ELSE ''::text
        END AS equipment_label
FROM gold.equipment_oee_hourly rh
JOIN core.equipments eq ON eq.id_equipment = rh.id_equipment
WHERE rh.ts_value <= now() AND rh.running_time > 0;
