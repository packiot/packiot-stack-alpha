# Historian cold id-space provenance (sweep R2)

**What this is.** The one-page provenance map for every `id_enterprise` that has a COLD
partition in the S3 historian, making the R1 cross-tenant-leak collision rule *enforceable
by inspection*. The authoritative, machine-readable copy lives in the gateway table
`hist_promoted_enterprise` (`provenance` + `note` columns) — this doc is the human
narrative. Derived live **2026-09-14** from `aws s3 ls .../equipment_values/` ∪
`.../equipment_events*/` cross-referenced with `core.enterprises` / `core.equipments`.

## The rule (R1)

The cold S3 archive is keyed by **raw-legacy** enterprise ids whose numeric values
**collide** with F3 tenant ids. `ev_all` / `ev_all_events` serve cold rows **only** for
ids flagged `ev_promoted` / `ee_promoted` in `hist_promoted_enterprise` (the views INNER
JOIN the allow-list). Therefore:

> **Never assign a NEW F3 tenant an id that appears in `hist_promoted_enterprise`, and
> never set `ev_promoted`/`ee_promoted` on an id without re-running the ownership test**
> (cold DISTINCT `id_equipment` ⊆ `core.equipments(id)` AND `core.equipments(id)` non-empty).

Inspect the blocklist any time with:

```sql
SELECT id_enterprise, provenance, ev_promoted, ee_promoted, note
  FROM hist_promoted_enterprise ORDER BY id_enterprise;
```

## Provenance classes

| Class | Meaning | Served? |
|-------|---------|---------|
| `f3_remapped` | Verified F3 remap — cold `id_equipment` ⊆ `core.equipments(id)`, non-empty. | **Yes** (promoted) |
| `f3_native` | The tenant's OWN recent data archived by the staging append. Promotion pending an ownership verification. | No (yet) |
| `legacy_collision_live_f3` | A **live** F3 tenant id whose cold partition is **raw-legacy** data (NOT that tenant's). The allow-list is what stops this leaking **today**. | No (correctly denied) |
| `legacy_passthrough` | Raw-legacy cold, **no live F3 tenant** yet. The future-assignment blocklist. | No |

## The map (cold-partition ids, 2026-09-14)

| id | name (core.enterprises) | provenance | ev | ee | notes |
|----|-------------------------|-----------|----|----|-------|
| 3 | CPACK-Staging (62 eq) | `f3_remapped` | ✅ | ✅ | legacy 1→F3 3; cold EV/EE {47..108} == core.equipments(3) |
| 4 | Incoplast-Staging (4 eq) | `f3_remapped` | ✅ | ❌ | legacy 33→F3 4; cold EV {990015..990018}. EE still legacy-33 (un-remapped) |
| 5 | Bispharma-Staging (128 eq) | `f3_native` | ❌ | ❌ | F3-native EV cold from the append (HIST_ENTS "3 5"); promotion pending |
| 2 | Simulator Corp (3 eq) | `legacy_collision_live_f3` | ❌ | ❌ | cold EV {160..184} ⊄ core.equipments(2)={3,4,5} — raw-legacy collision |
| 1000000 | PACKIOT-ADMIN (0 eq) | `legacy_collision_live_f3` | ❌ | ❌ | cold EV {111..113} vs ∅ — raw-legacy |
| 6 | (MONTEBELLO draft, 0 eq) | `legacy_passthrough` | ❌ | ❌ | cold EV {134..852} raw-legacy; core.equipments(6)=∅ |
| 13 | (NEOPAC draft, 0 eq) | `legacy_passthrough` | ❌ | ❌ | cold EV {0..865} raw-legacy; core.equipments(13)=∅ |
| 0, 10, 30, 31, 33, 35, 36, 37, 38, 99, 100, 101, 102, 111, 112, 113, 116, 117, 118, 10016 | — (no live F3 tenant) | `legacy_passthrough` | ❌ | ❌ | raw-legacy cold; safe to leave un-served, dangerous to reassign |

`33` is EE-only cold (Incoplast's legacy id — its EE partition is not yet re-unloaded to
F3 4, which is why ent 4 is `ev`-promoted but not `ee`-promoted).

## Why materialized, not derived

The allow-list is a **deliberately materialized, audited list**, not an auto-recomputed
query — a misfiring derivation must not be able to silently re-open the leak. Extend it
ONLY through a verified promotion (`scripts/historian-events-reunload.sh` for EE), which
also moves the partition and re-seeds the cutover boundary.
