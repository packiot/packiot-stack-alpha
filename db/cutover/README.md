# db/cutover — F3 (`packiot_analytics`) forward-only cutover fixes

Idempotent, hand-verified SQL applied to the live staging F3 database
(`packiot_analytics`) to fix confirmed data + schema defects surfaced during the
F1→F3 cutover. Each file was dry-run (`BEGIN … ROLLBACK`) with before/after
counts, then applied for real. They run *after* `db/init-f3` (snapshot/manifest)
and are safe to re-run.

| File | Fix | What it does |
|------|-----|--------------|
| `f3-capture-observations.sql` | 1 (HIGH) | Creates the missing `capture_observations` table so the onboarding Capture DQ report stops 500ing. Mirrors `db/init/04-capture-observations.sql`. |
| `f3-shift-hours-dedup.sql` | 2 (MED) | Dedups `shift_hours` (882→252, removed 630 byte-identical dups) and replaces the NULL-defeated `shift_hours_un` unique constraint with a NULL-safe unique index on `COALESCE(id_equipment,0)` so re-seeding can no longer accumulate duplicates. |
| `f3-legacy-replicator-cpack-staging-pollutants.sql` | 3 (MED) | Deletes the 5 malformed `CPACK_STAGING/SC/CELULAn//` packml_register rows (id_equipment set) that hijacked the legacy resolver's shortest-topic selection, causing HOTMADAG(99)/FLEXO(557)/POLYTYPE1(110)/SLEEVE1(763) downtimes to be dropped. **Requires a `legacy-replicator` restart** (resolver map is cached at startup). |
| `f3-drop-dead-functions.sql` | 4 (LOW) | Drops 3 dead, permanently-erroring `h_piot_*` functions not in the read-api contract (which uses the `_uns` variants). `db/init-f3/MANIFEST.f3-target` is updated in the same PR to keep the parity gate green. |
| `f3-packml-register-hygiene.sql` | 5 (LOW) | Deletes the 12 remaining id_equipment-NULL `CPACK_STAGING` hierarchy junk rows. (There were **0** classic orphan rows — the task's "13 inactive orphans" do not exist on live F3.) Legit `CPACK/` hierarchy topics are left intact. |
| `f3-phasec-history-backfill.sql` | Phase-C (deferred deep history) | Backfills CPACK ent-3 **pre-cutover deep history** the F1→F3 cutover deferred, copying from F1 `packiot` ent-3 over `dblink` in one transaction: **43 production_orders** + their **43 production_orders_runtime**, **197,011 equipment_events** (deep-history downtimes with irreplaceable operator reasons/notes), **28,480 user_logs**, **7,626 equipment_runtime_shift** rows. **Business-key-aware, not PK-naive:** F1/F3 hold the same POs under divergent `id_production_order` PKs but a stable `(id_enterprise, id_order)` key — POs are matched/deduped on that key and re-minted with a fresh F3 identity PK; `production_orders_runtime.id_production_order` is remapped to the fresh PK via `id_order`. Events/shift key on their natural composite PK. OEE ratio cols are NULL-preserving-clamped to `[0,1]` (F1 has measurement artifacts >1 that violate F3's CHECK); history loaded `recalc_needed=false` so the live worker recompute loop is never triggered. The shift grain is the gate that makes deep-history downtimes **surface in `v_report_downtimes` with their `op`** — op-populated ent-3 rows went **408 → 2,916**. Idempotent (`ON CONFLICT`), fenced strictly before the per-grain cutover instant. Companion `f3-phasec-history-backfill.reverse.sql` deletes exactly the backfilled slice (ent-3-scoped, fenced to windows empty before the backfill) to return to baseline. |

## Not changed (deliberate)

- **Fix 6 — future-dated `equipment_runtime_shift` rows (LOW).** ~11,880 zero-OEE
  rows dated up to 30 days ahead are **intentional** calendar pre-provisioning by
  stream-engine's `internal/rollup/provision.go` ("30-DAY horizon of future
  shift/hour/day buckets"). The rollup later writes OEE *into* these pre-created
  buckets. Deleting them would be futile (recreated next provision cycle) and
  risky (rollup UPSERTs assume the bucket row exists). Left as-is.
