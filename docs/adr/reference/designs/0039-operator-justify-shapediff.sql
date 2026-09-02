-- 0039-operator-justify-shapediff.sql
-- ADR-0039 R5 CONTRACT · task #12 · Step 3 (operator justify-flow reasons re-nest).
--
-- PURPOSE
--   Prove the re-nest is byte-identical for every field the edge-node-red justify
--   subflow reads. It rebuilds `_downtime_reasons[packmlTopic]` SERVER-SIDE from the
--   R5 dimension (downtime_reason) + junction (equipment_downtime_reason) for the
--   VOCABULARY factor, plus the top-level machine-code list from the legacy jsonb for
--   the ATTRIBUTION factor (the thin-skeleton this pass — see the design doc §5.2/§7),
--   and asserts deep-equality against the jsonb-derived shape the loader produces today.
--
-- CONTRACT ASSERTED (the exact fields node 63b722c0c1851e52 "Build Justify Event
-- Request" reads; see design doc §2):
--   top-level : .code
--   category  : .code, .description (full i18n map), .planned_downtime, .change_over,
--               .idle, and the SET of child subcategory codes
--   subcat    : .code, .description, .planned_downtime, .change_over, .idle
--   ( .name is intentionally NOT emitted — absent in source; the consumer's `|| code`
--     fallback makes emitting it a pure byte-diff. We ASSERT the jsonb side also lacks
--     `name`, so parity holds. )
--
-- SEMANTICS
--   * Order-independent: the subflow uses .find(), never index access. We compare
--     categories/subcategories as SETS keyed by code, and compare the scalar/label
--     fields per code. Array order is NOT asserted.
--   * SELECT-only. Wrap in `BEGIN READ ONLY; ... COMMIT;` when running on packiot_shadow.
--   * CLEAN RESULT = zero rows from every SELECT below. Any returned row is a mismatch
--     (the columns explain which packml_topic / code / field diverged).
--
-- SCOPE NOTE
--   Runs against packiot_shadow (staging), where downtime_reason / equipment_downtime_reason
--   exist (R5 is prod-gated). The attribution (top-level machine-code) factor is NOT
--   checked here beyond presence, because it is sourced from jsonb this pass by design;
--   its parity is trivially the identity. Assertion A4 documents that.

-- ════════════════════════════════════════════════════════════════════════════
-- Common CTEs: the two shapes, decomposed to comparable relations.
-- ════════════════════════════════════════════════════════════════════════════

-- ---- LEGACY (jsonb) side ----------------------------------------------------
-- jsonb categories per (topic): code + description(i18n) + flags
WITH eq_topic AS (
  SELECT e.id_equipment, e.id_enterprise, p.packml_topic AS topic, e.downtime_reasons
  FROM equipments e
  JOIN packml_register p ON p.id_equipment = e.id_equipment AND p.active
  WHERE jsonb_typeof(e.downtime_reasons) = 'array'
),
json_cat AS (
  SELECT DISTINCT
    t.topic,
    cat->>'code'                              AS cat_code,
    cat->'description'                        AS cat_desc,      -- full i18n map
    COALESCE((cat->>'planned_downtime')::bool,false) AS planned,
    COALESCE((cat->>'change_over')::bool,false)      AS change_over,
    COALESCE((cat->>'idle')::bool,false)             AS idle,
    (cat ? 'name')                            AS has_name
  FROM eq_topic t,
       jsonb_array_elements(t.downtime_reasons) elem,
       jsonb_array_elements(elem->'categories') cat
  WHERE cat->>'code' IS NOT NULL
),
json_sub AS (
  SELECT DISTINCT
    t.topic,
    cat->>'code'                              AS cat_code,
    sub->>'code'                              AS sub_code,
    sub->'description'                        AS sub_desc,
    COALESCE((sub->>'planned_downtime')::bool,false) AS planned,
    COALESCE((sub->>'change_over')::bool,false)      AS change_over,
    COALESCE((sub->>'idle')::bool,false)             AS idle,
    (sub ? 'name')                            AS has_name
  FROM eq_topic t,
       jsonb_array_elements(t.downtime_reasons) elem,
       jsonb_array_elements(elem->'categories') cat,
       jsonb_array_elements(cat->'subcategories') sub
  WHERE sub->>'code' IS NOT NULL
),

-- ---- DIMENSION (re-nest) side ----------------------------------------------
dim_cat AS (
  SELECT DISTINCT
    t.topic,
    r.code                                    AS cat_code,
    r.label_i18n                              AS cat_desc,
    r.planned_downtime                        AS planned,
    r.change_over                             AS change_over,
    r.idle                                    AS idle
  FROM eq_topic t
  JOIN equipment_downtime_reason j ON j.id_equipment = t.id_equipment AND j.active
  JOIN downtime_reason r ON r.id = j.id_reason AND r.active AND r.reason_level = 1
),
dim_sub AS (
  SELECT DISTINCT
    t.topic,
    r.category                                AS cat_code,      -- parent category code
    r.code                                    AS sub_code,
    r.label_i18n                              AS sub_desc,
    r.planned_downtime                        AS planned,
    r.change_over                             AS change_over,
    r.idle                                    AS idle
  FROM eq_topic t
  JOIN equipment_downtime_reason j ON j.id_equipment = t.id_equipment AND j.active
  JOIN downtime_reason r ON r.id = j.id_reason AND r.active AND r.reason_level = 2
)

-- ════════════════════════════════════════════════════════════════════════════
-- ASSERTION A1 — CATEGORY set + fields parity (per topic, per category code).
--   Full outer join on (topic, cat_code); any row where a side is missing, or any
--   field differs, is a mismatch. `description` compared as jsonb equality.
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'A1_category_mismatch' AS assertion,
       COALESCE(j.topic, d.topic)       AS topic,
       COALESCE(j.cat_code, d.cat_code) AS cat_code,
       (j.cat_code IS NULL)             AS missing_in_dimjson_side_legacy,
       (d.cat_code IS NULL)             AS missing_in_dimension,
       j.cat_desc IS DISTINCT FROM d.cat_desc AS desc_diff,
       j.planned  IS DISTINCT FROM d.planned  AS planned_diff,
       j.change_over IS DISTINCT FROM d.change_over AS change_over_diff,
       j.idle     IS DISTINCT FROM d.idle     AS idle_diff
FROM json_cat j
FULL OUTER JOIN dim_cat d USING (topic, cat_code)
WHERE j.cat_code IS NULL
   OR d.cat_code IS NULL
   OR j.cat_desc IS DISTINCT FROM d.cat_desc
   OR j.planned  IS DISTINCT FROM d.planned
   OR j.change_over IS DISTINCT FROM d.change_over
   OR j.idle     IS DISTINCT FROM d.idle;

-- ════════════════════════════════════════════════════════════════════════════
-- ASSERTION A2 — SUBCATEGORY set + fields parity (per topic, per parent cat, per sub).
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'A2_subcategory_mismatch' AS assertion,
       COALESCE(j.topic, d.topic)       AS topic,
       COALESCE(j.cat_code, d.cat_code) AS cat_code,
       COALESCE(j.sub_code, d.sub_code) AS sub_code,
       (j.sub_code IS NULL)             AS missing_in_legacy,
       (d.sub_code IS NULL)             AS missing_in_dimension,
       j.sub_desc IS DISTINCT FROM d.sub_desc AS desc_diff,
       j.planned  IS DISTINCT FROM d.planned  AS planned_diff,
       j.change_over IS DISTINCT FROM d.change_over AS change_over_diff,
       j.idle     IS DISTINCT FROM d.idle     AS idle_diff
FROM json_sub j
FULL OUTER JOIN dim_sub d USING (topic, cat_code, sub_code)
WHERE j.sub_code IS NULL
   OR d.sub_code IS NULL
   OR j.sub_desc IS DISTINCT FROM d.sub_desc
   OR j.planned  IS DISTINCT FROM d.planned
   OR j.change_over IS DISTINCT FROM d.change_over
   OR j.idle     IS DISTINCT FROM d.idle;

-- ════════════════════════════════════════════════════════════════════════════
-- ASSERTION A3 — the `name` key must be ABSENT on the legacy side (design doc §4).
--   If any category/subcategory carries a `name` key, the re-nest (which emits only
--   `description`) would NOT be byte-identical and this test's premise is violated.
--   Expect zero rows.
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'A3_unexpected_name_key' AS assertion, topic, cat_code, NULL::text AS sub_code
FROM json_cat WHERE has_name
UNION ALL
SELECT 'A3_unexpected_name_key', topic, cat_code, sub_code
FROM json_sub WHERE has_name;

-- ════════════════════════════════════════════════════════════════════════════
-- ASSERTION A4 — ATTRIBUTION (top-level machine-code) presence.
--   This pass sources machine codes from jsonb (identity), so parity is trivial. We
--   still assert every top-level machine code resolves to a real nm_equipment (the
--   re-nest / future R5b junction depends on that), and surface the per-topic machine
--   count so the bake harness can spot any equipment whose skeleton went empty.
--   Expect zero rows for the mismatch clause.
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'A4_toplevel_code_not_a_machine' AS assertion,
       t.topic,
       elem->>'code' AS machine_code
FROM eq_topic t,
     jsonb_array_elements(t.downtime_reasons) elem
LEFT JOIN LATERAL (
  SELECT 1 FROM equipments m
  WHERE m.id_enterprise = t.id_enterprise AND m.nm_equipment = elem->>'code'
) match ON true
WHERE elem->>'code' IS NOT NULL AND match IS NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- ASSERTION A5 — TOPIC coverage: every topic that has a jsonb reasons array must also
--   resolve to at least one dimension row via the junction (else the re-nest global
--   would be empty for that topic). Expect zero rows.
-- ════════════════════════════════════════════════════════════════════════════
SELECT 'A5_topic_missing_from_dimension' AS assertion, t.topic
FROM eq_topic t
WHERE jsonb_array_length(t.downtime_reasons) > 0
  AND NOT EXISTS (
    SELECT 1 FROM equipment_downtime_reason j
    JOIN downtime_reason r ON r.id = j.id_reason AND r.active
    WHERE j.id_equipment = t.id_equipment AND j.active
  );
