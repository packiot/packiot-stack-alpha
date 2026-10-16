-- t-deriver-phantom-running-cleanup — delete the phantom RUNNING (status 6) rows the
-- count-silence deriver (stream-engine cpac_deriver.go) left behind, then re-chain the rows
-- that pointed at them. PR #1486. DO NOT apply before that stream-engine build is deployed:
-- the old build mints a new phantom on every tick.
--
-- WHY THEY EXIST (two stacked deriver bugs, both fixed in #1486):
--  1. Window edge: the 25h read window had no look-back, so the first productive minute in
--     the window always had gap NULL => a "session start" => a status-6 row at now()-25h on
--     EVERY tick (~1 per productive minute per equipment).
--  2. NULL-unsafe human guard: `NOT (... OR ev.planned_downtime OR ev.change_over ...)` is
--     NULL for every derived row (those columns are NULL, no default), so the correct pass
--     never deleted and DO UPDATE never refreshed. Phantoms, and stops superseded by late
--     counts, were never cleaned (staging logs: corrected=0 on every tick).
-- The deriver's stream strictly alternates 6/10, so a derived status-6 row directly after
-- another status-6 row carries no information: the earlier row already says "running".
--
-- STAGING SIZE (read-only dry run of exactly this selection, 2026-09-29 ~20:00Z; grows ~1
-- row per productive minute per equipment until #1486 is deployed):
--   ent5 live   silver.equipment_events              98,600 phantoms / 16 equipments
--               (of 99,652 in-scope rows), 421 chain heads re-chained, 0 human rows
--   ent3 shadow silver.equipment_events_cpac_shadow 833,874 phantoms / 46 equipments
--               (of 855,184 rows), 8,220 chain heads re-chained, 0 human rows
--
-- SAFETY: full row backups in ops._bkp_phantom_running_{live,shadow}_20260929 and the old
-- ts_end/duration of every re-chained row in ops._bkp_phantom_rechain_20260929 (rollback.sql
-- restores both). Never deletes or edits a human-touched / forced_creation_system row or
-- a row inside a human-protected span. Only the deriver's scope (status_type=0, tp 1/3).
-- The Downtimes views read status <> 6, so they are unchanged; refresh anyway at the end.
-- equipment_events is a compressed hypertable (TimescaleDB 2.27 DML on compressed chunks):
-- run it in a quiet window.
BEGIN;
SET LOCAL statement_timeout = 0;
SET LOCAL search_path TO core, public;

CREATE TABLE ops._bkp_phantom_running_live_20260929   (LIKE silver.equipment_events);
CREATE TABLE ops._bkp_phantom_running_shadow_20260929 (LIKE silver.equipment_events_cpac_shadow);
CREATE TABLE ops._bkp_phantom_rechain_20260929 (
    src text NOT NULL, id_equipment int NOT NULL, ts_event timestamptz NOT NULL,
    ts_end timestamptz, duration int, PRIMARY KEY (src, id_equipment, ts_event));

-- ─── live: silver.equipment_events, enterprise 5 ─────────────────────────────────
-- human-protected spans (a handful of rows) materialized once for the cover guard
CREATE TEMP TABLE hs_live ON COMMIT DROP AS
SELECT h.id_equipment, h.ts_event, COALESCE(h.ts_end, now()) AS ts_until
  FROM silver.equipment_events h
 WHERE h.id_enterprise = 5
   AND (h.forced_creation_system IS TRUE
                OR h.cd_category IS NOT NULL OR h.cd_subcategory IS NOT NULL
                OR h.cd_machine IS NOT NULL OR h.txt_downtime_notes IS NOT NULL
                OR h.planned_downtime IS TRUE OR h.change_over IS TRUE OR h.idle IS NOT NULL);

-- ONE window pass over the deriver's scope: flag each phantom and each chain head (the
-- surviving non-human row right before a run of phantoms, whose ts_end must be re-pointed).
CREATE TEMP TABLE cand_live ON COMMIT DROP AS
WITH x AS (
    SELECT ev.id_equipment, ev.ts_event, ev.status, ev.ts_end, ev.duration,
           (ev.forced_creation_system IS TRUE
                OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
                OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
                OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL) AS is_human,
           lag(ev.status) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event) AS prev_status
      FROM silver.equipment_events ev
     WHERE ev.id_enterprise = 5
       -- the deriver's own scope (status_type=0, tp 1/3); rows of other writers /
       -- deleted equipment (e.g. ent5 id 2000109, off-minute rows) stay untouched
       AND ev.id_equipment IN (SELECT e.id_equipment FROM core.equipments e
                                WHERE e.id_enterprise = 5 AND e.status_type = 0
                                  AND e.tp_equipment IN (1, 3))
), y AS (
    SELECT x.*,
           (x.status = 6 AND x.prev_status = 6                  -- RUNNING right after RUNNING
            AND x.ts_event = date_trunc('minute', x.ts_event)   -- deriver minute grain
            AND x.is_human IS NOT TRUE
            -- human-cover guard: never touch a row inside an operator-owned span
            AND NOT EXISTS (SELECT 1 FROM hs_live h
                             WHERE h.id_equipment = x.id_equipment
                               AND x.ts_event >= h.ts_event AND x.ts_event < h.ts_until)) AS is_ph
      FROM x
)
SELECT y.id_equipment, y.ts_event, y.ts_end, y.duration, y.is_human, y.is_ph,
       lead(y.is_ph) OVER (PARTITION BY y.id_equipment ORDER BY y.ts_event) AS next_is_ph
  FROM y;
CREATE TEMP TABLE ph_live ON COMMIT DROP AS
SELECT id_equipment, ts_event FROM cand_live WHERE is_ph;
CREATE UNIQUE INDEX ON ph_live (id_equipment, ts_event);
CREATE TEMP TABLE rc_live ON COMMIT DROP AS
SELECT id_equipment, ts_event, ts_end, duration FROM cand_live
 WHERE is_ph IS NOT TRUE AND next_is_ph AND is_human IS NOT TRUE;
ANALYZE ph_live;
ANALYZE rc_live;

INSERT INTO ops._bkp_phantom_running_live_20260929
SELECT ev.* FROM silver.equipment_events ev JOIN ph_live USING (id_equipment, ts_event);
INSERT INTO ops._bkp_phantom_rechain_20260929 (src, id_equipment, ts_event, ts_end, duration)
SELECT 'live', id_equipment, ts_event, ts_end, duration FROM rc_live;

DELETE FROM silver.equipment_events ev USING ph_live p
 WHERE ev.id_equipment = p.id_equipment AND ev.ts_event = p.ts_event;

-- re-point each chain head at the next SURVIVING event (NULL = open tail)
UPDATE silver.equipment_events ev
   SET ts_end   = nx.next_ts,
       duration = extract(epoch FROM (COALESCE(nx.next_ts, now()) - ev.ts_event))::int
  FROM rc_live r
  CROSS JOIN LATERAL (SELECT min(n.ts_event) AS next_ts FROM silver.equipment_events n
                       WHERE n.id_equipment = r.id_equipment AND n.ts_event > r.ts_event) nx
 WHERE ev.id_equipment = r.id_equipment AND ev.ts_event = r.ts_event
   AND NOT (ev.forced_creation_system IS TRUE
                OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
                OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
                OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL);

SELECT 'live' AS src,
       (SELECT count(*) FROM ph_live) AS phantoms_deleted,
       (SELECT count(DISTINCT id_equipment) FROM ph_live) AS equipments,
       (SELECT count(*) FROM rc_live) AS rows_rechained;

-- ─── shadow: silver.equipment_events_cpac_shadow, enterprise 3 ─────────────────────────────────
-- human-protected spans (a handful of rows) materialized once for the cover guard
CREATE TEMP TABLE hs_shadow ON COMMIT DROP AS
SELECT h.id_equipment, h.ts_event, COALESCE(h.ts_end, now()) AS ts_until
  FROM silver.equipment_events_cpac_shadow h
 WHERE h.id_enterprise = 3
   AND (h.forced_creation_system IS TRUE
                OR h.cd_category IS NOT NULL OR h.cd_subcategory IS NOT NULL
                OR h.cd_machine IS NOT NULL OR h.txt_downtime_notes IS NOT NULL
                OR h.planned_downtime IS TRUE OR h.change_over IS TRUE OR h.idle IS NOT NULL);

-- ONE window pass over the deriver's scope: flag each phantom and each chain head (the
-- surviving non-human row right before a run of phantoms, whose ts_end must be re-pointed).
CREATE TEMP TABLE cand_shadow ON COMMIT DROP AS
WITH x AS (
    SELECT ev.id_equipment, ev.ts_event, ev.status, ev.ts_end, ev.duration,
           (ev.forced_creation_system IS TRUE
                OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
                OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
                OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL) AS is_human,
           lag(ev.status) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event) AS prev_status
      FROM silver.equipment_events_cpac_shadow ev
     WHERE ev.id_enterprise = 3
       -- the deriver's own scope (status_type=0, tp 1/3); rows of other writers /
       -- deleted equipment (e.g. ent5 id 2000109, off-minute rows) stay untouched
       AND ev.id_equipment IN (SELECT e.id_equipment FROM core.equipments e
                                WHERE e.id_enterprise = 3 AND e.status_type = 0
                                  AND e.tp_equipment IN (1, 3))
), y AS (
    SELECT x.*,
           (x.status = 6 AND x.prev_status = 6                  -- RUNNING right after RUNNING
            AND x.ts_event = date_trunc('minute', x.ts_event)   -- deriver minute grain
            AND x.is_human IS NOT TRUE
            -- human-cover guard: never touch a row inside an operator-owned span
            AND NOT EXISTS (SELECT 1 FROM hs_shadow h
                             WHERE h.id_equipment = x.id_equipment
                               AND x.ts_event >= h.ts_event AND x.ts_event < h.ts_until)) AS is_ph
      FROM x
)
SELECT y.id_equipment, y.ts_event, y.ts_end, y.duration, y.is_human, y.is_ph,
       lead(y.is_ph) OVER (PARTITION BY y.id_equipment ORDER BY y.ts_event) AS next_is_ph
  FROM y;
CREATE TEMP TABLE ph_shadow ON COMMIT DROP AS
SELECT id_equipment, ts_event FROM cand_shadow WHERE is_ph;
CREATE UNIQUE INDEX ON ph_shadow (id_equipment, ts_event);
CREATE TEMP TABLE rc_shadow ON COMMIT DROP AS
SELECT id_equipment, ts_event, ts_end, duration FROM cand_shadow
 WHERE is_ph IS NOT TRUE AND next_is_ph AND is_human IS NOT TRUE;
ANALYZE ph_shadow;
ANALYZE rc_shadow;

INSERT INTO ops._bkp_phantom_running_shadow_20260929
SELECT ev.* FROM silver.equipment_events_cpac_shadow ev JOIN ph_shadow USING (id_equipment, ts_event);
INSERT INTO ops._bkp_phantom_rechain_20260929 (src, id_equipment, ts_event, ts_end, duration)
SELECT 'shadow', id_equipment, ts_event, ts_end, duration FROM rc_shadow;

DELETE FROM silver.equipment_events_cpac_shadow ev USING ph_shadow p
 WHERE ev.id_equipment = p.id_equipment AND ev.ts_event = p.ts_event;

-- re-point each chain head at the next SURVIVING event (NULL = open tail)
UPDATE silver.equipment_events_cpac_shadow ev
   SET ts_end   = nx.next_ts,
       duration = extract(epoch FROM (COALESCE(nx.next_ts, now()) - ev.ts_event))::int
  FROM rc_shadow r
  CROSS JOIN LATERAL (SELECT min(n.ts_event) AS next_ts FROM silver.equipment_events_cpac_shadow n
                       WHERE n.id_equipment = r.id_equipment AND n.ts_event > r.ts_event) nx
 WHERE ev.id_equipment = r.id_equipment AND ev.ts_event = r.ts_event
   AND NOT (ev.forced_creation_system IS TRUE
                OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
                OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
                OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL);

SELECT 'shadow' AS src,
       (SELECT count(*) FROM ph_shadow) AS phantoms_deleted,
       (SELECT count(DISTINCT id_equipment) FROM ph_shadow) AS equipments,
       (SELECT count(*) FROM rc_shadow) AS rows_rechained;

COMMIT;

-- The Downtimes table reads status <> 6 only; this refresh is a no-op safety net.
SELECT serving.refresh_downtime_events_resolved(date_trunc('month', now()) - interval '1 month', now());
