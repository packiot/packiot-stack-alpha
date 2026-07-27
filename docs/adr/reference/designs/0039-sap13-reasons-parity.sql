-- 0039-sap13-reasons-parity.sql — Step-1 verify gate for ADR-0039 R5 CONTRACT (task #12).
--
-- PURPOSE: prove the dimension-sourced downtime-reason vocabulary (downtime_reason +
-- equipment_downtime_reason) is row-for-row identical to the jsonb-sourced vocabulary the
-- `sap13` report reads today (equipments.downtime_reasons), for the NEOPAC (ent 13) line
-- equipment set, BEFORE flipping SAP13_REASONS_FROM_DIM=true.
--
-- Run SELECT-ONLY on staging packiot_shadow (BEGIN READ ONLY). Both sides must be empty.
--
-- CONTRACT under test: the `downtime_codes(position, description)` CTE that
-- sap13_reasons_{jsonb,dim}.sql each build. `position` = category code::int;
-- `description` = en-US category label. Downstream, stops_neopac_ch joins
-- `ee.cd_category::text = dc.description`, so the DESCRIPTION strings must match exactly —
-- a label mismatch silently drops every stop into the no-reason/microstop buckets.
--
-- DEFINITIVE LIVE FINDING (packiot_shadow, 2026-07-26): the report reads the label from
-- the jsonb `->'name'->>'en-US'` key, but on live data the `name` key is NEVER present
-- (categories name=0/description=1400; subcategories 0/3640). So the jsonb side's
-- `description` is NULL for every row, while the dim side (R5 backfill reads `->'description'`)
-- has real labels. The EXCEPT sets below will therefore be NON-EMPTY: this is NOT a dim
-- regression — it exposes a pre-existing reports bug (jsonb path yields all-NULL descriptions,
-- so the downstream `ee.cd_category::text = dc.description` join never matches). Enabling
-- SAP13_REASONS_FROM_DIM is a BEHAVIORAL FIX requiring the report owner's sign-off, not a
-- byte-parity swap. Use this query to quantify exactly which categories start matching.

BEGIN READ ONLY;

-- jsonb-derived vocabulary (mirrors sap13_reasons_jsonb.sql: downtime_codes)
WITH jsonb_codes AS (
  SELECT DISTINCT
         (cat ->> 'code')::int                       AS position,
         (cat -> 'name') ->> 'en-US'                  AS description
  FROM equipments e,
       jsonb_array_elements(e.downtime_reasons) elem,
       jsonb_array_elements(elem -> 'categories') cat
  WHERE e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
    AND jsonb_typeof(e.downtime_reasons) = 'array'
    AND cat ->> 'code' IS NOT NULL
),
-- dimension-derived vocabulary (mirrors sap13_reasons_dim.sql: downtime_codes)
dim_codes AS (
  SELECT DISTINCT
         r.code::int                                  AS position,
         COALESCE(r.label, r.label_i18n ->> 'en-US')  AS description
  FROM equipment_downtime_reason j
  JOIN downtime_reason r ON r.id = j.id_reason
  JOIN equipments      e ON e.id_equipment = j.id_equipment
  WHERE e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
    AND j.active AND r.active AND r.reason_level = 1
)
-- BOTH result sets below MUST be empty for parity.
SELECT 'in_jsonb_not_in_dim' AS side, position, description FROM (
  SELECT position, description FROM jsonb_codes
  EXCEPT
  SELECT position, description FROM dim_codes
) a
UNION ALL
SELECT 'in_dim_not_in_jsonb' AS side, position, description FROM (
  SELECT position, description FROM dim_codes
  EXCEPT
  SELECT position, description FROM jsonb_codes
) b
ORDER BY 1, 2;

-- Cardinality cross-check (expect jsonb_n = dim_n):
--   SELECT (SELECT count(*) FROM jsonb_codes) AS jsonb_n,
--          (SELECT count(*) FROM dim_codes)   AS dim_n;

ROLLBACK;
