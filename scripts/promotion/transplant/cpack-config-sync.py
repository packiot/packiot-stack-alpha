#!/usr/bin/env python3
"""CPACK (ent 3) configuration sync — carry staging's curated equipment config + downtime-reason catalog to prod.

Decided 2026-10-09 (runbook §6.1): prod's CPACK config drifted from staging on core.equipments (display flag, stop
threshold, minimum thresholds, reason tree, lead/gross/net/scrap machine, production/ideal speed, position, …) and in the
reason catalog. Staging's values are months of fixes verified against legacy, so prod takes them.

Three steps, all files reviewable:

  1. extract (READ ONLY, against STAGING)      → <workdir>/cpack-config.json
       cpack-config-sync.py extract --psql 'psql "host=… dbname=packiot_analytics user=…"' -o <workdir>/cpack-config.json
     (any psql command line works, e.g. 'docker exec -i stack-pgbouncer-1 psql -h … -U … -d packiot_analytics'; the query
      runs inside BEGIN READ ONLY … ROLLBACK and only SELECTs.)
  2. emit (no DB access)                        → 07b-cpack-config.sql (apply) + 07b-cpack-config-diff.sql (read-only report)
       cpack-config-sync.py emit <workdir>/cpack-config.json -o <dir>      (build.py calls this when the JSON is present)
  3. on the TARGET (packiot_next during the transplant, after phase `data`, before `logic`):
       xplant.sh cpack-diff   # READ ONLY: per-column target vs staging, skipped rows and why — review it
       xplant.sh cpack        # apply, idempotent (a re-run changes nothing), one transaction, ends with a report

IDENTITY — never trust id_equipment across databases. An equipment is matched by its BASE packml topic (the shortest
active topic, enterprise prefix stripped — the same key legacy-replicator and t-cpack-reason-catalog use:
'CPACK/SC/LINHAS/L5/BREYER' and 'C-PACK/SC/LINHAS/L5/BREYER' both → 'SC/LINHAS/L5/BREYER'), and the match is only
trusted when tp_equipment AND nm_equipment agree (cd_equipment too when both sides have one — prod's is often empty).
Anything else — no topic, no/ambiguous target, kind or name differs — is SKIPPED and reported, never written.
Machine references (lead/gross/net/scrap) are translated through the same verified map; an unmappable reference keeps
the target's current value and is reported.

Reason catalog (ent 3): core.downtime_reason keyed by code (unique per enterprise while active): changed rows updated,
missing rows inserted (parents first), rows staging no longer has are DEACTIVATED (active=false, valid_to=now()), never
deleted (events store the code text; old ids stay valid FK targets). core.equipment_downtime_reason is rebuilt only for
equipments whose identity verified.
"""
import argparse, json, os, shlex, subprocess, sys

ENT = 3
# Value columns copied verbatim (typed via jsonb_populate_record(NULL::core.equipments, …)).
VALUE_COLUMNS = ['event_should_be_displayed', 'stop_threshold_time', 'minimum_performance_threshold',
                 'minimum_ideal_performance_threshold', 'downtime_reasons', 'production_speed', 'ideal_speed', 'position',
                 'downtime_from_lead_machine']
# Columns that hold another equipment's id — translated staging id → base topic → target id.
REF_COLUMNS = ['lead_machine', 'gross_machine', 'net_machine', 'scrap_machine']

BASE_TOPIC_SQL = """SELECT DISTINCT ON (p.id_equipment) p.id_equipment, regexp_replace(p.packml_topic, '^[^/]*/', '') AS base
  FROM core.packml_register p
 WHERE p.id_enterprise = {ent} AND p.active AND p.id_equipment IS NOT NULL
 ORDER BY p.id_equipment, array_length(string_to_array(p.packml_topic, '/'), 1), p.packml_topic"""


def extract_sql():
    cols = ', '.join(f'e.{c}' for c in VALUE_COLUMNS + REF_COLUMNS)
    return f"""\\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
WITH b AS ({BASE_TOPIC_SQL.format(ent=ENT)}),
eq AS (SELECT e.id_equipment, b.base, e.tp_equipment, e.nm_equipment, e.cd_equipment, {cols}
         FROM core.equipments e LEFT JOIN b USING (id_equipment) WHERE e.id_enterprise = {ENT}),
rs AS (SELECT r.code, r.reason_level, r.label, r.label_i18n, r.category, pr.code AS parent_code,
              r.planned_downtime, r.change_over, r.idle
         FROM core.downtime_reason r LEFT JOIN core.downtime_reason pr ON pr.id = r.parent_id
        WHERE r.id_enterprise = {ENT} AND r.active),
lk AS (SELECT j.id_equipment, r.code
         FROM core.equipment_downtime_reason j
         JOIN core.downtime_reason r ON r.id = j.id_reason AND r.id_enterprise = {ENT} AND r.active
         JOIN core.equipments e ON e.id_equipment = j.id_equipment AND e.id_enterprise = {ENT}
        WHERE j.active IS NOT FALSE)
SELECT json_build_object(
  'source_db', current_database(), 'extracted_at', now(), 'enterprise', {ENT},
  'enterprise_name', (SELECT nm_enterprise FROM core.enterprises WHERE id_enterprise = {ENT}),
  'equipments', (SELECT coalesce(json_agg(eq ORDER BY id_equipment), '[]') FROM eq),
  'reasons', (SELECT coalesce(json_agg(rs ORDER BY reason_level, code), '[]') FROM rs),
  'links', (SELECT coalesce(json_agg(lk ORDER BY id_equipment, code), '[]') FROM lk))::jsonb::text;  -- one line
ROLLBACK;
"""


def cmd_extract(a):
    out = subprocess.run(shlex.split(a.psql) + ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'], input=extract_sql(),
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'extract failed (rc={out.returncode}): {out.stderr.strip()}')
    lines = [l for l in out.stdout.splitlines() if l.strip().startswith('{')]
    if len(lines) != 1:
        sys.exit(f'extract: expected one JSON line, got {len(lines)}: {out.stdout[:400]}')
    snap = json.loads(lines[0])
    json.dump(snap, open(a.output, 'w'), indent=1, sort_keys=True)
    print(f"extracted {len(snap['equipments'])} equipments, {len(snap['reasons'])} reasons, {len(snap['links'])} links "
          f"from {snap['source_db']} ent {snap['enterprise']} ({snap['enterprise_name']}) → {a.output}")


def dollar(s):
    tag = 'cfg'
    while f'${tag}$' in s:
        tag += 'x'
    return f'${tag}${s}${tag}$'


def build_payload(snap):
    by_id = {e['id_equipment']: e for e in snap['equipments']}
    eqs = []
    for e in snap['equipments']:
        refs = {}
        for c in REF_COLUMNS:
            src = e.get(c)
            refs[c] = None if src is None else {'src': src, 'base': (by_id.get(src) or {}).get('base')}
        eqs.append({'src_id': e['id_equipment'], 'base': e['base'], 'tp': e['tp_equipment'], 'nm': e['nm_equipment'],
                    'cd': e['cd_equipment'], 'cols': {c: e.get(c) for c in VALUE_COLUMNS}, 'refs': refs})
    links = [{'base': (by_id.get(l['id_equipment']) or {}).get('base'), 'src_id': l['id_equipment'], 'code': l['code']}
             for l in snap['links']]
    return eqs, snap['reasons'], links


# CTEs shared by apply and diff. :name_re guards that ENT on the target is the same client.
def common_ctes(eqs, reasons, links, inline=True):
    """inline=True embeds the JSON literals (read-only diff: no temp tables allowed); False reads them from _cs_json."""
    def src(k, v):
        return f"{dollar(json.dumps(v, sort_keys=True))}::jsonb" if inline else f"(SELECT j FROM _cs_json WHERE k = '{k}')"
    return f"""snap AS (
  SELECT * FROM jsonb_to_recordset({src('eqs', eqs)})
         AS x(src_id int, base text, tp int, nm text, cd text, cols jsonb, refs jsonb)),
rsnap AS (
  SELECT * FROM jsonb_to_recordset({src('reasons', reasons)})
         AS x(code text, reason_level smallint, label text, label_i18n jsonb, category text, parent_code text,
              planned_downtime boolean, change_over boolean, idle boolean)),
lsnap AS (
  SELECT * FROM jsonb_to_recordset({src('links', links)}) AS x(base text, src_id int, code text)),
tb AS ({BASE_TOPIC_SQL.format(ent=ENT)}),
tgt AS (SELECT e.id_equipment, tb.base, e.tp_equipment, e.nm_equipment, e.cd_equipment
          FROM core.equipments e JOIN tb USING (id_equipment) WHERE e.id_enterprise = {ENT}),
map AS (
  SELECT s.*, t.id_equipment AS tgt_id, t.nm_equipment AS tgt_nm,
         CASE WHEN s.base IS NULL                                                THEN 'skip: no active topic on staging'
              WHEN (SELECT count(*) FROM snap s2 WHERE s2.base = s.base) > 1     THEN 'skip: ambiguous staging topic'
              WHEN (SELECT count(*) FROM tgt t2 WHERE t2.base = s.base) > 1      THEN 'skip: ambiguous target topic'
              WHEN t.id_equipment IS NULL                                        THEN 'skip: no target equipment for topic'
              WHEN t.tp_equipment IS DISTINCT FROM s.tp                          THEN 'skip: tp_equipment differs'
              WHEN lower(btrim(t.nm_equipment)) IS DISTINCT FROM lower(btrim(s.nm)) THEN 'skip: nm_equipment differs'
              WHEN coalesce(t.cd_equipment, '') <> '' AND coalesce(s.cd, '') <> ''
                   AND t.cd_equipment <> s.cd                                    THEN 'skip: cd_equipment differs'
              ELSE 'ok' END AS status
    FROM snap s LEFT JOIN tgt t ON t.base = s.base),
ok AS (SELECT * FROM map WHERE status = 'ok'),
-- desired value per (target equipment, column) as jsonb; refs translated, unmappable refs flagged
want AS (
  SELECT m.tgt_id, c.col, (m.cols -> c.col) AS v, true AS mappable
    FROM ok m CROSS JOIN unnest(ARRAY{VALUE_COLUMNS!r}::text[]) AS c(col)
  UNION ALL
  SELECT m.tgt_id, c.col,
         CASE WHEN m.refs -> c.col = 'null'::jsonb OR m.refs -> c.col IS NULL THEN 'null'::jsonb
              ELSE to_jsonb((SELECT o.tgt_id FROM ok o WHERE o.base = m.refs -> c.col ->> 'base')) END,
         m.refs -> c.col = 'null'::jsonb OR m.refs -> c.col IS NULL
           OR EXISTS (SELECT 1 FROM ok o WHERE o.base = m.refs -> c.col ->> 'base')
    FROM ok m CROSS JOIN unnest(ARRAY{REF_COLUMNS!r}::text[]) AS c(col)),
cur AS (SELECT e.id_equipment AS tgt_id, to_jsonb(e) AS j FROM core.equipments e WHERE e.id_enterprise = {ENT}),
treason AS (SELECT r.*, pr.code AS parent_code FROM core.downtime_reason r
              LEFT JOIN core.downtime_reason pr ON pr.id = r.parent_id
             WHERE r.id_enterprise = {ENT} AND r.active),
wlink AS (SELECT DISTINCT o.tgt_id, l.code FROM lsnap l JOIN ok o ON o.base = l.base)"""


def guard_sql(name_re):
    return f"""DO $g$ BEGIN
  IF coalesce((SELECT nm_enterprise FROM core.enterprises WHERE id_enterprise = {ENT}), '') !~* {dollar(name_re)} THEN
    RAISE EXCEPTION 'cpack-config-sync: enterprise {ENT} on this DB does not match % — refusing', {dollar(name_re)};
  END IF;
END $g$;"""


def emit_apply(eqs, reasons, links, name_re, meta):
    ctes = common_ctes(eqs, reasons, links, inline=False)
    blobs = '\n'.join(f"INSERT INTO _cs_json VALUES ('{k}', {dollar(json.dumps(v, sort_keys=True))}::jsonb);"
                      for k, v in (('eqs', eqs), ('reasons', reasons), ('links', links)))
    vals = ',\n       '.join(f"{c} = r.{c}" for c in VALUE_COLUMNS)
    refs = ',\n       '.join(
        f"""{c} = CASE WHEN m.refs -> '{c}' IS NULL OR m.refs -> '{c}' = 'null'::jsonb THEN NULL
                     ELSE coalesce((SELECT o.tgt_id FROM ok o WHERE o.base = m.refs -> '{c}' ->> 'base'), e.{c}) END"""
        for c in REF_COLUMNS)
    differs = ' OR '.join(f"e.{c} IS DISTINCT FROM r.{c}" for c in VALUE_COLUMNS) + ' OR ' + ' OR '.join(
        f"""e.{c} IS DISTINCT FROM (CASE WHEN m.refs -> '{c}' IS NULL OR m.refs -> '{c}' = 'null'::jsonb THEN NULL
              ELSE coalesce((SELECT o.tgt_id FROM ok o WHERE o.base = m.refs -> '{c}' ->> 'base'), e.{c}) END)"""
        for c in REF_COLUMNS)
    return f"""-- 07b-cpack-config.sql — GENERATED by scripts/promotion/transplant/cpack-config-sync.py; do not hand-edit.
-- Source: {meta}
-- Apply staging's CPACK (ent {ENT}) equipment config + downtime-reason catalog. Idempotent; one transaction.
\\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '10min';
{guard_sql(name_re)}

CREATE TEMP TABLE _cs_json (k text PRIMARY KEY, j jsonb NOT NULL) ON COMMIT DROP;
{blobs}
CREATE TEMP TABLE _cs_map ON COMMIT DROP AS
WITH {ctes}
SELECT src_id, base, tp, nm, cd, cols, refs, tgt_id, tgt_nm, status FROM map;
CREATE TEMP TABLE _cs_rsnap ON COMMIT DROP AS
WITH {ctes}
SELECT * FROM rsnap;
CREATE TEMP TABLE _cs_wlink ON COMMIT DROP AS
WITH {ctes}
SELECT * FROM wlink;

-- 1. core.equipments: value columns + translated machine references, only where something differs
WITH ok AS (SELECT * FROM _cs_map WHERE status = 'ok'),
upd AS (
UPDATE core.equipments e
   SET {vals},
       {refs},
       updated_at = now()
  FROM ok m CROSS JOIN LATERAL jsonb_populate_record(NULL::core.equipments, m.cols) r
 WHERE e.id_equipment = m.tgt_id AND e.id_enterprise = {ENT}
   AND ({differs})
RETURNING e.id_equipment)
SELECT 'equipments updated', count(*) FROM upd;

-- 2. reason catalog: deactivate what staging no longer has, update changed, insert missing (parents first)
WITH d AS (
UPDATE core.downtime_reason r SET active = false, valid_to = now(), updated_at = now()
 WHERE r.id_enterprise = {ENT} AND r.active AND NOT EXISTS (SELECT 1 FROM _cs_rsnap s WHERE s.code = r.code)
RETURNING 1) SELECT 'reasons deactivated', count(*) FROM d;
WITH u AS (
UPDATE core.downtime_reason r
   SET label = s.label, label_i18n = s.label_i18n, category = s.category, reason_level = s.reason_level,
       planned_downtime = s.planned_downtime, change_over = s.change_over, idle = s.idle,
       parent_id = (SELECT p.id FROM core.downtime_reason p
                     WHERE p.id_enterprise = {ENT} AND p.active AND p.code = s.parent_code),
       updated_at = now()
  FROM _cs_rsnap s
 WHERE r.id_enterprise = {ENT} AND r.active AND r.code = s.code
   AND (r.label, r.label_i18n, r.category, r.reason_level, r.planned_downtime, r.change_over, r.idle)
       IS DISTINCT FROM (s.label, s.label_i18n, s.category, s.reason_level, s.planned_downtime, s.change_over, s.idle)
RETURNING 1) SELECT 'reasons updated', count(*) FROM u;
WITH i AS (
INSERT INTO core.downtime_reason (id_enterprise, code, label, label_i18n, category, reason_level, planned_downtime,
                                  change_over, idle, active)
SELECT {ENT}, s.code, s.label, s.label_i18n, s.category, s.reason_level, s.planned_downtime, s.change_over, s.idle, true
  FROM _cs_rsnap s
 WHERE s.reason_level = 1
   AND NOT EXISTS (SELECT 1 FROM core.downtime_reason r WHERE r.id_enterprise = {ENT} AND r.active AND r.code = s.code)
RETURNING 1) SELECT 'reasons inserted (level 1)', count(*) FROM i;
WITH i AS (
INSERT INTO core.downtime_reason (id_enterprise, code, label, label_i18n, category, parent_id, reason_level,
                                  planned_downtime, change_over, idle, active)
SELECT {ENT}, s.code, s.label, s.label_i18n, s.category,
       (SELECT p.id FROM core.downtime_reason p WHERE p.id_enterprise = {ENT} AND p.active AND p.code = s.parent_code),
       s.reason_level, s.planned_downtime, s.change_over, s.idle, true
  FROM _cs_rsnap s
 WHERE s.reason_level <> 1
   AND NOT EXISTS (SELECT 1 FROM core.downtime_reason r WHERE r.id_enterprise = {ENT} AND r.active AND r.code = s.code)
RETURNING 1) SELECT 'reasons inserted (level 2+)', count(*) FROM i;
-- parents that were inserted after their children's update pass
UPDATE core.downtime_reason r
   SET parent_id = p.id, updated_at = now()
  FROM _cs_rsnap s JOIN core.downtime_reason p ON p.id_enterprise = {ENT} AND p.active AND p.code = s.parent_code
 WHERE r.id_enterprise = {ENT} AND r.active AND r.code = s.code AND r.parent_id IS DISTINCT FROM p.id;

-- 3. equipment ↔ reason links, rebuilt ONLY for identity-verified equipments
WITH want AS (
  SELECT w.tgt_id AS id_equipment, r.id AS id_reason
    FROM _cs_wlink w JOIN core.downtime_reason r ON r.id_enterprise = {ENT} AND r.active AND r.code = w.code),
del AS (
DELETE FROM core.equipment_downtime_reason j
 WHERE j.id_equipment IN (SELECT tgt_id FROM _cs_map WHERE status = 'ok')
   AND NOT EXISTS (SELECT 1 FROM want w WHERE w.id_equipment = j.id_equipment AND w.id_reason = j.id_reason)
RETURNING 1),
ins AS (
INSERT INTO core.equipment_downtime_reason (id_equipment, id_reason)
SELECT w.id_equipment, w.id_reason FROM want w
 WHERE NOT EXISTS (SELECT 1 FROM core.equipment_downtime_reason j
                    WHERE j.id_equipment = w.id_equipment AND j.id_reason = w.id_reason)
RETURNING 1)
SELECT 'links deleted', (SELECT count(*) FROM del), 'links inserted', (SELECT count(*) FROM ins);

-- 4. report: identity outcome + every skipped row + unmappable machine references (kept at the target's value)
SELECT 'identity', status, count(*) FROM _cs_map GROUP BY status ORDER BY status;
SELECT 'SKIPPED', src_id, base, nm, tgt_id, tgt_nm, status FROM _cs_map WHERE status <> 'ok' ORDER BY src_id;
SELECT 'UNMAPPED REF (target value kept)', m.src_id, m.base, c.col, m.refs -> c.col
  FROM _cs_map m CROSS JOIN unnest(ARRAY{REF_COLUMNS!r}::text[]) AS c(col)
 WHERE m.status = 'ok' AND m.refs -> c.col IS NOT NULL AND m.refs -> c.col <> 'null'::jsonb
   AND NOT EXISTS (SELECT 1 FROM _cs_map o WHERE o.status = 'ok' AND o.base = m.refs -> c.col ->> 'base');
COMMIT;
"""


def emit_diff(eqs, reasons, links, name_re, meta):
    ctes = common_ctes(eqs, reasons, links)
    return f"""-- 07b-cpack-config-diff.sql — GENERATED by scripts/promotion/transplant/cpack-config-sync.py; do not hand-edit.
-- Source: {meta}
-- READ-ONLY report of what 07b-cpack-config.sql would change on this DB (ent {ENT}). Writes nothing.
\\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
SELECT CASE WHEN coalesce((SELECT nm_enterprise FROM core.enterprises WHERE id_enterprise = {ENT}), '') ~* {dollar(name_re)}
            THEN 'enterprise {ENT} name matches' ELSE 'WARNING: enterprise {ENT} name does not match — apply would refuse' END;
WITH {ctes},
eqdiff AS (
  SELECT 'equipment'::text AS section, w.tgt_id::text AS key, w.col AS item,
         cur.j -> w.col AS target_value, w.v AS staging_value,
         CASE WHEN NOT w.mappable THEN 'unmapped ref: target value kept' ELSE 'change' END AS action
    FROM want w JOIN cur USING (tgt_id)
   WHERE w.mappable IS FALSE OR (cur.j -> w.col) IS DISTINCT FROM w.v),
skipped AS (
  SELECT 'equipment'::text, coalesce(base, '(no topic)') || ' [stg ' || src_id || ']', 'identity',
         to_jsonb(tgt_nm), to_jsonb(nm), status
    FROM map WHERE status <> 'ok'),
rdiff AS (
  SELECT 'reason'::text, coalesce(s.code, t.code), 'row',
         CASE WHEN t.code IS NULL THEN NULL ELSE jsonb_build_object('label', t.label, 'category', t.category,
              'level', t.reason_level, 'parent', t.parent_code, 'planned', t.planned_downtime, 'change_over', t.change_over,
              'idle', t.idle, 'i18n', t.label_i18n) END,
         CASE WHEN s.code IS NULL THEN NULL ELSE jsonb_build_object('label', s.label, 'category', s.category,
              'level', s.reason_level, 'parent', s.parent_code, 'planned', s.planned_downtime, 'change_over', s.change_over,
              'idle', s.idle, 'i18n', s.label_i18n) END,
         CASE WHEN t.code IS NULL THEN 'insert' WHEN s.code IS NULL THEN 'deactivate' ELSE 'update' END
    FROM rsnap s FULL JOIN treason t ON t.code = s.code
   WHERE s.code IS NULL OR t.code IS NULL
      OR (t.label, t.label_i18n, t.category, t.reason_level, t.planned_downtime, t.change_over, t.idle, t.parent_code)
         IS DISTINCT FROM (s.label, s.label_i18n, s.category, s.reason_level, s.planned_downtime, s.change_over, s.idle,
                           s.parent_code)),
tlink AS (SELECT j.id_equipment AS tgt_id, r.code FROM core.equipment_downtime_reason j
            JOIN core.downtime_reason r ON r.id = j.id_reason
           WHERE j.id_equipment IN (SELECT tgt_id FROM ok)),
ldiff AS (
  SELECT 'links'::text, coalesce(w.tgt_id, t.tgt_id)::text, 'reason links',
         to_jsonb(count(*) FILTER (WHERE w.code IS NULL)), to_jsonb(count(*) FILTER (WHERE t.code IS NULL)),
         'delete/insert'
    FROM wlink w FULL JOIN tlink t ON t.tgt_id = w.tgt_id AND t.code = w.code
   WHERE w.code IS NULL OR t.code IS NULL
   GROUP BY coalesce(w.tgt_id, t.tgt_id))
SELECT * FROM (
  SELECT 'summary' AS section, status AS key, 'identity' AS item, to_jsonb(count(*)) AS target_value,
         NULL::jsonb AS staging_value, '' AS action FROM map GROUP BY status
  UNION ALL SELECT * FROM skipped
  UNION ALL SELECT * FROM eqdiff
  UNION ALL SELECT * FROM rdiff
  UNION ALL SELECT * FROM ldiff) x
ORDER BY section, key, item;
ROLLBACK;
"""


def cmd_emit(a):
    snap = json.load(open(a.snapshot))
    if snap.get('enterprise') != ENT:
        sys.exit(f"snapshot is for enterprise {snap.get('enterprise')}, expected {ENT}")
    eqs, reasons, links = build_payload(snap)
    meta = f"{snap['source_db']} ent {ENT} extracted {snap['extracted_at']} — {len(eqs)} equipments, {len(reasons)} reasons, {len(links)} links"
    os.makedirs(a.output_dir, exist_ok=True)
    for name, text in (('07b-cpack-config.sql', emit_apply(eqs, reasons, links, a.enterprise_name_re, meta)),
                       ('07b-cpack-config-diff.sql', emit_diff(eqs, reasons, links, a.enterprise_name_re, meta))):
        open(os.path.join(a.output_dir, name), 'w', newline='').write(text)
    no_base = [e['src_id'] for e in eqs if not e['base']]
    print(f"emitted 07b-cpack-config.sql + 07b-cpack-config-diff.sql → {a.output_dir} ({meta}); "
          f"staging equipments without an active topic (will be skipped): {no_base or 'none'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    e = sub.add_parser('extract', help='READ ONLY snapshot of staging ent 3 config → JSON')
    e.add_argument('--psql', required=True, help='psql command line connected to STAGING packiot_analytics')
    e.add_argument('-o', '--output', required=True)
    m = sub.add_parser('emit', help='JSON → apply SQL + read-only diff SQL (no DB access)')
    m.add_argument('snapshot')
    m.add_argument('-o', '--output-dir', required=True)
    m.add_argument('--enterprise-name-re', default='c-?pack',
                   help="target ent 3 nm_enterprise must match this (case-insensitive) regex, else apply refuses")
    a = ap.parse_args()
    {'extract': cmd_extract, 'emit': cmd_emit}[a.cmd](a)


if __name__ == '__main__':
    main()
