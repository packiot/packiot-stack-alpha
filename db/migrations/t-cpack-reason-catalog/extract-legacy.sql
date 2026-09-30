-- t-cpack-reason-catalog / extract-legacy.sql — READ-ONLY extract of the real CPACK
-- downtime-reason catalog from LEGACY production (packiot40, legacy id_enterprise=1).
--
-- Run it READ ONLY against legacy (e.g. scripts/ssm-psql.sh-style runner that wraps
-- BEGIN READ ONLY), with `psql -At`; the output is one JSON document per line, which
-- scripts/gen-cpack-reason-catalog.py turns into 01-up.sql.
--
--   legacy_id   legacy id_equipment (provenance only — NOT used as a key downstream)
--   topic       the equipment's BASE packml topic (no /Admin|/Status suffix), already
--               rewritten C-PACK -> CPACK: this is the join key to the analytics
--               core.packml_register (same rule as scripts/analytics-legacy-history-backfill.sh)
--   reasons     equipments.downtime_reasons verbatim (jsonb; NULL for most members)
SELECT jsonb_build_object(
         'legacy_id', e.id_equipment,
         'nm',        e.nm_equipment,
         'tp',        e.tp_equipment,
         'parent',    e.id_parentequipment,
         'topic',     replace(p.packml_topic, 'C-PACK', 'CPACK'),
         'reasons',   e.downtime_reasons)::text
  FROM equipments e
  JOIN packml_register p
    ON p.id_equipment = e.id_equipment AND p.active
   AND p.packml_topic !~ '/(Admin|Status)/'
 WHERE e.id_enterprise = 1
 ORDER BY e.id_equipment
