# Onboarding deep-review (fable-5) — what's fixed, what's deferred

**Date:** 2026-09-01 · **Driver:** bispharma (enterprise 5) UI onboarding · **Constraint:** must never break CPACK (enterprise 3, the protected staging twin fed by the legacy tee).

This is the triage of a thorough, read-only deep-review of the whole generate-from-descriptor onboarding pipeline (csadmin wizard → edge-api → Go generator → shared multi-tenant sparkplug-agent → register/cutover), cross-referenced against `origin/staging` HEAD of all three repos. It records what was **fixed + verified live** on 2026-09-01 and what is **deferred** (with severity + concrete failure scenario), so the remaining work before bispharma go-live is legible.

---

## Fixed + verified live (2026-09-01)

| # | What | Where | Verification |
|---|------|-------|--------------|
| **seam1** | `plc.type` profile generation (ADR-0050) — the generator expands `type × members` into the s7 tag map; no hand-authored `s7_tag_map` needed | onboard-gen (deployed) | POSTed the `plc.type` example descriptor → `validation.cutover_eligible: true, unmapped: []`; a fresh dummy `plc.type` descriptor generated clean end-to-end |
| **A** | `DefaultMetricTemplates` fallback when a wizard descriptor omits `metric_templates` | generator | live; a no-`metric_templates` descriptor synthesizes the full default leaf set |
| **P0-1** | **A bad wizard tenant can no longer crash-loop the shared agent** (see below) | `sparkplug-agent` + generator (#1009) | **proven live**: injected a malformed tenant file next to `cpack.yaml`, force-recreated → agent booted (`restarts=0`), logged `skipping tenant config … co-tenants keep serving`, **CPACK kept ingesting** |
| **seam2 wiring** | `apply-agent-config` (edge-ssm #224) configured: `SSM_SHARED_AGENT_INSTANCE_ID` + `SSM_SHARED_AGENT_DIR` set; app box tagged `managed-by=packiot-edge-api`; IAM `SendCommand` granted | compose (#1010) + IAM policy v4 + ec2.tf codify (#1011) | **proven**: `SendCommand` self-target from the app box's own instance role (= edge-api's identity) returned **ALLOWED** |
| **register #120** | register SQL backfills `id_site`/`id_area` from `equipments` | generator | dummy register apply → all rows carry site/area, 0 orphans |

### P0-1 in detail — the CPACK footgun that was armed

The CS-Admin wizard's `blankDescriptor` carries **no `agent:` block**. The generator emitted an `agent.yaml` with empty `edge_node_id`/`internal_broker`/`uplink_broker`; `apply-agent-config` pushed that file into the shared agent's tenants dir and force-recreated. The agent's `buildTenantPipelines` ran `agentcfg.Load` on every file and **returned an error on the one bad file → `os.Exit(1)` → crash-loop → every co-tenant (including CPACK) lost ingest**. One malformed wizard descriptor = a CPACK outage.

Two-layer fix (both `go test ./...` green, bispharma golden unchanged):
1. **Agent resilience** — `buildTenantPipelines` now skips-and-alarms a bad/duplicate tenant file (Error log + `sparkplug_agent_tenant_load_failed_total` metric) and keeps serving the rest; it only `os.Exit`s on an infra fault (dir unreadable / outbox uncreatable / *no* file loaded).
2. **Generator prevention** — `GenerateAgentConfig` fills empty required agent fields from `DefaultAgentWiring` and runs `agentcfg.Validate` at generate time, so a descriptor that would yield an unloadable `agent.yaml` fails at generate (400) rather than silently on push.

### The IAM gotcha worth remembering

`ssm:SendCommand` to an **EC2** instance authorizes on the resource ARN `arn:aws:ec2:REGION:ACCT:instance/*` — **not** `arn:aws:ssm:REGION:ACCT:instance/*` (that `ssm` namespace is for hybrid `mi-` activations only). The first grant used the `ssm` namespace and silently `AccessDenied`ed. Fixed to the `ec2` namespace + `ssm:resourceTag/managed-by` condition, verified ALLOWED. Codified in `terraform/staging/ec2.tf` (`packiot-staging-app-policy` + the instance tag).

---

## Deferred — prioritized for bispharma go-live

> None of these were armed tonight (seam2 was unconfigured until now, and P0-1 makes the shared agent safe). They are the remaining gaps to a clean UI onboarding.

### P0

- **P0-2 — tenant string is not charset-folded / not enforced == prefix head.** `csadmin descriptor-compose.ts` sets `tenant: enterprise.code || enterprise.name` with no fold; the edge-api DTO is `@IsString` only; the generator checks non-empty only. The tenant becomes the SparkPlug `group_id`, the `<TENANT>_INGEST_KEY` env-var stem (invalid if hyphenated), the tenants filename, and the routing key. Bispharma's code (`BISPHARMA`) happens to be clean, so it works — but "Bispharma Ltda" / "BIS-PHARMA" flows through silently. **Fix:** fold at compose + `@Matches(/^[A-Za-z0-9]+$/)` in the DTO + a generator rule (tenant == first prefix segment).

### HIGH

- **H-1 — bispharma on PROD cannot work as committed.** `compose.production.yml` has no `sparkplug-agent-shared`/`AGENT_TENANTS_DIR`; prod nginx has no ingest front door; `SSM_SHARED_AGENT_COMPOSE_FILE` defaults to `compose.staging.yml`. apply-agent-config on prod would run staging service defs on the prod box or fail `no such service`. **Staging onboarding is unaffected**; this blocks the prod cutover only.
- **H-2 — apply-agent-config status polls the wrong instance (UX).** `commandStatus(idEnterprise, commandId)` resolves the per-enterprise *factory* `mi-` box, but apply-agent-config's command ran on the shared *app* box (`SSM_SHARED_AGENT_INSTANCE_ID`) → `InvocationDoesNotExist` → the UI shows **"InProgress" forever** even though provisioning succeeded. Not data-unsafe. **Fix:** poll with the instance the command actually ran on (add an `agentConfigStatus(commandId)` that targets `sharedAgentInstanceId`).
- **H-3 — capture/observe is unwired for shared-agent tenants.** The multi-tenant capture recorder exists but `AGENT_CAPTURE_ENABLED` / `AGENT_TENANTS_PROFILE_DIR` / a DB DSN are not set in `compose.staging.yml`, and no seam pushes `profile_yaml`. So the capture → confirm-indices → cutover path can't run for a shared tenant; bispharma's count indices must be entered via the raw-JSON hatch pre-marked `confirmed` (works, but bypasses the ADR-0045 gate).
- **H-4 — type-profile expansion emits NET-only counters; gross/scrap absent.** `expandS7TypeEndpoint` emits one `ProdProcessedCount` tag per member; `PLCType.Derive` is parsed but inert, and `stampCounterDerive` only walks the *explicit* `s7_tag_map`. A `plc.type` line will have `oee_q = net/gross` with gross never written (the CPACK-zero-quality archetype). This is ADR-0050's open question (§4) — decide type-level `derive` vs per-member explicit entries before a type-profile client needs correct Quality.

### MED (selected)

- **M-1** ADR-0050 is un-authorable in the wizard — `connections-editor.tsx` only sets `{name, protocol, host_ref}`; no `type`/`line`/`plc.types` editor. The flagship feature is raw-JSON-only in the UI.
- **M-3** Any descriptor upsert (even a PLC-host IP fix) resets `status → draft` and nukes artifacts; the warning lives only on the Review step, not the Connections step.
- **M-4** Nothing validates topic **depth** (resolver truncates to 4-seg line / 5-seg member); a 6-seg member topic silently drops. Add a depth check to descriptor `Validate`.
- **M-5** `tenantFileName` is collision-prone (`"CPACK "` → `cpack.yaml`); a descriptor with `tenant_code: "cpack"` overwrites `tenants/cpack.yaml`. Add an ownership/protected-tenant floor in the edge-ssm slice (the teardown slice already has `[3, 2000003]`).
- **M-6** Teardown (#117) misses telemetry tables (`equipment_events`, `production_orders(_runtime)`, `scanned_boxes`, …) and never removes the tenant agent yaml / stops the reader — a "reset" tenant keeps transmitting. CPACK-safe (id-scoped, protected floor) but incomplete.
- **M-8** Readiness gates miss the two real silent-drop conditions: `packml_register` rows with NULL `id_site`/`id_area`, and descriptor `id_equipment`s absent from `equipments`.

### LOW

- **L-1** New table pagination (`table-pager.tsx`) has zero i18n keys (hard-coded English) inside the ADR-0048 i18n push; `pageSize=Infinity` is a latent NaN with no callers.
- **L-2** `docs/clients/bispharma.descriptor.yaml` says `enterprise_id: 4` (should be 5); committed `tenants/bispharma.yaml` carries `group_id: BISPHARMASTAGING` — a wizard apply will overwrite it with `BISPHARMA` (nginx/SG/key expectations must follow).
- **L-3** One shared `X-Ingest-Key` across tenants (mitigated by per-box SG /32) — design-accepted.

---

## Bottom line for bispharma (staging)

The seams are now **functional and CPACK-safe**: seam1 generates from a `plc.type` descriptor, seam2 provisions the tenant map into the running shared agent, and a bad wizard map is skipped rather than crashing CPACK. The recommended path for the first UI run: author bispharma's descriptor (indices via the raw-JSON hatch pre-marked `confirmed`, per H-3), generate, apply-register, apply-agent-config, cutover — watching that CPACK keeps landing. P0-2 (tenant fold) and H-2 (status poll) are the next polish items; H-1 blocks the eventual **prod** cutover only.
