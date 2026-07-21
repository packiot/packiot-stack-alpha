# Direct-from-PLC ingestion — CPACK + Incoplast → staging F3

**ADR-0032 "direct from the PLC" realization.** These are the ready-to-install
artifacts that let CPACK's and Incoplast's REAL factory Node-RED send live PLC
SparkPlug data into the staging stack, landing in **F3 (`packiot_shadow`)** via
the same `oee`-exchange → `oeecloud-worker` pipe. **Scope: STAGING only.** No prod
writes. We do **not** edit the customers' Node-RED — the USER installs the nodes
below; everything here is copy-paste ready.

> **Companion (already on this machine):** `~/incoplast-ingest/` holds the earlier
> Incoplast tee setup + the self-signed CA (`ca.crt`). The Incoplast artifact here
> is the same endpoint, hardened to read the key from an env var. Reuse the CA
> from that folder.

---

## 0. TL;DR — what to install where

| Tenant | Node-RED artifact | Cloud endpoint | Scope group | Lands in |
|--------|-------------------|----------------|-------------|----------|
| **Incoplast** (ent 4) | `incoplast-tee-node.json` / `incoplast-tee-function.js` | `…:8444/ingest/sparkplug` (existing `ingest-shim`) | `INCOPLAST` → `sparkplug.data.incoplast` | `oeecloud-worker-q-incoplast` → F3 |
| **CPACK** (ent 3) | `cpack-tee-node.json` / `cpack-tee-function.js` | `…:8446/ingest/sparkplug` (**new** `ingest-shim-cpack`) | `CPACK` → `sparkplug.data.cpack` | `oeecloud-worker-q-cpack` → F3 |

The cloud change (the new `ingest-shim-cpack` instance) is the PR on branch
`feat/task54-adr0032-cpack-ingest-shim` → **staging** (see §4). Incoplast's cloud
path is **byte-unchanged**.

---

## 1. How the pipe works (so the tee shape makes sense)

```
factory Node-RED (SparkPlug-JSON envelope)
    │  HTTPS POST  { X-Ingest-Key, Content-Type: application/json }
    ▼
ingest-shim (:8444 Incoplast) / ingest-shim-cpack (:8446 CPACK)
    │  1. auth  (constant-time X-Ingest-Key compare → 401)
    │  2. scope guard (first topic segment must == SCOPE_GROUP → 403)
    │  3. fan-out: republish VERBATIM, once per source_type, with publisher confirms
    ▼
RabbitMQ `oee` exchange · routing key sparkplug.data.<tenant>
    ▼
oeecloud-worker  →  per-tenant queue  →  legacy-ingest decode
    │  resolve topic→id_equipment via packml_register (already seeded)
    │  write equipment_values / events, source_type "refactored" → packiot_shadow
    ▼
F3 (packiot_shadow.public) → CAgg cascade → equipment_runtime_shift/_1hour → uns_*
```

The **envelope shape** the worker parses (send exactly this):

```json
{
  "timestamp": 1782161858551,
  "gateway": "cpack-edge",
  "metrics": [
    { "name": "CPACK/SC/LINHAS/L8/Status/StateCurrent", "timestamp": 1782161858551, "value": 6 },
    { "name": "CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit", "timestamp": 1782161858551, "value": 12345 }
  ]
}
```

- **Do NOT set `source_type`** in the tee — the shim stamps it (F1/F2/F3 fan-out)
  and overwrites any value you send.
- The first topic segment (`CPACK` / `INCOPLAST`) is both the scope group the
  shim enforces **and** the tenant the worker routes on (`lower(first segment)`).
- Metric `counter`/`curspeed`/`id` may be numbers **or** quoted strings — the
  worker tolerates both (Incoplast's `PackML2SparkPlug` emits strings; CPACK
  emits numbers). Send whatever your assembly node already produces.

---

## 2. Install the Node-RED tee

### 2a. Import the flow
1. In the customer Node-RED: **Menu → Import → select file** → pick
   `cpack-tee-node.json` (or `incoplast-tee-node.json`). It imports a small tab:
   `[tee function] → [http request POST] → [switch on statusCode] → [debug ok/err]`.
2. **Wire it in:** drag a **second** wire from the output of the existing
   SparkPlug-assembly node (the node right before the cloud/`pubsub-out` publish
   — `PackML2SparkPlug` / `SparkPlug DDATA` for Incoplast; the equivalent
   envelope-producing node for CPACK) into the **`… tee`** function node's input.
   **Leave the existing publish path wired** — this is a tee, the factory keeps
   running normally.

### 2b. Set the ingest key (NEVER hardcode it in the flow)
The function node reads the key from a Node-RED **environment variable**, so the
secret never lives in the exported flow JSON:

- CPACK: `CPACK_INGEST_KEY`
- Incoplast: `INCOPLAST_INGEST_KEY`

Set it via **any** of (pick what fits their Node-RED deploy):
- the function node's **Setup → Environment Variables** tab, or
- an OS env var on the Node-RED process (`CPACK_INGEST_KEY=… node-red`), or
- `settings.js` `functionGlobalContext` / `envVars`.

The **key value** is provisioned cloud-side (see §3) and handed to the USER
out-of-band — it is **not** printed in this repo.

### 2c. TLS (self-signed staging cert)
The imported flow includes a `tls-config` node with **verify-server-cert OFF**
(acceptable for the staging window). To verify properly instead, attach the CA
(`~/incoplast-ingest/ca.crt`) to that `tls-config` node's **CA certificate**
field and turn verification back on.

---

## 3. Key handling & provisioning (no secrets in git)

- Each shim requires its own `INGEST_API_KEY` and **refuses to start unset** (no
  default — an empty key would disable auth). The two tenants use **distinct**
  keys: Incoplast `INGEST_API_KEY`, CPACK `INGEST_API_KEY_CPACK`.
- Generate a key: `openssl rand -hex 24`.
- **Staging path:** the value lives in `/opt/packiot/.env` on the staging host as
  `INGEST_API_KEY_CPACK=…`; the compose `env_file: [.env]` injects it. This file
  is **regenerated on deploy** — after a staging redeploy the key may need
  re-adding (ask the deployer). Hand the same value to the USER to paste into the
  Node-RED env var (§2b).
- **Hardening (recommended for prod):** promote both keys to **AWS Secrets
  Manager** (same mechanism the shim already uses for the RabbitMQ creds) rather
  than the deploy-regenerated `.env`. Tracked as a follow-up, not required for the
  staging bring-up.
- The shim **never logs** the key or the payload body — only the derived
  group/topic + byte size.

---

## 4. Cloud ingress — the CPACK instance (the PR)

**Recommended multi-tenant approach: a second, CPACK-scoped shim instance**
(`ingest-shim-cpack`), not extending the single Incoplast shim. Rationale:

- **Incoplast stays byte-unchanged** — different container, port, cert, key,
  routing key. Zero risk to the proven Incoplast path.
- **Zero Go code change** — pure `compose.staging.yml` config, so it ships today
  and reverts by stopping one container.
- **Fully isolated blast radius** — CPACK auth/scope/routing can't affect
  Incoplast.

Trade-off: it doesn't scale elegantly to N tenants (N certs/ports/containers).
**Mature-stack evolution (documented, not built here):** fold both into ONE shim
with a **per-key scope map** — `X-Ingest-Key → {allowed group, routing key}` —
and derive the routing key as `sparkplug.data.<lower(group)>`. That derivation is
byte-identical for Incoplast (`lower("INCOPLAST")` = `incoplast`), so the
generalization is safe when we choose to take it. For staging **now**, the second
instance is the surgical call.

**The change:** branch `feat/task54-adr0032-cpack-ingest-shim` adds the
`ingest-shim-cpack` service to `compose.staging.yml` (`:8446`, `SCOPE_GROUP=CPACK`,
`ROUTING_KEY=sparkplug.data.cpack`, `INGEST_API_KEY=${INGEST_API_KEY_CPACK}`, own
cert at `/opt/packiot/ingest-shim-cpack/certs`, IP `172.18.0.35`). → **PR to
`staging`.** Deploy steps for the host:

1. Add `INGEST_API_KEY_CPACK=<hex>` to `/opt/packiot/.env`.
2. Drop a TLS cert/key at `/opt/packiot/ingest-shim-cpack/certs/{server.crt,server.key}`
   (reuse the same self-signed CA as `:8444`, or a new one — hand the CA to the USER).
3. Open SG/Nginx for `:8446` (auth + TLS gate it; give the factory egress IP to
   restrict `0.0.0.0/0`).
4. `docker compose -f compose.staging.yml up -d ingest-shim-cpack`.
5. Confirm healthy: the container's `--healthcheck` self-probe flips healthy once
   RabbitMQ is reachable.

`FANOUT_SOURCE_TYPES` on the new instance is `legacy,go,refactored` (triple-emit)
so the real CPACK tee is a **drop-in replacement for plc-sim** — F1/F2/F3 all stay
fed, nothing downstream notices the synthetic→real swap. At the **ADR-0032
collapse** (F3-only), flip it to `refactored` — a one-line env change, no Node-RED
edit.

---

## 5. ⚠️ plc-sim coexistence — do NOT double-feed ent 3

On staging today, **CPACK ent 3 is fed by `plc-sim`** (172.18.0.200): synthetic
SparkPlug B over MQTT → `edge-transformer` → worker → F3, on the SAME
`CPACK/SC/LINHAS/L*` topics the real tee uses. If you enable the real CPACK tee
**without** stopping plc-sim, ent 3 gets **two writers** racing on the same
`(ts_value, id_equipment)` rows (UPSERT last-write-wins, values fight → garbage).

**Before enabling the real CPACK tee, do exactly one of:**
- **Disable plc-sim** (recommended): comment out / `docker compose … stop plc-sim`
  (or scale to 0). The real tee then fully replaces it. ← the clean cutover.
- **Repoint plc-sim to a throwaway group** (e.g. `groupID = "CPACKSIM"` in
  `services/edge-transformer/cmd/plc-sim/main.go`) so its topics no longer resolve
  to ent 3 — only if you want synthetic + real running side by side for A/B.

**Validation ordering:** stop plc-sim → confirm ent-3 `equipment_values` stops
advancing → enable the real CPACK tee → confirm it resumes advancing with REAL
values (§6). Never have both live on ent 3 at once.

---

## 6. Validate a message landed in F3

Run against **`packiot_shadow`** (F3) on the staging DB EC2 (`10.10.10.89`,
container `timescaledb`). **SELECT-only.** Fresh rows for the tenant = success.

```sql
-- F3 freshness per equipment for a tenant (id_enterprise: CPACK=3, Incoplast=4)
SELECT ev.id_equipment,
       max(ev.ts_value)                AS last_value_ts,
       now() - max(ev.ts_value)        AS age,
       count(*) FILTER (WHERE ev.ts_value > now() - interval '5 min') AS rows_last_5min
FROM   public.equipment_values ev
JOIN   public.equipments e ON e.id_equipment = ev.id_equipment
WHERE  e.id_enterprise = 3            -- 3=CPACK, 4=Incoplast
GROUP  BY ev.id_equipment
ORDER  BY age
LIMIT  20;
```

Expect `age < ~10s` and non-zero `rows_last_5min` on the equipments the tee feeds.
Then confirm the rollup cascade advanced:

```sql
SELECT id_equipment, max(ts_end) AS last_shift_end
FROM   public.equipment_runtime_shift ers
JOIN   public.equipments e USING (id_equipment)
WHERE  e.id_enterprise = 3
GROUP  BY id_equipment ORDER BY 2 DESC LIMIT 10;
```

Cloud-side sanity (no DB): the shim returns **202** on success and its Prometheus
metrics (`:9106` internal) count `published`; the worker's `/health` shows
`sparkplug_parsed` and per-tenant `batch_writes{tenant="cpack"}` advancing.

### Response codes the tee sees
| Code | Meaning | Action |
|------|---------|--------|
| **202** | accepted (published + broker-confirmed) | success |
| 401 | wrong/missing `X-Ingest-Key` | fix the key env var; do not retry |
| 403 | first topic segment ≠ scope group (CPACK/INCOPLAST) | fix the topic; do not retry |
| 400 | empty / >1 MiB / unparseable JSON / no metrics | fix the payload; do not retry |
| 503 | broker transiently down / confirm timeout | **retry** the whole message (writes are idempotent UPSERTs) |

---

## 7. Rollback

- **Node-RED side (fastest):** disable the `http request` node (or the tee wire /
  the imported tab). The factory's normal publish path is untouched, so the plant
  keeps running; only the staging feed stops.
- **Cloud side:** `docker compose -f compose.staging.yml stop ingest-shim-cpack`
  — CPACK ingress is fully isolated, Incoplast (`:8444`) is unaffected. To roll
  CPACK back to synthetic, re-enable plc-sim (§5).

---

## 8. OPEN QUESTIONS FOR THE USER (please decide)

These are genuine forks I could not settle from the repo alone.

1. **⭐ Compute-path fidelity — the big one.** This HTTPS→ingest-shim path lands
   CPACK on the **worker's legacy-ingest decode** (raw `equipment_values` +
   `StateCurrent` events → CAgg rollups). It does **NOT** go through
   **`edge-transformer`'s Go Calc** — the CPAC min-speed downtime algorithm
   (30750/30751/30758), `MachSpeed` handling, and `Parameter30700` line-Phase-9
   aggregation — which is exactly the path **prod CPACK and plc-sim use**.
   Concretely, with plc-sim's topic names: the count metrics
   (`ProdConsumedCount/ProcessedCount/DefectiveCount`) and `StateCurrent`
   classify correctly, but `.../Status/MachSpeed` (worker wants `CurMachSpeed`)
   and `.../Status/Parameter30700` do **not** — they'd be skipped. So CPACK OEE
   would be computed differently than in prod.
   - **If staging CPACK must faithfully mirror prod's compute**, the correct tee
     is an **MQTT tee → `edge-transformer`**, not HTTPS→ingest-shim: add a second
     `mqtt out` node in CPACK's Node-RED publishing the SAME SparkPlug B protobuf
     to a **public TLS MQTT listener** on our `mosquitto` (SG-gated). That lands
     on `edge-transformer` identically to plc-sim (ADR-0032 §1.2: *"every PLC →
     edge-transformer"*). Cost: exposing an MQTT ingress (new infra + auth), which
     is a bigger change than the HTTPS shim — hence the question.
   - **If a raw-write→CAgg OEE is acceptable for CPACK on staging** (it already is
     for Incoplast, which runs this exact path and produces correct F3 rollups),
     the HTTPS shim delivered here is sufficient — ship it.
   - **My recommendation:** ship the HTTPS shim now for a fast, low-risk real-data
     feed and F3 count/state validation; if prod-Calc fidelity for CPACK on
     staging is required, follow up with the MQTT→edge-transformer tee. Please
     confirm which fidelity bar CPACK needs.

2. **Does CPACK's real PLC use the same SparkPlug topic convention plc-sim
   assumes?** The CPACK function node assumes `CPACK/SC/LINHAS/L*/{Status|Admin}/…`
   names matching the seeded `packml_register`. If the real CPACK Node-RED emits
   different topic strings (or only protobuf-over-MQTT, no JSON envelope at any tap
   point), the tee needs the real topic list and possibly a name remap — send me a
   sample of the real envelope right before their cloud publish.

3. **`cpack` per-tenant queue** — I routed to `sparkplug.data.cpack` because the
   worker discovers `cpack` from `packml_register` and registers a
   `sparkplug.data.cpack` dispatcher (confirmed in `oeecloud-worker` main.go).
   Please confirm `oeecloud-worker-q-cpack` is declared + consumed on the current
   staging deploy; if not, fall back to plain `sparkplug.data` (the generic queue
   plc-sim's edge-transformer path already uses) by setting
   `ROUTING_KEY=sparkplug.data` on `ingest-shim-cpack`.

4. **FANOUT at collapse.** I defaulted the CPACK instance to triple-emit
   (drop-in for plc-sim). Confirm you want it flipped to `refactored` (F3-only) as
   part of the ADR-0032 Step-4 collapse, together with disabling plc-sim.
