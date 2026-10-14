---
title: Test environments, explained
layer: 0
owner_area: platform
last_verified: 2026-10-14
---
# Test environments, explained

> **Learn · for product and management.** One page on where clients run, where we test, and
> what "the sandbox resets" means for demos and QA sign-off. No technical background needed.
> Up: [Learn](index.md) · The full how-to: [Sandbox for testing](../use/sandbox-for-testing.md)

## Three environments

| Environment | What it is for | Who changes data in it |
|---|---|---|
| **Pack4 production** | The real factories. C-PACK and every other client run here today. It is the source of truth for how the product must behave | the factories' operators; **never** tests |
| **CPACK-Staging** | A **read-only mirror** of C-PACK production on the new platform. It shows how the new platform computes C-PACK's real data, so we can compare it with production | nobody: changes are copied in from production, and the apps refuse test writes |
| **SANDBOX-CPACK** | A **copy of CPACK-Staging** that anyone can change. QA, demos, training and automated tests happen here | QA, Customer Success, engineers, automated tests |

"Staging" is the new platform before it serves clients. "Production" in these docs means the
current (Pack4) platform unless a page says otherwise.

## How the copies flow

```text
 Pack4 production (real C-PACK factory)
        │  copied continuously (orders, operator actions, machine counts)
        ▼
 CPACK-Staging ............ read-only mirror: shows real data, refuses test changes
        │  copied continuously, a few seconds behind
        ▼
 SANDBOX-CPACK ............ the test copy: anyone may change anything
        │
        │  someone makes a change ─► sandbox is HELD (copying of operator actions pauses;
        │                            machine counts keep flowing)
        │  4 h after the LAST change (or the nightly tidy-up when nobody is testing)
        ▼
   RESET: the sandbox becomes an exact copy of CPACK-Staging again, then copying resumes
        │
        └──────────────────────────► back to the top of the loop
```

## What "resets" means for you

- **A test state lasts 4 hours after the last change.** Every change (a PO started, a stop
  justified, a box scanned) restarts the 4-hour clock. When nobody has touched it for 4 hours,
  the sandbox resets to CPACK-Staging, usually within 5 minutes.
- **Nothing you did in the sandbox survives a reset**: test orders, justifications, manual
  stops, barcode scans and configuration changes all go. (Sample labels and out-of-service
  windows are the current exceptions.)
- **A nightly tidy-up** at 06:00 UTC (03:00 São Paulo) resets the sandbox when nobody is
  holding it.
- **The sandbox is shared.** One person's changes keep it for everybody; one person's "reset
  now" clears it for everybody.

## Demos and QA sign-off

| Situation | What to do |
|---|---|
| A demo tomorrow that needs a prepared state (POs running, stops justified) | prepare it, then ask for an **extend** long enough to cover the demo (e.g. `24h`). The sandbox will not reset before then |
| A QA sign-off that must be reproducible | write the steps, not the state: after a reset, anyone can repeat them from the same starting point (CPACK-Staging) |
| Evidence for a sign-off | take screenshots or exports **before** the state resets; the sandbox is not an archive |
| Comparing the new platform with production | use CPACK-Staging (read-only), not the sandbox: the sandbox may hold someone's test changes |

## How to request a longer hold

Ask an engineer, or anyone with access to the stack repository on GitHub, to run the
**Sandbox Self-Heal** workflow with the action `extend` and a duration (for example `24h`).
`status` shows whether the sandbox is held and when it will reset. Details and the exact
clicks: [Keep your work longer](../use/sandbox-for-testing.md#keep-your-work-longer-check-the-status-or-reset-now).

## Next

- [Sandbox for testing](../use/sandbox-for-testing.md): addresses, logins, barcode tips, gotchas.
- [Environments](../understand/architecture/environments.md): the technical view of every environment.
