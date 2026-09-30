# Sandbox twin (SANDBOX-CPACK, ent 2000003): test anything, it self-heals

The sandbox is a **live copy of CPACK staging**: same lines, machines, shifts, reasons,
targets, POs, events, justifications and live counters. You can change anything in it,
and it puts itself back afterwards.

| | URL |
|---|---|
| Operator (sandbox) | https://operator-sbx.staging.packiot.app (user `qa-sandbox-staging@packiot.com`) |
| csadmin / customize | pick **SANDBOX-CPACK** in the enterprise list |
| front4 | super-admin switcher → SANDBOX-CPACK |

## How a session works

1. **Just start working.** Start/stop/change POs, justify or split stops, add manual
   events, edit areas/equipment/reasons/targets… Your **first change** puts the sandbox
   **on hold**:
   - CPACK's own operator actions stop being copied into the sandbox, so nothing
     overrides you (live **counters keep flowing**: a PO you start collects real
     production);
   - nothing resets it: the nightly clean-up, the E2E suite and `--heal` all refuse.
2. **Every change pushes the deadline.** The sandbox resets **4 hours after your last
   change** (the grace period).
3. **When the grace period ends** (checked every 5 min), it resets itself: config, POs,
   events, justifications and manual events become CPACK staging again, the hold is
   released, and CPACK's actions are copied in live again.

Only changes count. Looking at pages (lists, reads, reports) does not hold or extend
anything.

## Controls

GitHub → Actions → **Sandbox Self-Heal** → *Run workflow*, or the CLI (from a
workstation with AWS access):

| I want to… | GitHub action | CLI |
|---|---|---|
| see if it's held and when it resets | `status` | `scripts/sandbox-session.sh status` |
| keep my changes longer (at least 8 h from now) | `extend` + `8h` | `scripts/sandbox-session.sh extend 8h` |
| change the grace period | `grace` + `2h` | `scripts/sandbox-session.sh grace 2h` |
| I'm done, reset now | `heal-now` | `scripts/sandbox-session.sh heal-now` |

## What is reset, and what isn't

| Reset to CPACK staging | Not touched |
|---|---|
| enterprise config: sites, areas, equipments, packml topics, shifts, shift hours, targets, reasons | QA test users (`qa-*`) and the sandbox api key |
| all POs + their runtime windows | the live telemetry stream (always mirrored) |
| events of the last 14 days (justifications, splits), all manual events | older OEE history (it's the sandbox's own copy of CPACK's) |

## Under the hood (for engineers)

- A change is an `identity.user_logs` row for ent 2000003 whose category is not a read
  (`ops.sandbox_is_change`). Hold state: `ops.sandbox_hold_status`. Grace and state:
  `ops.sandbox_state`. Migration: `db/migrations/t-sandbox-grace-hold`.
- `legacy-replicator-sbx` runs with `SANDBOX_HOLD_ENABLED=true`. While held it advances
  its cursor without applying, and its PO / manual-event reconcilers and DLQ retrier
  skip (`services/analytics-sync/internal/replicate/hold.go`). If the hold check fails
  it fails open (keeps replicating).
- The heal is `provision-sandbox-tenant.sh --heal`: config clone plus
  `ops.sandbox_reflect(3, 2000003, …)`. It is guarded by `ops.sandbox_heal_begin`
  (refuses while held and not due, unless `SANDBOX_HEAL_FORCE=1`) and recorded by
  `ops.sandbox_heal_end`.
- Timer: `sandbox-grace-heal.timer` on the app box → `/opt/packiot/sandbox/sandbox-session.sh tick`.
  It is installed and refreshed by the Sandbox Self-Heal workflow (`scripts/install-sandbox-grace-heal.sh`).
  Logs: `journalctl -u sandbox-grace-heal.service`.
- The mutating E2E suite (`npm run test:sandbox`) heals first. While someone holds the
  sandbox, that heal refuses and the suite stops rather than wiping their session. After
  an E2E run, `heal-now` releases the hold instead of waiting 4 h.
