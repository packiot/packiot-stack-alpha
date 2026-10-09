-- t-backfill-production-targets-default
--
-- Onboarding-gap fix (same class as t-backfill-equipment-config-defaults and the
-- threshold/cd_equipment backfills).
--
-- THE GAP. config.production_targets rows are seeded at onboarding, but the ONLY
-- API to set a target — POST /api/production-targets → h_piot_set_production_target
-- (proportional=false) — is a plain UPDATE that assumes the row already exists. An
-- equipment created WITHOUT a pre-seeded row (bulk-imported lines like Bispharma
-- ent-5, which never went through the seeding path) can therefore NEVER get a
-- target: set-default silently updates 0 rows, so the client's target columns
-- (csadmin Targets menu + the dashboard proportional_target) stay empty. Measured:
-- ent-5 had 0 target rows for all 23 lines; CPACK (onboarded properly) has its 20.
--
-- THE DEFAULT VALUE. World-class OEE = 85% (Availability 90% x Performance 95% x
-- Quality 99.9%) — the Nakajima/TPM benchmark and the most widely cited target in
-- manufacturing (typical plants run 40-60%). A sensible non-empty default is thus
-- "produce at world-class OEE against nameplate speed":
--     vl_hour  = round(ideal_speed * 0.85)   ideal_speed = the line's lead_machine
--                                             production_speed (units/hr)
--     vl_shift = vl_hour * 8   (one 8h shift)
--     vl_day   = vl_hour * 24 ; vl_week = vl_day * 7 ; vl_month = vl_day * 30
-- A CS engineer can still override any line in csadmin — the row now EXISTS, so the
-- set-default UPDATE takes effect.
--
-- SCOPE. tp=3 LINES only (the OEE-reporting unit; matches CPACK's line-only
-- targets). Missing-row-only, lead-speed>0, id_site NOT NULL — never overwrites an
-- existing (possibly deliberately-zero) target and never seeds a machine row.
--
-- Two parts: (1) BACKFILL existing gapped lines; (2) a TRIGGER so a future line
-- auto-seeds once its lead_machine is assigned (bulk import bypasses the edge-api
-- create path, which is where a per-request seed would otherwise live).

BEGIN;

-- Ideal hourly target: 85% of the line's lead-machine nameplate speed.
CREATE OR REPLACE FUNCTION config.piot_line_default_target_hour(p_line int)
RETURNS int LANGUAGE sql STABLE AS $fn$
  SELECT round(COALESCE(m.production_speed, 0) * 0.85)::int
    FROM core.equipments l
    LEFT JOIN core.equipments m ON m.id_equipment = l.lead_machine
   WHERE l.id_equipment = p_line;
$fn$;

-- (1) Backfill every tp=3 line that has a lead-machine nameplate speed but no
--     target row yet.
INSERT INTO config.production_targets
       (id_equipment, id_enterprise, id_site, id_area, vl_hour, vl_shift, vl_day, vl_week, vl_month)
SELECT l.id_equipment, l.id_enterprise, l.id_site, l.id_area,
       t.h, t.h * 8, t.h * 24, t.h * 24 * 7, t.h * 24 * 30
  FROM core.equipments l
  CROSS JOIN LATERAL (SELECT config.piot_line_default_target_hour(l.id_equipment) AS h) t
 WHERE l.tp_equipment = 3
   AND l.id_site IS NOT NULL
   AND t.h > 0
   AND NOT EXISTS (SELECT 1 FROM config.production_targets pt WHERE pt.id_equipment = l.id_equipment);

-- (2) Forward guard: seed on line insert, or when its lead_machine is (re)assigned.
CREATE OR REPLACE FUNCTION config.piot_seed_line_default_target() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE h int;
BEGIN
  IF NEW.tp_equipment <> 3 OR NEW.id_site IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM config.production_targets WHERE id_equipment = NEW.id_equipment) THEN
    RETURN NEW;
  END IF;
  h := config.piot_line_default_target_hour(NEW.id_equipment);
  IF COALESCE(h, 0) > 0 THEN
    INSERT INTO config.production_targets
           (id_equipment, id_enterprise, id_site, id_area, vl_hour, vl_shift, vl_day, vl_week, vl_month)
    VALUES (NEW.id_equipment, NEW.id_enterprise, NEW.id_site, NEW.id_area,
            h, h * 8, h * 24, h * 24 * 7, h * 24 * 30);
  END IF;
  RETURN NEW;
END; $fn$;

DROP TRIGGER IF EXISTS trg_seed_line_default_target ON core.equipments;
CREATE TRIGGER trg_seed_line_default_target
  AFTER INSERT OR UPDATE OF lead_machine ON core.equipments
  FOR EACH ROW EXECUTE FUNCTION config.piot_seed_line_default_target();

COMMIT;
