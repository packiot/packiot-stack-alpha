-- t-sandbox-attribution-sync — the twin's COUNT ATTRIBUTION must be CPACK's, remapped (2026-10-01).
--
-- WHY (3-way audit legacy = CPACK staging = sandbox): events, POs and line gold matched, but the
-- twin's MACHINE-level counts landed on different machines (L10/DXL 3.21M in CPACK vs 309 in the
-- twin; L5/RMH 0 vs 2.85M …). Two config gaps, neither touched by ops.sandbox_reflect:
--   1. core.topic_routing (core.packml_register): the twin's copy was made once and never
--      refreshed — the 43 per-machine COUNTER topics CPACK gained since (…/Admin/Prod{Consumed,
--      Processed,Defective}Count/<idx>/Unit, counter-roles work) are missing, so the twin's
--      pipeline attributes those counts by its fallback.
--   2. core.equipments.gross_machine / net_machine / scrap_machine are not in the reflect's
--      remap (eq_map has id_parentequipment + lead_machine only): six twin lines (L3 L4 L5 L6 L8
--      L10) pointed net_machine at CPACK's OWN machine ids — a cross-tenant read that made the
--      twin's line net "match" CPACK by reading CPACK's data.
-- WHAT: ops.sandbox_sync_attribution(src, dst, off, src_tag, dst_tag) — remap those 3 columns;
-- sync topic_routing BY TOPIC (src_tag/… → dst_tag/…): update existing twin rows, insert missing
-- ones (new id from the table's sequence), delete twin rows with no source counterpart. Entity
-- ids + off; id_infeedcounter / id_outfeedcounter are PLC COUNT INDEXES (…/Count/565/Unit), not
-- ids — copied as-is; string keys get the tag swapped. Called by the sandbox heal after the
-- reflect. Idempotent; scoped hard to p_dst.
CREATE OR REPLACE FUNCTION ops.sandbox_sync_attribution(p_src integer, p_dst integer, p_off integer,
    p_src_tag text DEFAULT 'CPACK', p_dst_tag text DEFAULT 'SBXCPACK')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE n_eq int; n_up int; n_ins int; n_del int;
BEGIN
  IF p_dst < 1000000 OR p_dst = p_src THEN
    RAISE EXCEPTION 'sandbox_sync_attribution: refusing dst=% (must be a sandbox id >= 1,000,000 and != src)', p_dst;
  END IF;
  -- 1. line meter roles → the twin's own machines
  UPDATE core.equipments s
     SET gross_machine = c.gross_machine + p_off, net_machine = c.net_machine + p_off, scrap_machine = c.scrap_machine + p_off
    FROM core.equipments c
   WHERE c.id_enterprise = p_src AND s.id_enterprise = p_dst AND s.id_equipment = c.id_equipment + p_off
     AND (s.gross_machine, s.net_machine, s.scrap_machine) IS DISTINCT FROM
         (c.gross_machine + p_off, c.net_machine + p_off, c.scrap_machine + p_off);
  GET DIAGNOSTICS n_eq = ROW_COUNT;

  -- 2. topic routing, by topic
  CREATE TEMP TABLE IF NOT EXISTS sbx_tr ON COMMIT DROP AS SELECT * FROM core.topic_routing WHERE false;
  TRUNCATE sbx_tr;
  INSERT INTO sbx_tr (id_topic_route, packml_topic, "timestamp", value, signal_quality, ts_quality, mqtt_topic, sparkplug_json,
                      id_equipment, id_site, id_area, id_enterprise, id_infeedcounter, id_outfeedcounter, active, attributed,
                      id_unit, line_unit_seq, device_nm, device_key)
  SELECT c.id_topic_route, p_dst_tag || substr(c.packml_topic, length(p_src_tag) + 1), NULL, NULL, NULL, NULL,
         replace(c.mqtt_topic, p_src_tag, p_dst_tag), NULL,
         c.id_equipment + p_off, c.id_site + p_off, c.id_area + p_off, p_dst,
         c.id_infeedcounter, c.id_outfeedcounter, c.active, c.attributed, c.id_unit + p_off, c.line_unit_seq,
         c.device_nm, replace(c.device_key, p_src_tag, p_dst_tag)
    FROM core.topic_routing c
   WHERE c.id_enterprise = p_src AND c.packml_topic LIKE p_src_tag || '/%';

  UPDATE core.topic_routing s
     SET id_equipment = t.id_equipment, id_site = t.id_site, id_area = t.id_area, id_infeedcounter = t.id_infeedcounter,
         id_outfeedcounter = t.id_outfeedcounter, active = t.active, attributed = t.attributed, id_unit = t.id_unit,
         line_unit_seq = t.line_unit_seq, device_nm = t.device_nm, device_key = t.device_key
    FROM sbx_tr t
   WHERE s.id_enterprise = p_dst AND s.packml_topic = t.packml_topic
     AND (s.id_equipment, s.id_site, s.id_area, s.id_infeedcounter, s.id_outfeedcounter, s.active, s.attributed, s.id_unit, s.line_unit_seq, s.device_nm, s.device_key)
         IS DISTINCT FROM
         (t.id_equipment, t.id_site, t.id_area, t.id_infeedcounter, t.id_outfeedcounter, t.active, t.attributed, t.id_unit, t.line_unit_seq, t.device_nm, t.device_key);
  GET DIAGNOSTICS n_up = ROW_COUNT;

  INSERT INTO core.topic_routing (packml_topic, mqtt_topic, id_equipment, id_site, id_area, id_enterprise, id_infeedcounter,
                                  id_outfeedcounter, active, attributed, id_unit, line_unit_seq, device_nm, device_key)
  SELECT t.packml_topic, t.mqtt_topic, t.id_equipment, t.id_site, t.id_area, t.id_enterprise, t.id_infeedcounter,
         t.id_outfeedcounter, t.active, t.attributed, t.id_unit, t.line_unit_seq, t.device_nm, t.device_key
    FROM sbx_tr t
   WHERE NOT EXISTS (SELECT 1 FROM core.topic_routing s WHERE s.id_enterprise = p_dst AND s.packml_topic = t.packml_topic);
  GET DIAGNOSTICS n_ins = ROW_COUNT;

  DELETE FROM core.topic_routing s
   WHERE s.id_enterprise = p_dst AND s.packml_topic LIKE p_dst_tag || '/%'
     AND NOT EXISTS (SELECT 1 FROM sbx_tr t WHERE t.packml_topic = s.packml_topic);
  GET DIAGNOSTICS n_del = ROW_COUNT;

  RETURN format('attribution: line meter roles remapped %s; topic routes updated %s, inserted %s, deleted %s', n_eq, n_up, n_ins, n_del);
END $$;
COMMENT ON FUNCTION ops.sandbox_sync_attribution(integer, integer, integer, text, text) IS
  'Make the twin''s count attribution CPACK''s: remap equipments.gross/net/scrap_machine and sync core.topic_routing by topic. Called by the sandbox heal after ops.sandbox_reflect. See db/migrations/t-sandbox-attribution-sync.';
