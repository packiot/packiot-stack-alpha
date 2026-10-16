#!/usr/bin/env python3
"""gen-cpack-reason-catalog.py — generate db/migrations/t-cpack-reason-catalog/01-up.sql
from a READ-ONLY extract of LEGACY CPACK's downtime-reason catalog.

    # 1. extract (legacy prod, read-only; one JSON document per line)
    psql -At -f db/migrations/t-cpack-reason-catalog/extract-legacy.sql > legacy.jsonl
    # 2. generate the migration (deterministic: same input => byte-identical output)
    scripts/gen-cpack-reason-catalog.py legacy.jsonl > db/migrations/t-cpack-reason-catalog/01-up.sql

What it emits (see the header of the generated file for the full rationale):
  * the legacy per-equipment trees, verbatim, deduplicated into blobs, keyed by the
    equipment's BASE packml topic (the stable cross-DB key; analytics ids are resolved
    at apply time, never baked in);
  * the normalized catalog rows for core.downtime_reason, derived here so they can be
    reviewed as a literal list:
      level 1 (category):    code = category name['en-US']   (e.g. MAN-01, set/02)
      level 2 (subcategory): code = <category code>|<sub name['en-US']>
    label / label_i18n / planned_downtime / change_over / idle = the MODE over every
    occurrence in legacy (ties -> most common, then false / lexicographically first);
    the per-line trees keep their own exact per-line values.
"""
import collections
import hashlib
import json
import sys

ENT = 3  # analytics CPACK
SEP = "|"
DQ = "$cpk$"


def truthy(v):
    """legacy flags are booleans, but `idle` is the string 'yes'/'no'."""
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    return str(v).strip().lower() in ("yes", "true", "1", "y", "t")


def mode(counter, tiebreak):
    return sorted(counter.items(), key=lambda kv: (-kv[1], tiebreak(kv[0])))[0][0]


def lit(s):
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def dq(text):
    assert DQ not in text, "dollar-quote tag collides with data"
    return DQ + text + DQ


def main(path):
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip().startswith("{")]
    rows.sort(key=lambda r: r["topic"])
    topics = [r["topic"] for r in rows]
    assert len(topics) == len(set(topics)), "duplicate base topic in the legacy extract"

    # ── blobs: distinct trees (jsonb-canonical text used only for dedup)
    blobs, blob_of = {}, {}
    for r in rows:
        if r["reasons"] is None:
            continue
        canon = json.dumps(r["reasons"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        h = hashlib.md5(canon.encode()).hexdigest()
        if h not in blobs:
            blobs[h] = (f"b{len(blobs) + 1:02d}", r["reasons"])
        blob_of[r["topic"]] = blobs[h][0]

    # ── normalized catalog: collect every occurrence
    cat_occ = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    sub_occ = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    for r in rows:
        for m in r["reasons"] or []:
            for c in m.get("categories") or []:
                code = (c.get("name") or {}).get("en-US") or c.get("code")
                d = c.get("description") or {}
                o = cat_occ[code]
                o["label"][(d.get("en-US"), d.get("pt-BR"))] += 1
                o["planned"][truthy(c.get("planned_downtime"))] += 1
                o["co"][truthy(c.get("change_over"))] += 1
                o["idle"][truthy(c.get("idle"))] += 1
                for s in c.get("subcategories") or []:
                    sname = (s.get("name") or {}).get("en-US") or s.get("code")
                    sd = s.get("description") or {}
                    so = sub_occ[(code, sname)]
                    so["label"][(sd.get("en-US"), sd.get("pt-BR"))] += 1
                    so["planned"][truthy(s.get("planned_downtime"))] += 1
                    so["co"][truthy(s.get("change_over"))] += 1
                    so["idle"][truthy(s.get("idle"))] += 1

    def resolve(o):
        en, pt = mode(o["label"], lambda k: (str(k[0]), str(k[1])))
        return (en, pt,
                mode(o["planned"], lambda k: k), mode(o["co"], lambda k: k), mode(o["idle"], lambda k: k),
                len(o["label"]) > 1 or len(o["planned"]) > 1 or len(o["co"]) > 1 or len(o["idle"]) > 1)

    cats = [(code,) + resolve(cat_occ[code]) for code in sorted(cat_occ)]
    subs = [(cat, sname) + resolve(sub_occ[(cat, sname)]) for (cat, sname) in sorted(sub_occ)]
    for cat, sname, *_ in subs:
        assert SEP not in cat and SEP not in sname, "separator collides with data"

    out = []
    w = out.append
    n_members_null = sum(1 for r in rows if r["reasons"] is None)
    conflicts = [c[0] for c in cats if c[-1]]
    w(HEADER.format(n_eq=len(rows), n_blob=len(blobs), n_cat=len(cats), n_sub=len(subs),
                    n_null=n_members_null, n_tree=len(rows) - n_members_null,
                    conflicts=", ".join(conflicts) or "none"))

    w("-- ── 2. DATA (generated) ────────────────────────────────────────────────────")
    w("CREATE TEMP TABLE _cpk_blob (k text PRIMARY KEY, j jsonb NOT NULL) ON COMMIT DROP;")
    w("INSERT INTO _cpk_blob (k, j) VALUES")
    items = sorted(blobs.values())
    for i, (k, j) in enumerate(items):
        text = json.dumps(j, ensure_ascii=False, separators=(",", ":"))
        w(f"  ({lit(k)}, {dq(text)}::jsonb){',' if i < len(items) - 1 else ';'}")
    w("")
    w("-- legacy equipment -> tree. topic = BASE packml topic (C-PACK rewritten to CPACK):")
    w("-- the join key to core.packml_register; legacy_id / nm are provenance only.")
    w("CREATE TEMP TABLE _cpk_leg (topic text PRIMARY KEY, legacy_id int NOT NULL, nm text,")
    w("                           tp int NOT NULL, k text REFERENCES _cpk_blob) ON COMMIT DROP;")
    w("INSERT INTO _cpk_leg (topic, legacy_id, nm, tp, k) VALUES")
    for i, r in enumerate(rows):
        w(f"  ({lit(r['topic'])}, {r['legacy_id']}, {lit(r['nm'])}, {r['tp']}, {lit(blob_of.get(r['topic']))})"
          f"{',' if i < len(rows) - 1 else ';'}")
    w("")
    w("-- normalized catalog (level 1 = category, level 2 = subcategory; code rule in header)")
    w("CREATE TEMP TABLE _cpk_cat (reason_level smallint NOT NULL, category text, code text NOT NULL,")
    w("                           label text, label_pt text, planned_downtime boolean NOT NULL,")
    w("                           change_over boolean NOT NULL, idle boolean NOT NULL,")
    w("                           PRIMARY KEY (code)) ON COMMIT DROP;")
    w("INSERT INTO _cpk_cat (reason_level, category, code, label, label_pt, planned_downtime, change_over, idle) VALUES")
    allrows = [(1, None, c[0], c[1], c[2], c[3], c[4], c[5]) for c in cats] + \
              [(2, s[0], s[0] + SEP + s[1], s[2], s[3], s[4], s[5], s[6]) for s in subs]
    for i, (lvl, cat, code, en, pt, pl, co, idle) in enumerate(allrows):
        b = lambda v: "true" if v else "false"
        w(f"  ({lvl}, {lit(cat)}, {lit(code)}, {lit(en)}, {lit(pt)}, {b(pl)}, {b(co)}, {b(idle)})"
          f"{',' if i < len(allrows) - 1 else ';'}")
    w("")
    w(BODY.format(n_eq=len(rows), n_cat=len(cats), n_sub=len(subs), ent=ENT))
    sys.stdout.write("\n".join(out) + "\n")


HEADER = """\
-- t-cpack-reason-catalog / 01-up.sql — port the REAL CPACK downtime-reason catalog from
-- legacy into the analytics DB (id_enterprise = 3 ONLY).
--
-- GENERATED by scripts/gen-cpack-reason-catalog.py from extract-legacy.sql — do not hand-edit;
-- re-extract + regenerate instead. Reverse with rollback.sql (restores the exact prior rows
-- from the ops._bkp_cpack_reason_catalog_* snapshot this file takes in step 1).
--
-- WHY: analytics CPACK carried a generic 18-row English template (EQUIP_FAIL/MECH/…) in all
-- three reason structures, grouped by the WRONG machines (every L-line listed all 28 L*
-- members), while CPACK's events carry the real legacy codes (MAN-01, SET-02, PRG-04, …).
-- Justify/split dialogs therefore offered reasons CPACK never uses, and the codes on the
-- events resolved against nothing in the catalog.
--
-- WHAT (makes analytics == legacy in every structure a consumer reads):
--   core.equipments.downtime_reasons  the legacy tree, VERBATIM, per equipment ({n_eq} equipments:
--                                     {n_tree} carry a tree, {n_null} are NULL exactly as in legacy —
--                                     legacy keeps the tree on the LINE, members have none).
--                                     Shape (legacy/Hasura, read by edge-api, front4, operator):
--                                       [{{code, name{{en-US,pt-BR}}, description{{…}}, position,
--                                         categories:[{{code, name{{en-US}}, description{{…}}, position,
--                                           planned_downtime bool, change_over bool, idle 'yes'|'no',
--                                           subcategories:[{{code, name, description, position,
--                                             planned_downtime, change_over, idle}}]}}]}}]
--                                     The tree embeds NO equipment ids (machine groups are keyed by
--                                     free-text codes: 'Geral - Linha', 'PTH', 'RHM', …), so nothing
--                                     inside it needs remapping; the equipment it lands on is
--                                     remapped legacy -> analytics by BASE packml topic
--                                     (replace(legacy,'C-PACK','CPACK') = core.packml_register.packml_topic).
--   core.downtime_reason              {n_cat} categories + {n_sub} subcategories (replaces the 18 template rows).
--                                     code (level 1) = category name['en-US'] — the value the event
--                                     write path stores in equipment_events.cd_category (NOT the JSON
--                                     `code`, which is a per-line position number: MAN-01 is '1' on one
--                                     line and '2' on another, so it cannot key a per-enterprise dim).
--                                     code (level 2) = '<category code>|<sub name['en-US']>' — a sub name
--                                     repeats under several categories (e.g. under SET-02 and set/02),
--                                     and (id_enterprise, code) is unique WHERE active.
--                                     label/flags = the mode over all legacy occurrences; codes whose
--                                     occurrences disagree (label case/wording or flags): {conflicts}.
--                                     The per-line trees keep each line's exact values — they, not the
--                                     dim, are what the event write path reads flags from.
--   core.equipment_downtime_reason    derived from the NEW trees: one link per (equipment, distinct
--                                     category code) and (equipment, distinct category|sub) — the
--                                     same derivation as the ADR-0039 R5 backfill.
--
-- SAFETY: one transaction; asserts every legacy topic resolves to exactly one ent-3 equipment
-- of the same tp_equipment and that all ent-3 equipments are covered; touches rows of
-- id_enterprise = 3 only (+ the three ops._bkp_* snapshot tables it creates). The sandbox twin
-- (ent 2000003) is NOT touched here; the nightly sandbox-selfheal (ops.sandbox_reflect) re-clones
-- all three structures from ent 3 on its next run.
BEGIN;
SET LOCAL statement_timeout = '5min';
SET LOCAL lock_timeout = '15s';

-- ── 1. SNAPSHOT (what rollback.sql restores, byte-for-byte) ─────────────────
DO $g$ BEGIN
  IF to_regclass('ops._bkp_cpack_reason_catalog_eq') IS NOT NULL THEN
    RAISE EXCEPTION 't-cpack-reason-catalog: snapshot ops._bkp_cpack_reason_catalog_eq already exists — already applied? run rollback.sql or drop the snapshot deliberately first';
  END IF;
  IF (SELECT nm_enterprise FROM core.enterprises WHERE id_enterprise = 3) !~* 'c-?pack' THEN
    RAISE EXCEPTION 't-cpack-reason-catalog: id_enterprise 3 is not CPACK here — refusing';
  END IF;
END $g$;
CREATE TABLE ops._bkp_cpack_reason_catalog_eq AS
  SELECT id_equipment, downtime_reasons, updated_at FROM core.equipments WHERE id_enterprise = 3;
CREATE TABLE ops._bkp_cpack_reason_catalog_dr AS
  SELECT * FROM core.downtime_reason WHERE id_enterprise = 3;
CREATE TABLE ops._bkp_cpack_reason_catalog_edr AS
  SELECT j.* FROM core.equipment_downtime_reason j
    JOIN core.equipments e ON e.id_equipment = j.id_equipment WHERE e.id_enterprise = 3;
COMMENT ON TABLE ops._bkp_cpack_reason_catalog_eq IS
  't-cpack-reason-catalog pre-apply snapshot (rollback.sql source). Drop once the port is accepted.';
"""

BODY = """\
-- ── 3. REMAP legacy equipment -> analytics equipment by base packml topic ────
CREATE TEMP TABLE _cpk_map ON COMMIT DROP AS
SELECT l.topic, l.legacy_id, l.nm, l.tp, l.k, e.id_equipment, e.tp_equipment
  FROM _cpk_leg l
  LEFT JOIN core.packml_register p ON p.packml_topic = l.topic AND p.active AND p.id_enterprise = {ent}
  LEFT JOIN core.equipments e ON e.id_equipment = p.id_equipment AND e.id_enterprise = {ent};
DO $g$ DECLARE bad text; BEGIN
  SELECT string_agg(topic, ', ') INTO bad FROM _cpk_map
   WHERE id_equipment IS NULL OR tp_equipment IS DISTINCT FROM tp;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'unresolved / tp-mismatched legacy topics: %', bad; END IF;
  IF (SELECT count(*) FROM _cpk_map) <> {n_eq}
     OR (SELECT count(DISTINCT id_equipment) FROM _cpk_map) <> {n_eq} THEN
    RAISE EXCEPTION 'topic remap is not 1:1 (% rows, % distinct equipments)',
      (SELECT count(*) FROM _cpk_map), (SELECT count(DISTINCT id_equipment) FROM _cpk_map);
  END IF;
  SELECT string_agg(e.id_equipment || ':' || e.nm_equipment, ', ') INTO bad
    FROM core.equipments e WHERE e.id_enterprise = {ent}
     AND e.id_equipment NOT IN (SELECT id_equipment FROM _cpk_map);
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'ent-{ent} equipments with no legacy counterpart: %', bad; END IF;
END $g$;

-- ── 4. core.equipments.downtime_reasons := the legacy tree (NULL where legacy is NULL)
UPDATE core.equipments e
   SET downtime_reasons = b.j
  FROM _cpk_map m LEFT JOIN _cpk_blob b ON b.k = m.k
 WHERE e.id_equipment = m.id_equipment AND e.id_enterprise = {ent};

-- ── 5. core.downtime_reason: replace the template with the real catalog ─────
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM core.equipment_downtime_reason j
               JOIN core.downtime_reason r ON r.id = j.id_reason
               JOIN core.equipments e ON e.id_equipment = j.id_equipment
              WHERE r.id_enterprise = {ent} AND e.id_enterprise <> {ent}) THEN
    RAISE EXCEPTION 'another enterprise links ent-{ent} reasons — refusing to delete them';
  END IF;
END $g$;
DELETE FROM core.equipment_downtime_reason j USING core.equipments e
 WHERE j.id_equipment = e.id_equipment AND e.id_enterprise = {ent};
DELETE FROM core.downtime_reason WHERE id_enterprise = {ent};

INSERT INTO core.downtime_reason
  (id_enterprise, code, label, label_i18n, category, parent_id, reason_level,
   planned_downtime, change_over, idle, active)
SELECT {ent}, c.code, c.label,
       jsonb_strip_nulls(jsonb_build_object('en-US', c.label, 'pt-BR', c.label_pt)),
       NULL, NULL, 1, c.planned_downtime, c.change_over, c.idle, true
  FROM _cpk_cat c WHERE c.reason_level = 1 ORDER BY c.code;

INSERT INTO core.downtime_reason
  (id_enterprise, code, label, label_i18n, category, parent_id, reason_level,
   planned_downtime, change_over, idle, active)
SELECT {ent}, c.code, c.label,
       jsonb_strip_nulls(jsonb_build_object('en-US', c.label, 'pt-BR', c.label_pt)),
       c.category, p.id, 2, c.planned_downtime, c.change_over, c.idle, true
  FROM _cpk_cat c
  JOIN core.downtime_reason p ON p.id_enterprise = {ent} AND p.active AND p.reason_level = 1 AND p.code = c.category
 WHERE c.reason_level = 2 ORDER BY c.code;

-- ── 6. core.equipment_downtime_reason from the NEW trees ─────────────────────
INSERT INTO core.equipment_downtime_reason (id_equipment, id_reason)
SELECT DISTINCT e.id_equipment, r.id
  FROM core.equipments e
 CROSS JOIN LATERAL (
       SELECT coalesce(c->'name'->>'en-US', c->>'code') AS code
         FROM jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c
       UNION
       SELECT coalesce(c->'name'->>'en-US', c->>'code') || '|' || coalesce(s->'name'->>'en-US', s->>'code')
         FROM jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c,
              jsonb_array_elements(coalesce(c->'subcategories', '[]'::jsonb)) s) codes
  JOIN core.downtime_reason r ON r.id_enterprise = {ent} AND r.active AND r.code = codes.code
 WHERE e.id_enterprise = {ent} AND jsonb_typeof(e.downtime_reasons) = 'array';

-- ── 7. POST-ASSERTS ──────────────────────────────────────────────────────────
DO $g$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM core.downtime_reason WHERE id_enterprise = {ent} AND reason_level = 1;
  IF n <> {n_cat} THEN RAISE EXCEPTION 'expected {n_cat} categories, got %', n; END IF;
  SELECT count(*) INTO n FROM core.downtime_reason WHERE id_enterprise = {ent} AND reason_level = 2;
  IF n <> {n_sub} THEN RAISE EXCEPTION 'expected {n_sub} subcategories, got %', n; END IF;
  -- every category/subcategory in every tree resolves to a catalog row linked to that equipment
  SELECT count(*) INTO n
    FROM core.equipments e, jsonb_array_elements(e.downtime_reasons) m, jsonb_array_elements(m->'categories') c
   WHERE e.id_enterprise = {ent} AND jsonb_typeof(e.downtime_reasons) = 'array'
     AND NOT EXISTS (SELECT 1 FROM core.equipment_downtime_reason j JOIN core.downtime_reason r ON r.id = j.id_reason
                      WHERE j.id_equipment = e.id_equipment AND r.code = coalesce(c->'name'->>'en-US', c->>'code'));
  IF n > 0 THEN RAISE EXCEPTION '% tree categories do not resolve through the junction', n; END IF;
  SELECT count(*) INTO n
    FROM core.equipments e JOIN _cpk_map m USING (id_equipment) LEFT JOIN _cpk_blob b ON b.k = m.k
   WHERE e.downtime_reasons IS DISTINCT FROM b.j;
  IF n > 0 THEN RAISE EXCEPTION '% equipments do not carry their legacy tree', n; END IF;
END $g$;

SELECT 'cpack-reason-catalog' AS step,
       (SELECT count(*) FROM core.equipments WHERE id_enterprise = {ent} AND downtime_reasons IS NOT NULL) AS eq_with_tree,
       (SELECT count(*) FROM core.downtime_reason WHERE id_enterprise = {ent}) AS reasons,
       (SELECT count(*) FROM core.equipment_downtime_reason j JOIN core.equipments e USING (id_equipment)
         WHERE e.id_enterprise = {ent}) AS links;
COMMIT;"""


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
