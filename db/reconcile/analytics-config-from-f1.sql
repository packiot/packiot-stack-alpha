-- analytics-config-from-f1.sql
-- ---------------------------------------------------------------------------
-- Idempotent config reconciliation: copy packml_register line-meter columns
-- from F1 (packiot, legacy write-master) into F3 (packiot_analytics, the plane
-- we are consolidating to) for the CPACK enterprises.
--
-- WHY THIS EXISTS
--   The stream-engine `refsync` job mirrors master/reference tables main->F3 with
--   a PK upsert, but DELIBERATELY EXCLUDES packml_register (see
--   services/stream-engine/internal/refsync/refsync.go). analytics-sync
--   (shadow-mirror) only replays operator ACTIONS, not config. So the
--   packml_register line-meter columns
--       id_infeedcounter / id_outfeedcounter / id_rejectcounter
--   never mirror to F3: they are loose integer refs (NO foreign key) that the
--   Phase-9 line-agg seeder reads to attribute line counts. They sit NULL in F3
--   while F1 has them set for every CPACK line (L3/L4/L5/L6/L8/L10), which
--   silently zeroes CPACK line OEE once the decoder reads F3.
--
-- WHAT IT DOES  (CONFIG ONLY — never touches telemetry: equipment_values,
--               caggs, uns_*)
--   For enterprises 3 (CPACK-Staging) and 2000003 (SANDBOX-CPACK), UPSERT-in-place
--   the three meter columns onto the matching F3 rows, matched by the NATURAL KEY
--   (id_enterprise, packml_topic).
--
--   Natural key, NOT id_packml_register, on purpose: ent-3 happens to share F1's
--   id space (ids aligned), but the sandbox twin 2000003 does NOT (F1 2000140 vs
--   F3 504 for the same topic). Matching on the topic is correct for both.
--
--   No INSERT of "missing" rows: the F1<->F3 packml_register rowcount gap
--   (ent-3: 154 vs 137) is entirely DUPLICATE `CPACK_STAGING/*` placeholder rows
--   that exist twice in F1 and once (deduped) in F3. Every REAL topic is already
--   present in F3 with a matching id (audited: 120 == 120 real ent-3 rows). So
--   there is nothing real to insert; copying F1's duplicates would REGRESS F3.
--
-- IDEMPOTENT: the `IS DISTINCT FROM` guard means a re-run updates 0 rows once
--   converged, and the reported row count equals the number of rows actually
--   changed (observable, per the bug-247/248 no-op-visibility lesson).
--
-- HOW TO RUN (against F3, which has the dblink extension installed):
--   psql -h 10.10.10.89 -U postgres -d packiot_analytics \
--     -v f1_dsn="host=10.10.10.89 port=5432 dbname=packiot user=postgres password=$F1_PW" \
--     -f db/reconcile/analytics-config-from-f1.sql
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS dblink;

WITH f1 AS (
  SELECT *
    FROM dblink(:'f1_dsn',
      $f1$ SELECT id_enterprise, packml_topic,
                  id_infeedcounter, id_outfeedcounter, id_rejectcounter
             FROM public.packml_register
            WHERE id_enterprise IN (3, 2000003)
              AND (id_infeedcounter  IS NOT NULL
                OR id_outfeedcounter IS NOT NULL
                OR id_rejectcounter  IS NOT NULL) $f1$)
      AS t(id_enterprise integer, packml_topic text,
           id_infeedcounter integer, id_outfeedcounter integer, id_rejectcounter integer)
)
UPDATE public.packml_register AS f3
   SET id_infeedcounter  = f1.id_infeedcounter,
       id_outfeedcounter = f1.id_outfeedcounter,
       id_rejectcounter  = f1.id_rejectcounter
  FROM f1
 WHERE f3.id_enterprise = f1.id_enterprise
   AND f3.packml_topic  = f1.packml_topic
   AND ( f3.id_infeedcounter  IS DISTINCT FROM f1.id_infeedcounter
      OR f3.id_outfeedcounter IS DISTINCT FROM f1.id_outfeedcounter
      OR f3.id_rejectcounter  IS DISTINCT FROM f1.id_rejectcounter );

-- Verification (read-only): the reconciled meter coverage in F3.
SELECT id_enterprise, packml_topic,
       id_infeedcounter, id_outfeedcounter, id_rejectcounter
  FROM public.packml_register
 WHERE id_enterprise IN (3, 2000003)
   AND (id_infeedcounter  IS NOT NULL
     OR id_outfeedcounter IS NOT NULL
     OR id_rejectcounter  IS NOT NULL)
 ORDER BY id_enterprise, packml_topic;

COMMIT;
