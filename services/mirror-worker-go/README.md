# mirror-worker-go

**Prod → staging mirror + fidelity watchdog.** Continuously copies
selected production data (real factories, e.g. CPACK) into staging so
the new stack is exercised by real-world shapes, and reconciles the
two sides to catch drift. This is how staging has genuine customer
data without any factory pointing at it.

## How it works

| Package | Role |
|---|---|
| `db` | two pools: **prod is SELECT-only** (`awslambda` role, `BEGIN READ ONLY` discipline) + staging read/write |
| `translate` | the ID-translation layer — prod and staging allocate surrogate ids independently; `mirror_id_map` maps them. Deterministic tiebreaks matter (see the `LLLLL` packml_register audit) |
| `replay` | applies translated mutations to staging |
| `reconcile` | periodic loop (`RunForever`) comparing prod vs staging windows; divergence → DLQ/alert, not silent repair |
| `comparator` | the ADR-0008 fidelity-watchdog pattern |
| `secrets`, `config`, `metrics`, `health`, `log` | plumbing — prod creds from AWS SM `databaseCredentials` (UPPERCASE field names: DB_HOST/DB_USER/…) |

## Invariants (the ones with scars)

- **Prod is SELECT-only, always.** The role does NOT structurally
  prevent writes (it holds INSERT on 316 tables) — `BEGIN READ ONLY`
  wrapping is the guardrail. Never remove it.
- Value-sync guards clamp |delta| > 1e9 — the e38 oscillator was a
  feedback loop through this path; the guard is loss-with-alert, not
  loss-silent.
- Interval-overlap matching (not equality) when comparing derived
  events: same upstream + independent triggers ⇒ structurally
  different downstream rows (prod 4 events vs staging 12 on identical
  input is CORRECT — see `cross-system-trigger-divergence` lessons).
- Translation reads must order deterministically
  (`length(packml_topic), id` tiebreak) — non-deterministic LIMIT 1
  against duplicated prod rows caused real misroutes.

## Post-flip

The mirror continues feeding the ONE consolidated flow (target DB
switches to `packiot_analytics`); the value fan-out collapses to
single-write (`VALUE_FANOUT=false`, R3).
