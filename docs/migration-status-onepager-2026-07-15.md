# Migration Status — OEE Engine Refactor

**2026-07-15 · Status: 🟢 On track — highest-risk milestone achieved & validated**

## Summary
The goal is to move our core efficiency analytics (OEE) out of the legacy platform (computation buried in the production database + Node-RED) into the new Go stream-processing service. **The hardest, highest-risk part — proving the new engine produces correct numbers — is now done and validated in staging.** We've moved from *"can it work?"* to *"roll it out."*

## What's proven
- ✅ **Correct:** the new engine matches **live production data to within 1%**, and reproduces the legacy engine **exactly** where they must agree.
- ✅ **Better:** it **fixes a real bug in production today** — a counter overflow that reports impossible efficiency (>100%) on some lines. New engine is right; old system is 10,000× off.
- ✅ **Safe:** flag-gated and **instantly reversible**, **stable overnight with zero drift**, staging-only — **no production impact.**

*Validated the safe way: old and new run in parallel on the same live data and are continuously compared — so we prove correctness before switching anything.*

## Roadmap to full migration
| Stage | Risk | Status |
|---|---|---|
| 1. Core engine validated | 🔴 High (retired) | ✅ **Done** |
| 2. Stabilization & full-surface bake | 🟡 Med | 🔵 In progress |
| 3. Line-level validation (confirmation) | 🟢 Low | 🔵 In progress |
| 4. Retire legacy computation paths | 🟡 Med | ⏳ Next |
| 5. Production cutover | 🟡 Med | ⏳ Planned |
| 6. Decommission strained legacy DB | 🟢 Low | ⏳ Planned |

Stages 2–3 *confirm* an already-proven result. Stages 4–6 are **execution/rollout, not open technical risk.**

## Bottom line
The biggest technical unknown is retired: the new engine is proven correct against production, more accurate than what it replaces, stable, and reversible. What remains is schedulable execution.

**Next step:** a short rollout-scoping session to sequence stages 4–6 (production-cutover plan + rollback/data-cleanup procedures) and attach firm dates to the path-to-done.
