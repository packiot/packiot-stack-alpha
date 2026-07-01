# Data-quality report — `LLLLL` prefix on prod `packml_register` rows

**Reported to Packiot team**: pending (draft for PRODT Jira, do not merge without ticket link)
**Discovered**: 2026-06-29 (session 69, mirror-worker DLQ investigation)
**Severity**: MEDIUM (silent misrouting risk in prod oeecloud pipeline)
**Blast radius**: 4 rows on 1 equipment (equipment_id=84, TEXA on line L3 of CPACK)

## What we saw

While debugging mirror-worker's DLQ backlog, the translator (`services/mirror-worker-go/internal/translate/translate.go`) was returning "no matching staging equipment" for CPACK's equipment 84 (TEXA) — even though the equipment exists on both prod and staging.

Trace:
1. Mirror worker queries prod `packml_register` for equipment 84's `packml_topic`
2. Query returns 7 active rows (unusual — most equipments have 3-5)
3. **4 of the 7 rows have a literal `LLLLL` prefix** on `packml_topic`:

```
id_equipment | packml_topic                                              | active
─────────────┼──────────────────────────────────────────────────────────┼───────
84           | LLLLLCPACK/SC/LINHAS/L3/TEXA/Admin/ProdConsumedCount/80/Unit | t
84           | LLLLLCPACK/SC/LINHAS/L3/TEXA/Admin/ProdProcessedCount/80/Unit | t
84           | LLLLLCPACK/SC/LINHAS/L3/TEXA/Status/StateCurrent          | t
84           | LLLLLCPACK/SC/LINHAS/L3/TEXA                             | t
84           | CPACK/SC/LINHAS/L3/TEXA                                  | t
84           | CPACK/SC/LINHAS/L3/TEXA/Admin/ProdConsumedCount/80/Unit  | t
84           | CPACK/SC/LINHAS/L3/TEXA/Status/StateCurrent              | t
```

The corrupted rows still have `active=true`, meaning oeecloud will USE them for topic routing. If any incoming Sparkplug message ever matches `LLLLLCPACK/SC/…`, oeecloud would route it to equipment 84 correctly. If a bug or copy-paste elsewhere ever produced that literal topic string, it would route silently. That's the misrouting risk.

## What we did on the staging / mirror side

Mirror-worker's translator had an `ORDER BY active DESC NULLS LAST LIMIT 1` that made the tiebreak non-deterministic — picking one of the corrupted rows for topic remapping, then failing to match staging (which doesn't have the `LLLLL` variants).

Fix shipped in **PR #83** (packiot-stack-alpha): added `length(packml_topic) ASC, id_packml_register ASC` as tiebreak, so the canonical short topic wins deterministically. This resolved the mirror-side misrouting.

## What the Packiot team should fix on prod

The underlying data is still corrupt. Recommended cleanup:

```sql
-- Verify first (SELECT-only, safe to run in prod)
SELECT id_packml_register, id_equipment, packml_topic, active, ts_creation
FROM packml_register
WHERE packml_topic LIKE 'LLLLL%'
ORDER BY id_equipment, id_packml_register;

-- Then, ideally in a staging validation pass, deactivate the corrupted rows
UPDATE packml_register
SET active = false
WHERE packml_topic LIKE 'LLLLL%';

-- Or delete outright if history/audit are not needed
-- DELETE FROM packml_register WHERE packml_topic LIKE 'LLLLL%';
```

## Root cause hypothesis

Almost certainly a past copy-paste accident in CS Admin or a manual DB session. The `LLLLL` prefix is exactly 5 uppercase L's — the shape you get if you accidentally paste the same 5-character sequence twice, then edit around it. No known automated process produces this.

If the Packiot team wants us to check similar patterns on other equipments:

```sql
-- Any packml_topic with a repeated-character prefix (letter × 3+)
SELECT id_equipment, packml_topic FROM packml_register
WHERE packml_topic ~ '^([A-Z])\1{2,}'
ORDER BY id_equipment;
```

## Cross-references

- Session 69 discovery narrative — DLQ #316 cascade investigation
- PR #83 (mirror-worker translator ORDER BY fix)
- `sql-non-deterministic-order-by-limit-1` zettel — the mirror-side fix pattern
- `packml_register` schema: `edge-api/schema.sql` in the edge-api repo

## Contact

For questions, reference PR #83's discussion or ping the mirror-worker-go maintainer.
