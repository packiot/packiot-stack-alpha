# adr/reference — the taxonomy

Living documents stay at this level; everything else is filed by kind:

| Where | What | Rule |
|---|---|---|
| **here** | `0016-flip-runbook.md` · `naming-ledger.md` · `0016-endstate-schema-map.md` · `0012-phase4-execution-plan.md` | LIVING — updated as the plan evolves |
| `captures/` | Raw legacy PL/pgSQL bodies, prod view/trigger defs, dispatcher call-lists | IMMUTABLE ground truth. Every port PR cites its capture. Never edit — recapture if prod changes |
| `designs/` | Port designs, inventories, specs (the thinking before the code) | Frozen once the port ships; the code's equivalence header is the living version |
| `migrations/` | SQL actually executed against staging (waves, phases, parity repairs) | As-executed record. Re-runnable only where idempotent — read the header |

Naming: `<adr>-<topic>-<kind>.<ext>` (e.g. `0014-p3b-rollup-1day2-capture.sql`).
