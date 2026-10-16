# ADR-0051 — `packml_register` is a Generated Routing Table (Cloud-Side, Late-Binding), and Unroutable Topics Must Alert

**Status:** Proposed · **Date:** 2026-08-27 · **Scope:** the role of `packml_register` in the telemetry path — whether topic→`id_equipment` routing belongs at the edge or in the cloud, how the table is authored, and how a missing/inactive routing row is surfaced · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** companion to [ADR-0045](0045-client-onboarding-architecture.md) (onboarding generates the edge + register) and [ADR-0047](0047-per-client-configuration-architecture.md) (config-as-data). This ADR settles a recurring "why do we even need packml?" question and turns the layer's one bad failure mode (silent drop) into a signal.

## 1. Context

### 1.1 The question
`packml_register` maps a SparkPlug **topic string** (e.g. `CPACK/SC/LINHAS/L5/BREYER/…`) to a cloud `id_equipment`. The factory publishes *topics*, never database identity. A fair recurring challenge: *"Couldn't the edge (Node-RED / the agent) just stamp `id_equipment` directly and let us delete the whole cloud-side routing table? It feels like overcomplication."*

### 1.2 The real code path (deployed truth, traced 2026-08-27)
- **Wire key formed at the edge** — `edge-transformer/internal/s7/mapping.go:46`: the SparkPlug metric name is `packml_topic + suffix`. Pure string, zero DB identity.
- **Lookup in the cloud worker** — `…/sparkplug/resolver.go:118`: `SELECT … id_equipment … FROM packml_register WHERE packml_topic = $1 AND active = true LIMIT 1`. An **inactive** row is indistinguishable from a **missing** one.
- **The silent drop** — `…/writers/equipment_values.go:218` (`info==nil`) + `…/handlers/sparkplug.go:276` (`q==nil → continue`): no row ⇒ the sample is **acked, not retried, and logged only 1-in-32** ⇒ `equipment_values` is silently empty with green pipelines and green acks.
- **The write** — `equipment_values.go:425`: the resolved `id_equipment` (+ enterprise/site/area) is what gets INSERTed.
- **Generation** — `edge-transformer/.../clientdescriptor/generate.go:171` → edge-api `apply-register.service.ts`: onboard-gen already **emits** `INSERT INTO packml_register (… active=true …)` from the descriptor.

**Codification gap noted:** the resolver/writer Go tree (`oeecloud-worker` / `stream-engine`) is currently on feature branches, not `origin/staging` — tracked separately.

### 1.3 Two translations are being conflated
1. **Client PLC tags → canonical SparkPlug topic** — *protocol translation*, genuinely client-specific, correctly an **edge** concern (the reader/agent/descriptor do this).
2. **Canonical topic → `id_equipment`** — *identity resolution / routing*, i.e. `packml_register`. This is the piece proposed for deletion.

## 2. Decision

**Keep topic→`id_equipment` routing in the cloud (late binding). `packml_register` is a GENERATED, cloud-side routing table — never hand-authored — and its CS-Admin surface is read-only inspection plus the `active` lifecycle. Unroutable topics MUST raise a signal (metric + alert), not silently drop.** Proposed — pending USER sign-off.

### 2.1 Why routing stays cloud-side (late binding), not edge-stamped
- **Factory deploys are expensive (the whole ADR-0045/0049 problem).** With cloud-side routing, re-orging the hierarchy, splitting a line, fixing a mis-map, or re-onboarding a tenant (F1→F3, the +2M sandbox offset) is an `UPDATE` in the cloud — the factory keeps publishing the same topics, **no edge redeploy**. Edge-stamped ids make *every* identity change a trip to the box.
- **Stable physical name vs mutable surrogate key.** The topic mirrors PLC wiring (stable); `id_equipment` is a cloud surrogate key that changes often. Bind the mutable thing where the mutation happens (cloud), keyed on the stable thing (topic). A stale edge stamping a wrong id → **silent misattribution** (worse than a drop).
- **Single source of truth for identity.** The edge knows topics; the cloud owns ids. Edge-stamping creates two sources of truth to keep in sync — the exact class of bug behind the counter-role column collision.
- **`active` is a cloud control-plane knob** (gate a topic during onboarding without touching the factory). Edge-stamping loses it.
- **SparkPlug on the wire keeps ingest standard + multi-consumer** (worker, historian, debug tap each resolve identity as needed).

### 2.2 Why it still felt overcomplicated — and what we actually simplify
The friction is real; it just isn't the routing table:
- **No hand-authoring.** `packml_register` is emitted by onboard-gen from the descriptor. CS-Admin's packml view is **inspection + the `active` toggle**, never a data-entry form. (Onboarding remains the only writer of routing rows, via `apply-register`.)
- **No silent drop.** Make an unroutable/inactive topic **loud** (§2.3) so a missing row screams instead of zeroing OEE.
- **No overloaded columns.** Already handled by ADR-0047 Option A (honest column semantics + dead-column GC).

### 2.3 Unroutable topics must alert
Add a Prometheus counter at the resolver's skip branch (`packml_unresolved_topic_total`, labelled by **tenant** — not full topic, for cardinality), and a Prometheus alert `PackmlUnroutableTopic` firing when `rate(...[10m]) > 0` sustained ~10–15m. Keep the existing sampled log (with the full topic) for the drill-down. This is the *packml-layer* sibling of the existing broker-layer `oee-unroutable` alert (a non-allowlisted tenant → no queue). Metric-only; the skip logic (skip-not-nack) is unchanged.

## 3. Consequences
- CS-Admin: the packml surface becomes read-only + `active` lifecycle; remove any hand-create/edit affordance for topics (onboarding owns creation).
- Observability: a missing/inactive routing row now pages instead of silently emptying `equipment_values` — directly attacks the failure mode behind past incidents (F3 empty tenants, CPACK zero line counts).
- No wire/protocol change; no edge redeploy; SparkPlug stays the ingest contract.
- Follow-up: close the codification gap (get the resolver/writer service onto `origin/staging`).

## 4. Rejected alternative — edge-stamped `id_equipment` (delete `packml_register`)
Rejected: it makes every identity remap a factory deploy, turns a stale edge into silent cross-machine corruption, and splits identity ownership across edge+cloud. The simplification it promises is achieved instead by "generated-only + loud + un-overloaded," which keeps the operational safety.

## References
- Trace: `…/sparkplug/resolver.go:118`, `…/writers/equipment_values.go:218,425`, `…/handlers/sparkplug.go:276`, `edge-transformer/internal/s7/mapping.go:46`, `…/clientdescriptor/generate.go:171`, `edge-api/src/usecases/onboarding/apply-register/apply-register.service.ts`, `edge-api/migrations/20260512000001_create_packml_register.ts`.
- [ADR-0045](0045-client-onboarding-architecture.md) (onboarding generates edge + register) · [ADR-0047](0047-per-client-configuration-architecture.md) (config-as-data; Option A column GC).
- `memory/feedback_bug_eem_forced_flag_not_pollution.md` and the counterroles collision — prior "same name, two meanings / silent drop" incidents this decision guards against.
