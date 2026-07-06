# Onboarding — your first week on this stack

> Audience: a new engineer joining the team. Read
> [00-executive-summary](00-executive-summary.md) →
> [01-architecture](01-architecture.md) → this page. Budget: the
> reading below is ~2 hours; the guided tour ~1 day.
>
> Status date: 2026-07-06.

## Day 1 — orient

1. Read the four overview docs (00-04). You now know what exists, why,
   and how it's proven.
2. Skim [`docs/PORTING.md`](../PORTING.md) — the nine-step law every
   legacy-port PR follows. It is enforced in review.
3. Open Grafana → `/d/bake-flow-parity`. This board is the project's
   heartbeat: every panel non-zero has a named cause (§7 of the
   [differences doc](03-prod-vs-new-differences.md)) or it's YOUR
   next investigation.
4. Repo tour:

```
services/
  oeecloud-worker/    THE engine (start at internal/rollup/, then
                      cmd/oeecloud-worker/main.go job wiring)
  edge-transformer/   MQTT ingest, Sparkplug decode, Calc port,
                      triple-emit; cmd/plc-sim = the staging "factory"
  mirror-worker-go/   prod→staging mirroring (POs, events, value-sync
                      with its attributed ledger)
  shadow-mirror/      operator-action replay (POs + runtime windows)
  query-api/          read side (ADR-0015)
docs/
  overview/           you are here
  adr/                every major decision, numbered
  adr/reference/      CAPTURED LEGACY BODIES — the ground truth every
                      port cites (0014-*.sql), wave scripts, the
                      flip runbook
compose.staging.yml   the whole stack, env-flagged per feature
grafana/dashboards/   provisioned boards
```

## Day 2 — the golden rules (each one was paid for)

1. **Prod is SELECT-only. Always.** `BEGIN READ ONLY`, no exceptions.
2. **Never port from a function's name** — capture the dispatcher and
   follow `perform()`. `_test` is production; `f2()` supersedes
   `f()`; monitors log the wrong names.
3. **Behavior parity includes bug parity** — see the amber bugs.
   Fixing prod behavior = a consumer-signed ledger item, never a port
   side effect.
4. **Enterprise/tenant ids are config**, never literals (standing
   directive).
5. **Every destructive cleanup gets ONE precise predicate.** Before
   retiring a transport/queue, list its riders.
6. **Convergence loops measure their own ledger** (attributed rows),
   never a downstream-processed view.
7. **Periodic jobs**: first tick at boot, staggered; every return
   path logs; shared-table writers take advisory locks.
8. git hygiene here: always `git fetch && git checkout -B <branch>
   origin/staging` from the REPO ROOT (cwd bites), commit, push, PR
   with auto-merge. `main`/`master` are never touched.

## Day 3 — hands-on loop (staging)

- **See data flow**: `docker logs stack-plc-sim-1` (NBIRTH/NDATA) →
  `edge-transformer` (triple-emit) → `oeecloud-worker` → check rows:
  `SELECT count(*) FROM shadow_go_port.equipment_values WHERE
  ts_value >= now() - interval '10 minutes'` (expect ≈ F1 ≈ F3).
- **See the engine think**: flag a window
  (`UPDATE ...production_orders_runtime SET recalc_needed = true ...`)
  and watch the next `po-runtime-refresh` tick fill it.
- **Run a parity subject** end-to-end
  ([verification doc §harness](04-verification.md)).
- **Ops crib**: heavy psql goes base64 → `docker cp` → `psql -f`
  (never heredocs without `-i`); SSM output caps at 24KB; long legacy
  runs are detached `nohup`; distroless images have no shell — read
  gauges via logs or Prometheus.

## Week 1 — where decisions live

| Question | Answer lives in |
|---|---|
| Why is X built this way? | `docs/adr/` (numbered; 0010/0011/0012/0014/0016 are the spine) |
| What did the legacy fn actually do? | `docs/adr/reference/*.sql` captures |
| Is this difference intentional? | [03-prod-vs-new-differences](03-prod-vs-new-differences.md) + the ADR-0016 bloat ledger |
| What's the cutover plan? | [`adr/reference/0016-flip-runbook.md`](../adr/reference/0016-flip-runbook.md) |
| What broke before and why? | the project bug journal (260+ entries, root cause + rule each) and the team knowledge vault |
| Who signs off on what? | ADR-0016 gate checklist (PowerBI / sap_13 / c35) |

## The state you're joining (2026-07-06)

Engine: 100% ported, 0/32,848 measured parity, self-verifying.
Awaiting: the 7-day bake window, three human sign-offs, then the
~30-minute flip and the retirement of everything legacy. Your first
contribution will likely be post-flip cleanup (R1–R9) or a bloat-
ledger item — both excellent first PRs.
