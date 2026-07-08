# C3 — Edge-deployed operator SPA (ADR-0019 G3)

The reward for the wave 1–6 operator rebuild: replacing Incoplast's 556-node bespoke
local UI with *our* operator SPA, deployed at the edge for offline floor operation.
The functionality is already ours — this is a *deployment pattern*, not a new app.

> **Status**: design (2026-07-08). Blocked on [C1](0019-C1-edge-command-channel.md)
> for PLC write-back parity; validates against the live Incoplast tenant post-flip.

## Why almost all the work is already done

The operator SPA became, in [ADR-0018](../../0018-operator-frontend-integration-makeover.md),
a static nginx container whose backends are *proxy targets* — reads to refdata,
writes to edge-api, login to edge-api `/session`. That refactor is what makes edge
deployment a matter of *changing where the proxy points*, not rewriting anything:

| Concern | Cloud deployment (today) | Edge deployment (C3) |
|---------|--------------------------|----------------------|
| static SPA | served from cloud | same container, on the factory box |
| `/api/*`, `/session` | → cloud edge-api | → **factory-local** edge-api |
| `/v1/*` reads | → cloud refdata | → **local** refdata (or a cached read layer) |
| language | `language_packs` (dynamic) | same — `pt-BR` for Incoplast |
| PLC write-back | — (not needed in cloud) | → the **command channel** (C1) |

So the "port their UI" problem dissolves: their *functionality* (PO control, downtime
justification, scrap, shifts) is exactly what our SPA already does, and `operator.mode:
edge` in the descriptor selects this deployment.

## What C3 actually builds

1. **An edge deployment profile** — a Dockerfile/nginx template (extending the existing
   `nginx.staging.conf.template`) whose proxy targets are the factory-local services,
   parameterized by the descriptor. The image is the same SPA build.
2. **Offline tolerance** — the one genuinely new concern. The floor has no reliable
   internet (Incoplast's whole reason for a local UI). This needs:
   - a **local read layer** — a small refdata cache (or refdata itself) on the edge, so
     the operator's reads work without cloud;
   - **write buffering** — operator actions that can't reach the cloud edge-api queue
     locally and forward when connectivity returns (the transformer's outbox pattern,
     applied to operator writes);
   - a **service-worker / offline-aware SPA build** so the screen stays usable through
     a network drop.
3. **The command path** — the PO-setup / parameter screens post to the C1 command
   channel, giving parity with Incoplast's PLC write-back. Without C1, the SPA can
   read and justify but not command — hence the dependency.

## What it retires

Incoplast's entire operator-UI wing — the three versioned `mui_*` UIs (556 nodes,
~52% of their flow), the Firebase-at-the-edge auth, the direct-Hasura reads. Replaced
by: our SPA + edge-api `/session` (bcrypt, factory-local — already built, ADR-0018
wave 2) + local refdata + the command channel.

## Test strategy

Stand the edge profile up against the live Incoplast tenant (Layer A, post-flip):
verify the operator screens work pointed at factory-local backends, that a simulated
network drop keeps reads working and buffers writes, and — with C1 — that a PO-setup
from the screen reaches the (simulated) PLC. The offline behavior is the part that
needs real validation; everything else is the proven cloud SPA with different proxy
targets.
