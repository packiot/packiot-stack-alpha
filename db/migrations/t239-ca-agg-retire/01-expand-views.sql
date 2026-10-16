-- t239 EXPAND — retire the duplicate ca_agg_equipment_values_* cagg chain, back the
-- OEE rollup with the medallion silver.equipment_categorical_* chain instead.
--
-- WHY: ca_agg_equipment_values_{1min,1hour} and silver.equipment_categorical_{1min,1hour}
-- are TWO parallel categorical caggs over the SAME raw silver.equipment_values. Proven
-- value-identical for correctly-materialized data (task #239: gross/net/scrap + speed
-- row-parity 1.0000; force-refresh of a divergent historical ca_agg bucket collapsed it
-- exactly onto silver — the "bug-276 2.7× divergence" was ca_agg STALE materialization,
-- not a silver defect). Keeping both = duplicate compute + a stale-prone second chain.
--
-- MECHANISM (medallion-shim, mirrors public.equipment_values→silver etc.): the rollup
-- SQL now reads `equipment_categorical_{1min,1hour}` via EvSchema=public; these thin
-- public views forward to silver, deriving the scalar `speed` ca_agg exposed
-- (silver keeps sum_speed/cnt_speed). Increment 2 (full de-shim) points the rollup at
-- silver directly and drops these public views along with the other medallion shims.
CREATE VIEW public.equipment_categorical_1min AS
  SELECT s.*, (s.sum_speed / NULLIF(s.cnt_speed, 0))::double precision AS speed
    FROM silver.equipment_categorical_1min s;
CREATE VIEW public.equipment_categorical_1hour AS
  SELECT s.*, (s.sum_speed / NULLIF(s.cnt_speed, 0))::double precision AS speed
    FROM silver.equipment_categorical_1hour s;
COMMENT ON VIEW public.equipment_categorical_1min IS 't239: medallion shim → silver.equipment_categorical_1min (adds derived speed=sum_speed/cnt_speed). Retires ca_agg_equipment_values_1min. Dropped at the full de-shim (increment 2).';
COMMENT ON VIEW public.equipment_categorical_1hour IS 't239: medallion shim → silver.equipment_categorical_1hour (adds derived speed). Retires ca_agg_equipment_values_1hour. Dropped at the full de-shim (increment 2).';
