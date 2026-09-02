# Bispharma — STAGING validation runbook (PLC → OEE)

**Goal:** prove that Bispharma's real PLC data flows end-to-end on **staging (F3 =
`packiot_shadow`)** and that **OEE actually computes** for at least one machine/line.
This is the greenfield first-light validation — NOT a prod cutover.

**Scope: STAGING only. No prod writes.** Prod is touched exactly once, SELECT-only,
for the users pull (tenant-prep §2a).

**The sequence (ADR-0045 onboarding loop):** describe → generate → CAPTURE →
validate → (cutover, later). Each step below is gated on the previous.

---

## 0. CRITICAL BLOCKER — read this first

**Nothing in §2 onward can start until Bispharma's actual PLC/edge facts arrive**
(intake §1–§7). Bispharma is a shell tenant with zero topology; the descriptor is
a template full of TODOs. The single highest-priority action is **obtaining the
client facts**. Until then, only §1 (prep that needs no client facts) proceeds.

Companion docs:
- [`bispharma-intake.md`](bispharma-intake.md) — the facts to collect (the blocker).
- [`bispharma.descriptor.yaml`](bispharma.descriptor.yaml) — the SSoT to fill.
- [`bispharma-staging-tenant-prep.md`](bispharma-staging-tenant-prep.md) — ent id + users seed.
- ADR-0045 (P1 descriptor/generator, P2 capture) — landing via #608/#609.
- `docs/ingestion/cpack-tee-golive-runbook.md` — the CPACK worked precedent for the tee/front-door/cutover mechanics.

---

## 1. Prep that needs NO client facts (do now)

- [ ] **Tenant-prep pre-check** — run [`bispharma-staging-tenant-prep.md`](bispharma-staging-tenant-prep.md) §1a, pick the staging enterprise id, reserve the `id_equipment` block.
- [ ] **Users seed prepared** — pull the 65 from prod (SELECT-only) + generate the staging seed SQL, held out of git (tenant-prep §2). Do NOT apply yet.
- [ ] **Client-edge container ready** — the parallel agent's client-edge image built + smoke-tested in isolation (throwaway tenant/broker), able to boot → auth → forward raw tags → `/healthz` green. Pointed at *nothing* until §3.

## 2. DESCRIBE — fill the descriptor (needs client facts)

- [ ] Transcribe every intake §1–§7 fact into [`bispharma.descriptor.yaml`](bispharma.descriptor.yaml): `enterprise_id`, `canonical.prefix`, the real `equipment` tree (lines tp=3, machines tp=1 + `id_unit`), the metric_templates trimmed to the leaves each machine actually emits, and any `mapping` fixups/aliases.
- [ ] Author each machine's `count_index` as **`confidence: inferred`** (a guess) — P2 confirms it.
- [ ] Mark **counters-only** machines (no MachSpeed): drop `/Status/MachSpeed` from their template and record their **rated speed** for `production_speed` at apply.
- [ ] Descriptor validates: `go run ./services/edge-transformer/cmd/onboard-gen --descriptor docs/clients/bispharma.descriptor.yaml` prints artifacts (stderr lists inferred indices — expected, all of them at this point).

## 3. GENERATE — emit the four artifacts

```bash
go run ./services/edge-transformer/cmd/onboard-gen \
  --descriptor docs/clients/bispharma.descriptor.yaml \
  --out gen/bispharma/          # emits profile.yaml, register.sql, agent.yaml, tee-node.json
```

- [ ] Review `bispharma-register.sql` — topics ↔ id_equipment, `active=true`, `id_enterprise=:ENT`.
- [ ] **Do NOT pass `--cutover`** — it refuses while indices are inferred (correct; we're validating, not cutting over).
- [ ] Apply the topology on staging F3: create enterprise/site/area/equipment rows (from the tree) + run `bispharma-register.sql`. Set `production_speed` for counters-only machines and `status_type=4` only for machines with a real state signal (tenant-prep §1).
- [ ] Apply the **users seed** now (tenant-prep §2c) so logins resolve.

## 4. DEPLOY the client-edge — point it at staging ingest

- [ ] Stand up the **client-edge container** (or, if Bispharma runs Node-RED, install the generated `bispharma-tee-node.json` tee after their PLC-read node). It forwards **raw** tags — all raw→canonical normalization happens stack-side in the generated profile (ADR-0045 §2.3 Option B).
- [ ] Point it at the staging **ingest front-door** (the `tee.ingest_url`); USER applies the SG allowlist rule for Bispharma's edge egress IP + the nginx vhost (same mechanic as the CPACK front-door; see cpack-tee-golive-runbook §1).
- [ ] Ingest key wired via `BISPHARMA_INGEST_KEY` env (never hardcoded).
- [ ] Confirm the agent `/healthz` is green and messages are landing: raw tags → internal mosquitto → edge-transformer Calc → F3.

### Pieces that apply to Bispharma (flag per intake)

- [ ] **Rebirth handling.** On (re)connect / NBIRTH, the agent must (re)establish the tagstore snapshot so counts don't appear to reset. Confirm the client-edge/agent emits/consumes Rebirth correctly — a missed Rebirth after a reconnect looks like a counter reset downstream.
- [ ] **Absolute totalizer vs incremental.** Calc expects **absolute totalizers** (plc-sim sims these faithfully, #15). If any Bispharma machine sends **incremental** counts (intake §4), that machine needs the incremental transform + is at risk of the reset/rollover double-count — flag before trusting its OEE.
- [ ] **Sanity-clamp.** Guard against counter rollover / resets / garbage spikes producing impossible deltas (the classic `oee>1.0` / running_time-overflow class — feedback_bug_two_writer_line_double_count, feedback_bug_eventmint). Verify the clamp is active for Bispharma's streams before believing a first OEE number.
- [ ] **Counters-only OEE.** For machines with no MachSpeed, Performance = observed rate / `production_speed` (rated). Sanity-check `production_speed` units match the count unit (intake §6) — a unit mismatch silently corrupts Performance %.

## 5. CAPTURE — confirm the count indices (P2)

The descriptor's indices are guesses. Turn them into facts by observing the live tee.

```bash
# 1. Run the agent with AGENT_UNMAPPED_VERBOSE=true; let a real production window run.
# 2. Snapshot the accepted (mapped) suffixes from the SparkPlug NBIRTH:
mosquitto_sub -h <broker> -t 'spBv1.0/BISPHARMA/NBIRTH/#' -C 1 | jq -r '.metrics[].name' > accepted.txt
# 3. Reconcile observed vs expected, emit a corrected descriptor fragment:
go run ./services/edge-transformer/cmd/onboard-capture \
  --descriptor docs/clients/bispharma.descriptor.yaml \
  --agent-url https://bispharma-agent:9102 --insecure \
  --accepted accepted.txt --only <LINE>          # scope per line/cell
```

- [ ] Paste the emitted fragment back into the descriptor (indices now `confirmed`).
- [ ] Repeat per line until no `inferred` remain. `onboard-capture … --cutover` exits 0 only when the scope is fully confirmed — that's the CI gate for a later real cutover (out of scope for this first validation).

## 6. VALIDATE — does OEE compute?

Confirm data landed and OEE math ran on F3 (`packiot_shadow`), SELECT-only:

- [ ] **Raw arriving:** `equipment_values` has fresh rows for Bispharma equipment ids (recent `ts_value`), and `equipment_events` shows state transitions for `status_type=4` machines.
- [ ] **Current snapshot:** `uns_equipment_current_metrics` shows a recent `last_update` + sane `state`/`speed` for each machine.
- [ ] **OEE computed:** the OEE aggregates populate for a Bispharma machine/line — `equipment_runtime_shift` / `_1hour` rows with `availability`, `performance`, `quality`, `oee` in **[0, 1]** (an `oee > 1.0` means a count double-count or a bad rated speed — do NOT accept it; re-check §4 clamp + counters-only unit).
- [ ] **front4 login resolves:** a seeded Bispharma Firebase user logs into staging front4 and sees their tenant's equipment (proves the users-seed + refdata tenant resolution).

## 7. Done / not-done

**Validation PASSES when:** real Bispharma data flows PLC → client-edge → ingest →
Calc → F3, indices are captured, and at least one machine/line shows OEE ∈ [0,1]
with a seeded user able to see it in front4.

**Explicitly OUT of scope here (later):** prod cutover (`--cutover` gate), full
shift-calendar config, all-machine sign-off, per-SKU speeds. First light first.

---

## Blocker restated

The gate on this entire runbook is **§0: get Bispharma's PLC/edge facts.** With
them, this is a mechanical fill-in-the-blanks. Without them, only §1 moves.
