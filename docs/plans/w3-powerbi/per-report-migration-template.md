# Per-Report Migration Worksheet — copy one per report

> Companion to `../w3-powerbi-migration-readiness.md` §3. One filled copy per report.
> A report is "migrated" only when §6 (parity) is green on **two** windows + owner sign-off.

---

## 0. Identity
- Report name: __________
- `reportId`: __________   `dataset id`: __________   workspace: __________
- Owner (biz / tech): __________
- Usage rank: ____   Destination: `front4-native` | `Metabase-curated` | `Metabase-self-service`
- `.pbix` extracted at (private path): __________

## 1. Source (Power Query / M → SQL)
For each table in the model, resolve its M source to a concrete SQL query against Postgres.
| Model table | M source (paste) | Resolves to (SQL / `report_*` table) | Import or DirectQuery |
|---|---|---|---|
|  |  |  |  |

> Most tables likely `SELECT * FROM report_<...>_enterprsie_<ent>`. Note any M-side transforms
> (filters, renames, merges) — they must be moved into the SQL/Metabase model.

## 2. DAX measures → SQL / Metabase metric
Export via DAX Studio / Tabular Editor, then re-express each. **Watch filter context,
`CALCULATE`, time-intelligence, BLANK() handling** — the common semantic-gap sources.
| Measure name | DAX (paste) | SQL / Metabase custom column or metric | Semantic gap noted? |
|---|---|---|---|
|  |  |  |  |

## 3. Model → schema mapping
| PowerBI table | Stack table | Join key(s) | Tenant filter (for RLS/sandbox) |
|---|---|---|---|
|  | `equipment_runtime_shift` / `_1hour` / `equipment_values` / `downtimes` / `production_orders_runtime` / `scanned_boxes` / `report_*` |  | `id_enterprise` / `tenant_id` |

## 4. Visuals → Metabase (rebuild, one row per visual)
| PowerBI visual (page + type) | Metabase equivalent (question/chart type) | No-equivalent? action | Rebuilt? |
|---|---|---|---|
|  |  | nearest / drop / front4-native |  |

## 5. Isolation
- [ ] Tenant filter applied (Metabase sandbox mapping `tenant_id` → row filter).
- [ ] Postgres RLS covers any shared-fact table this report reads.
- [ ] Verified: run as tenant A → **zero** tenant-B rows.

## 6. Parity (the gate) — see §4 harness
- Parity spec file: `../w3-powerbi/parity-specs/<report>.yaml`
- [ ] PowerBI-exported values (DAX Studio) for window 1: __________
- [ ] Postgres ground-truth == PowerBI (within tolerance) for window 1.
- [ ] Metabase question == Postgres (within tolerance) for window 1.
- [ ] All three tie out on window 2 (independent).
- Tolerances used + reason: __________
- [ ] **Owner sign-off** (name + date): __________

## 7. Cutover
- [ ] Metabase report placed in tenant/curated collection.
- [ ] PowerBI report scheduled for decommission (only after sign-off).
