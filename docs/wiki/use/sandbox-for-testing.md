---
title: Sandbox for testing
layer: guide
owner_area: platform
last_verified: 2026-10-14
---
# Sandbox for testing

> **Use Packiot · how-to.** The one guide to testing on staging without breaking anything: which
> addresses and logins to use, what the sandbox is, when it resets, and how to keep your test
> state longer. For QA and testers first; engineers and product people have short entry
> points below. Up: [Use Packiot](index.md)

| You are… | Read |
|---|---|
| **QA / tester** | this page, top to bottom |
| **Product or management** (demos, sign-off) | [Test environments, explained](../learn/test-environments.md) first, then [The reset rule](#the-reset-rule) |
| **Engineer** (E2E tests, the heal, SQL) | [Sandbox twin (engineering)](../understand/components/sandbox-twin.md) |

## What the sandbox is

The **sandbox** (its name in the apps is **SANDBOX-CPACK**, enterprise number `2000003`) is a
**copy of CPACK-Staging**. It has the same lines, machines, shifts, stop reasons, production
orders (POs) and live machine counts as CPACK-Staging, a few seconds behind it.

You can change anything in it: start and stop POs, justify or split stops, add manual stops,
scan boxes, print sample labels, edit areas and machines. Afterwards it **resets itself**: it
throws your changes away and becomes a copy of CPACK-Staging again.

There are three environments, and only one of them is for your test writes:

| Environment | What it is | Can you change things? |
|---|---|---|
| **Pack4 production** | the real factories (C-PACK and other clients) | no, never test here |
| **CPACK-Staging** (enterprise 3) | a **read-only mirror** of C-PACK production on the new platform | no: the Operator refuses PO, stop and shift changes with the error `MIRROR_TENANT_WRITE_BLOCKED` |
| **SANDBOX-CPACK** (enterprise 2000003) | a resettable **copy of CPACK-Staging** | **yes**: this is where you test |

## Which address to use

| App | Address | Shows |
|---|---|---|
| Operator (tablet app) | **`https://operator-sbx.staging.packiot.app`** | the sandbox. Test PO and stop changes here |
| Operator | `https://operator.staging.packiot.app` | CPACK-Staging: **read-only**. Use it to compare, never to test a change |
| Barcode app | **`https://barcode.staging.packiot.app`** | the sandbox (it always writes to the sandbox) |
| front4 (dashboards) | `https://front.staging.packiot.app` (or `https://staging.packiot.com`) | log in with the sandbox QA user, or use the enterprise switcher (super-admin accounts only) and pick **SANDBOX-CPACK** |
| CS Admin, Customize | `https://csadmin.staging.packiot.app`, `https://customize.staging.packiot.app` | pick **SANDBOX-CPACK** in the enterprise list |

!!! tip "Use `front.staging.packiot.app` for reports"
    On `staging.packiot.com` the embedded Superset reports can fail with a CSRF error
    (a browser cookie rule). `front.staging.packiot.app` does not have that problem.

## Which login to use

Shared QA accounts exist for staging. **Passwords are never written in docs or chat**: they
are in AWS Secrets Manager under `packiot/staging/e2e-test-creds`. If you cannot read it, ask
an engineer on the platform team to give you the password or create a personal login.

| Login | Lands on | Use it for |
|---|---|---|
| `qa-sandbox-staging@packiot.com` | SANDBOX-CPACK | Operator on `operator-sbx`, front4 on the sandbox |
| `qa-cpack-staging@packiot.com` | CPACK-Staging | read-only checks on `operator.staging` and front4 |
| `qa-csadmin-staging@packiot.com` | CS Admin team (all enterprises) | CS Admin and Customize |
| `qa-bispharma-staging@packiot.com` | Bispharma | Bispharma demos (a real client box; read-only habits apply) |

The barcode app has no login of its own: the staff sign-in page in front of it (any account
in the CS Admin group) is the gate, and every scan goes to the sandbox.

## The reset rule

!!! warning "The reset rule"
    1. Your **first change** in the sandbox puts it **on hold**. A change is any write: a PO
       action, a justification or split, a manual stop, a **barcode scan**, a **sample label**,
       a configuration edit. Just looking at pages does not count.
    2. While it is held, nothing resets it, and CPACK-Staging's own operator actions stop being
       copied in, so nobody overwrites your work. Live machine counts **keep flowing**, so a PO
       you start collects real production.
    3. **Every change moves the deadline.** The hold lasts for the **grace period, 4 hours by
       default, after the LAST change** anyone made in the sandbox.
    4. When the grace period runs out, the sandbox **resets** (we also call it a *heal*)
       within about 5 minutes: everything goes back to CPACK-Staging, **barcode scans
       included**, and live copying from CPACK-Staging starts again.
    5. There is also a **nightly tidy-up reset at 06:00 UTC** (03:00 in São Paulo). It is
       skipped while the sandbox is held; the held session resets when its own grace period
       ends. GitHub can start this nightly job late.

The sandbox is **shared**. Someone else's change also holds it (and moves the deadline for
everyone); someone else's "reset now" also wipes your work. Check the status before a long
test and tell the team if you hold it overnight.

### What you will see after a reset

| Thing | After the reset |
|---|---|
| POs | back to exactly what CPACK-Staging has: same numbers, same status, same running PO per line. POs you created are gone |
| Stops | your justifications and splits of the last 14 days are undone; manual stops you added are gone |
| Configuration | areas, machines, shifts, targets and stop reasons are CPACK-Staging's again; anything you created is gone |
| Barcode | all box scans and box counts are gone, so **label numbering starts again at 1** for every PO |
| Logins | the QA logins keep working (they are not reset) |
| Live counts and history | untouched: they are a copy of CPACK-Staging's anyway |

!!! note "Not reset today"
    **Sample labels** (the sample total and printed sample labels) and **out-of-service
    windows** are not part of the reset yet; they stay until someone deletes them. Do not rely
    on them being empty after a reset.

## Keep your work longer, check the status, or reset now

Use the **Sandbox Self-Heal** workflow on GitHub: repository `packiot/packiot-stack-alpha` →
**Actions** → **Sandbox Self-Heal** → **Run workflow**, then pick an action.

| I want to… | action | duration |
|---|---|---|
| see if it is held, the last change, and when it will reset | `status` | (ignored) |
| keep my state for longer (e.g. a demo tomorrow morning) | `extend` | how long from now, e.g. `8h`, `90m`, `2d` |
| I'm done: reset it now | `heal-now` | (ignored) |

`status` prints lines like `held: true`, `last change: … at 2026-10-14 13:05 UTC`,
`grace: 04:00:00`, `heal due at: 2026-10-14 17:05 UTC` and `last heal: …`. Open the run and
the step "Sandbox session action" to read them.

`extend 8h` keeps the sandbox for **at least** 8 hours from now. Later changes can only push
the deadline further, never shorten it. The extension ends at the next reset.

!!! info "You need access to run it"
    Running a workflow needs **write access** to the `packiot/packiot-stack-alpha` GitHub
    repository. If you do not have it, ask an engineer on the platform team to run the action
    for you, or to grant access. Engineers can also run it from a terminal:
    `gh workflow run sandbox-selfheal.yml -R packiot/packiot-stack-alpha -f action=extend -f duration=8h`.

There is a fourth action, `grace`, which changes the 4-hour grace period **for everyone,
permanently**. Leave it to engineers, and set it back to `4h` afterwards.

## Barcode testing tips

The barcode app on `barcode.staging.packiot.app` always works on the sandbox.

| What | How it behaves |
|---|---|
| Label format | a box label reads `op;N;qty` (the PO number, the label number, units per box). A Brazilian keyboard may send `ç` instead of `;`; both work |
| The PO must match | the `op` part must be the PO **running on the line you picked**, or the app says `OP inválida` |
| Label 0 | the starter label. Reading it records **nothing** and prints label 1 |
| Reading label N | records box N and prints label N+1 for the next box |
| Duplicate | reading a label already recorded: `Etiqueta N já foi lida (…). Nada foi impresso.` Nothing is counted or printed |
| Gap | reading a number that is not the next one: `Sequência inválida. Esperado X, lido Y.` |
| Sample labels | print as `op;A<N>;qty` (A = *amostra*). Read into the box input they are refused with `Etiqueta de amostra — não é caixa`; samples never count as production |
| Blank label fields | the sandbox's POs are copies of CPACK-Staging's, which carry no label data (the PO's `custom_field` is empty), so product, order number and box quantity print blank. That is the data, not a bug |
| After a reset | numbering starts again at 1 for every PO: scan label 0 (prints 1) or start from label 1 |

These behaviours are from the barcode app's `staging` branch of 2026-10-14. If the screen
shows something different, the deployed build may be older; tell an engineer.

## Known gotchas

| You see | Why | What to do |
|---|---|---|
| `MIRROR_TENANT_WRITE_BLOCKED` (403) in the Operator | you are on `operator.staging`, which is CPACK-Staging (read-only) | use `operator-sbx.staging.packiot.app` |
| Your POs, scans or justifications disappeared | the sandbox reset (grace period over, nightly, or someone ran `heal-now`) | run `status` to see `last heal`; use `extend` next time |
| The sandbox does not reset although you are done | someone (or an automated test) made a change later, which moved the deadline | run `status`; `heal-now` if everyone is done |
| CPACK-Staging shows a new PO or stop that the sandbox does not | the sandbox is held, so CPACK-Staging's operator actions are not copied in | expected; they arrive after the reset |
| Label number refused with `Sequência inválida` right after a reset | the counter restarted at 1 | read label 0 or label 1 |
| The Operator shows no running PO on a line where CPACK-Staging has one | CPACK-Staging had a running PO without an open run; the reset opens one where the line is free, otherwise it pauses the PO | pick or start a PO; tell an engineer if it repeats |
| An automated test run stopped saying the sandbox is held | the test suite refuses to wipe a held sandbox | expected: it protects your session |
| Customize "Apply now" says "Test client — nothing was restarted" | sandbox box actions are simulated | expected |

## Next

- [Test environments, explained](../learn/test-environments.md): the picture for product and management.
- [Sandbox twin (engineering)](../understand/components/sandbox-twin.md): how the copy and reset work.
- [Onboard a client end to end](../learn/onboard-a-client-end-to-end.md): a full tutorial on the sandbox.
- [Glossary](../reference/glossary.md): sandbox, mirror tenant, grace period.
