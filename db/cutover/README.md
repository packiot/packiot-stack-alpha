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

## Not changed (deliberate)

- **Fix 6 — future-dated `equipment_runtime_shift` rows (LOW).** ~11,880 zero-OEE
  rows dated up to 30 days ahead are **intentional** calendar pre-provisioning by
  stream-engine's `internal/rollup/provision.go` ("30-DAY horizon of future
  shift/hour/day buckets"). The rollup later writes OEE *into* these pre-created
  buckets. Deleting them would be futile (recreated next provision cycle) and
  risky (rollup UPSERTs assume the bucket row exists). Left as-is.
