# ADR-0041 — GCP Exit → single cloud: an AWS-native lakehouse (S3 + Glue + Athena) replacing BigQuery, plus the single-cloud teardown checklist

**Status:** Proposed · **Date:** 2026-07-22 (rev. 2026-07-23 — added §10 concrete P0→P3 build plan + reference build-plan doc + unrooted Terraform scaffold) · **Scope:** DESIGN / SCOPING ONLY (read-only inventory + target architecture + phased cutover + P0 scaffold; **no infra is provisioned, no prod is touched, no GCP resource is mutated by this ADR — the Terraform module is unrooted and applies nothing**). STAGING-first; every GCP-teardown / prod-touching step is explicitly **USER-gated**. · **Decision owner:** data/platform architect (pending USER review).

**This ADR is the execution-scoping companion to the north-star A0 milestone.** [ADR-0038 §6](0038-north-star-factory-platform.md) names **A0 — "GCP exit → single cloud (AWS)"** as a *foundation* milestone (removes cross-cloud seams before new pillars assume one IAM). [ADR-0038 §5.9](0038-north-star-factory-platform.md) states the principle: *"one cloud: one IAM, one billing, no cross-cloud seams, no service-account keys shuttling between providers."* This ADR takes that principle from slogan to **evidence-cited inventory + a phased, reversible cutover with a teardown checklist.**

**Governed by / builds on:**
- [ADR-0036 §2.4](0036-data-architecture-medallion.md) — the medallion. §2.4 *already decided* the offline/analytics tier is **AWS-native S3 + Glue + Athena replacing BigQuery**, and migration step **L0** carries the `cq-logs-bigquery` repoint. **This ADR does not re-decide that — it expands L0 into a full scoping doc** (bucket layout, partitioning, export job, parity harness, teardown). The lakehouse is fed *from the immutable Bronze tier* 0036 §3 defines; it is **offline-only**, never in the live serving path (0036 §2.2).
- [ADR-0026 §6](0026-api-layer-consolidation.md) — API consolidation. §6 item 6 first scoped **`cq-logs-bigquery` → all-AWS (S3)**, noting *"BigQuery is a lone GCP dependency for a stub that never shipped… staging is greenfield."* This ADR confirms that finding with fresh evidence (§2) and answers its open question #3 (prod BQ consumer) in the teardown gate (§5).
- [ADR-0034](0034-adopt-cognito-amplify-auth.md) — Cognito + write-side fence *(concurrent — `feat/adr-0034-cognito-amplify`; staged in `compose.staging.yml` but not yet merged to `staging`)*. **The Firebase → Cognito leg of the GCP exit is owned by 0034, not here.** This ADR *inventories* Firebase as the single load-bearing remaining GCP dependency and sequences the project-close **behind** 0034; it does not design the auth cutover.

**Relates to:** [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md)/[ADR-0010](0010-sparkplug-decode-in-go-end-state.md) (the Go ingest boundary that produced Bronze — the export source), [ADR-0011](0011-durability-boundary-and-store-and-forward.md) (durability), [ADR-0027](0027-refdata-api-surface-1-read-contract.md) (the Gold *live* read contract — unchanged by the offline lake).

> **Numbering note.** `0040` is the barcode/traceability service; this is `0041`. ADR-0034 (Cognito) currently lives on its concurrent feature branch — the Firebase-leg links resolve once that PR lands on `staging`.

---

## 1. Context — what "GCP exit" actually means, and why it is 80 % done

The stack was born cross-cloud: **GCP** carried auth (Firebase), the message bus (Pub/Sub), the cloud OEE engine (`oeecloud-node-red` on GCP Compute), and an *intended* analytics warehouse (BigQuery); **AWS** carried everything else. Every cross-cloud seam is a distinct failure class — a second IAM to reason about, a second bill, credentials shuttling between providers, and egress/latency between the two. ADR-0038 §5.9 makes **single-cloud (AWS)** a maturity requirement, not a nicety.

The exit is already *mostly* executed in the running stack. This ADR's first job is to **prove that with evidence** (so we don't teardown something still live, and don't re-migrate something already done), and its second is to **finish the two remaining legs** — BigQuery (this ADR's design content) and Firebase (ADR-0034's) — and then **close the GCP account**.

---

## 2. Inventory — the current GCP footprint (read-only, evidence-cited)

Two read-only sweeps (Sept-2026 checkout): (i) a deep read of the two BigQuery-named repos, (ii) a token grep across `packiot-stack-alpha`, `back4-api`, `front4`, `edge-node-red`. Worktree/`.wt-*` copies excluded to avoid double-counting.

### 2.1 Ledger

| GCP service | Status | Blocker weight | Replacement | Owner |
|---|---|---|---|---|
| **Firebase Auth** (project `fbpackiot`) | **ACTIVE — load-bearing** | **HIGH** (only live GCP dep) | AWS Cognito | **ADR-0034** |
| **Cloud Pub/Sub** | LEGACY (dev emulator + vestigial node only) | LOW | RabbitMQ / AMQP (**done**) | cleanup here |
| **`oeecloud-node-red`** (GCP Compute + PubSub) | LEGACY / dead | LOW | `oeecloud-worker` Go (**done**) | cleanup here |
| **BigQuery** | LEGACY / isolated (one stub Lambda, never shipped) | LOW | **S3 + Glue + Athena** | **this ADR (§3–§4)** |
| **GCS / Cloud Storage** | none (Firebase config strings only) | — | n/a | — |
| **Cloud Functions / Compute / GCE** | none (public `gcr.io/cadvisor` image mirror only) | — | n/a | — |
| Go `googleapis` genproto | transitive gRPC/protobuf, **not** a GCP binding | — | ignore | — |

**Bottom line: the GCP exit is ~80 % done in the running stack.** The bus (RabbitMQ) and the cloud engine (`oeecloud-worker`) are already AWS-native and confirmed done by ADR-0038 §5.9/§6. What genuinely remains is **Firebase → Cognito** (the hard leg, owned by 0034) and **BigQuery → Athena** (the cheap leg, scoped here), then the cleanup + project-close.

### 2.2 BigQuery — the headline: nothing to migrate, because nothing shipped

The two BigQuery-named repos are **skeletons with respect to BigQuery — not a single line of executing BQ code, SQL, or a data-source query exists in either.**

- **`cq-logs-bigquery`** (AWS Lambda scaffold). The only first-party source is `test.py`; everything under `bigquery_layer/python/**` and `psycopg2_layer/python/**` is *vendored* dependencies packaged as Lambda layers. No BigQuery client is imported or instantiated — `google-cloud-bigquery 3.26.0` is vendored in the layer but **wired to nothing**. The only query in the repo is a **commented-out Postgres read**: `# cur.execute("SELECT * FROM cq_logs LIMIT 1")` (`test.py:63-69`). The handler returns an empty `items` list; `print('test')` (`test.py:62`) confirms stub status. Intended source = the Packiot Postgres DB, table `cq_logs` (env-driven `DB_HOST/DB_NAME/...`). **Consequence: zero BigQuery Standard-SQL to port — no `STRUCT`/`ARRAY`/`UNNEST`/`APPROX_*`/`_PARTITIONTIME` dialect risk in this repo.** The migration is *greenfield build*, not *rewrite*.
- **`reports/`** — pure **LaTeX** (`main.tex` + `sections/*.tex` + `packiot.sty`, built with `latexmk`). No Python, no SQL, no BigQuery, no data-access of any kind. It is a narrative PDF deliverable that *describes* a Grafana/OpenTelemetry observability picture (HighByte @ Gerdau) in prose — figures are pasted, not programmatically pulled. **It touches no data tier at all** and needs no change under any lakehouse decision (confirms ADR-0036 §2.4: *"`reports/` is LaTeX-only"*).

So the entire real BigQuery footprint to retire is **one vendored, unused `google-cloud-bigquery 3.26.0` Lambda layer.** The name "BigQuery" reflects an *intended, unimplemented* Postgres→BigQuery CQ-logs pipeline.

### 2.3 Firebase — the one ACTIVE leg (inventoried here, migrated by ADR-0034)

Firebase project **`fbpackiot`**, service account **`firebase-adminsdk-31o62@fbpackiot.iam.gserviceaccount.com`**. Live in four components:

- **back4-api** — `firebase-admin ^11.0.0` (`package.json:39`); `initializeApp({credential: cert(serviceAccount)})` (`src/server.js:49-50`); `getAuth().verifyIdToken(token)` on every request (`src/app/middlewares/auth.js:9`, `authDevices.js:9`).
- **front4** — `firebase ^9.1.3` (`package.json:33`); client login `initializeApp(FirebaseConfig)` (`src/firebase.js`) with a **hardcoded** web API key `AIzaSyCRK02fBbgho-VSQrjt5bIZzzVdoIgpRGo`.
- **refdata-api** (the Go read plane) — `auth_firebase.go` verifies RS256 Firebase ID tokens against `securetoken@system.gserviceaccount.com` x509 certs; canonical `main.go` is **Firebase-only** (`FIREBASE_PROJECT_ID` default `fbpackiot`). The dual (Firebase+Cognito) verifier exists only in the concurrent worktree, not mainline.
- **edge-node-red** — operator login calls `identitytoolkit.googleapis.com/...signInWithPassword` + `securetoken.googleapis.com/v1/token` with `$(FIREBASE_API_KEY)` (`flows.json`).

Cognito is **staged in config** (`compose.staging.yml:410-411`: `COGNITO_ISSUER … us-east-1_0T9t1sTwt`, `COGNITO_CLIENT_ID 2ckuoa0ov598rdpdn3uv039h6e`) but not yet cut over. **This is the long pole of the GCP exit** and is owned by ADR-0034.

### 2.4 Pub/Sub + `oeecloud-node-red` — LEGACY, already replaced

RabbitMQ (`rabbitmq:3.13-management`, `RABBITMQ_HOST`) is the active bus across `compose.{development,staging,production}.yml` for edge-nodered, oeecloud-worker, ingest-shim, edge-transformer. Pub/Sub survives only as a **dev emulator** (`thekevjames/gcloud-pubsub-emulator`, `GCP_PROJECT_ID: packiot-dev`) and one vestigial node-red node (`flows.json` has **1** stale `pubsub` label vs **12** live `amqp` outputs). `oeecloud-node-red` still exists on disk but its `entrypoint.sh:54` literally says *"PUBSUB_SUBSCRIPTION removed — stack migrated to RabbitMQ"*; `oeecloud-worker` (Go AMQP) is the live engine. **Cleanup only** — no migration.

### 2.5 Security items surfaced by the inventory (independent of, but bundled with, the exit)

1. **`back4-api/private-key.json`** — a **real, checked-in GCP service-account key** (live `private_key`, `project_id: fbpackiot`). Must be deleted from the working tree **and purged from git history**, and the SA key **revoked**, as part of the Firebase teardown.
2. **`front4/src/firebase.js`** — hardcoded Firebase Web API key (lower risk — Firebase web keys are public identifiers, not secrets — but should die with the Cognito cutover).
3. **`cq-logs-bigquery`** — README documents a **prod Postgres password previously committed to git history, removed from the tree but NOT rotated** ("the leaked credential remains valid"). Rotate independently of GCP — it outlives this migration.

---

## 3. Target architecture — the AWS-native gold-offline lakehouse

Per ADR-0036 §2.4, the offline/analytics tier is **AWS-native S3 + Glue + Athena**, fed *from the immutable Bronze tier* on a **batch cadence**, and **never** in the live serving path (the hot path stays entirely on Timescale, 0036 §2.2). This ADR fills in the concrete shape; the **full engineering spec** (parquet-column type mapping, Glue projection DDL, export-job algorithm + watermark, parity harness) lives in the reference companion — [`reference/designs/0041-lakehouse-build-plan.md`](reference/designs/0041-lakehouse-build-plan.md) — with the Athena DDL at [`reference/migrations/0041-glue-catalog-ddl.sql`](reference/migrations/0041-glue-catalog-ddl.sql) and a **scaffold (unrooted, non-applying) Terraform module** at [`terraform/modules/lakehouse/`](../../terraform/modules/lakehouse/README.md).

```
TIMESCALE (live medallion — unchanged)
  Bronze (immutable raw)  Gold (equipment_runtime_*, uns_*)
        │                          │
        └──────────┬───────────────┘
                   ▼  batch export job (scheduled, SELECT-only read)
         parquet, partitioned, written to S3
                   ▼
   s3://packiot-lake-<env>/{bronze,silver,gold}/<table>/id_enterprise=<t>/dt=<YYYY-MM-DD>/*.parquet
                   ▼
        AWS Glue Data Catalog  (schema + partitions; partition projection, no crawler)
                   ▼
        Amazon Athena  (engine v3 / Trino; serverless, pay-per-TB-scanned)
                   ▼
     consumers:  cq-logs  ·  reports upstream  ·  ad-hoc SQL  ·  future ML features
```

### 3.1 S3 layout & format

- **One bucket per env** (`packiot-lake-staging`, later `packiot-lake-prod`), prefixed by layer: `bronze/`, `silver/`, `gold/`. Mirrors the medallion so the lake is legible to anyone who knows the live DB.
- **Parquet** (columnar, compressed — Snappy/ZSTD). Columnar + compression is what makes Athena cheap: you pay per **byte scanned**, and Athena reads only the projected columns of the pruned partitions.
- **Hive-style partitioning** `…/<table>/id_enterprise=<t>/dt=<YYYY-MM-DD>/`. Two partition keys chosen deliberately:
  - `id_enterprise` — **tenant**. Every offline query is tenant-scoped, so tenant-first partitioning prunes hardest and keeps the one-tenant-per-scan isolation the read plane enforces (ADR-0038 §5.5).
  - `dt` — **date**. Reporting is date-ranged; date partitioning turns "last quarter for tenant 4" into a handful of partition reads instead of a full-table scan.
- **File sizing** — target 128–512 MB parquet files (coalesce small daily writes) to avoid the "many tiny files" Athena/Trino anti-pattern (per-object listing + planning overhead dominates when files are KB-sized).

### 3.2 Glue Data Catalog — use partition projection, not a crawler

The catalog holds the table schemas + partition registry (the Hive-metastore equivalent Athena queries against). **Recommendation: define tables with Glue *partition projection*** (the `id_enterprise` / `dt` ranges declared in table properties) rather than running a Glue *crawler*. Projection computes partitions from the query predicate at plan time — **no crawler DPU-hours, no partition-staleness window, $0 catalog maintenance.** A crawler is only worth it for schema-drift discovery we don't have here (we own the export schema).

### 3.3 Athena — the BigQuery analog, plus the alternative

Athena is serverless pay-per-query SQL over S3 — the **direct BigQuery replacement** (0036 §2.4). Set up a dedicated **Athena workgroup** per env with (a) a **per-query bytes-scanned cap** (guardrail against a runaway full-scan bill), (b) results written to a governed `s3://…/athena-results/` prefix with lifecycle expiry, (c) CUR/CloudWatch cost attribution by workgroup.

**Alternative — Redshift Serverless — deferred, not rejected** (0036 §2.4): layer it later via Spectrum over the *same* S3 only if a warehouse-shaped BI workload (heavy concurrency, complex joins) emerges. Don't provision a warehouse before there's a warehouse-shaped workload.

### 3.4 The batch export job

A scheduled job (**EventBridge Scheduler → a small ECS task or Lambda**) that, per tenant per day:
1. Reads the closed/immutable window from Timescale — **Bronze** (`equipment_values`, `equipment_events`) as the raw export source, plus **Gold** rollups (`equipment_runtime_*`) for reporting. Read-only — a natural fit for the **prod DB's SELECT-only** posture (memory: prod is SELECT-only for us; a read-export never needs write access).
2. Writes parquet to the partition path, coalesced to target file size.
3. Refreshes the Glue partition (or relies on projection — §3.2).
- **Cadence:** daily for gold reporting; Bronze export can be daily or on the same closed-window boundary. Late-arriving data is handled by re-exporting the affected `dt` partition (idempotent overwrite of that partition only — the medallion's replay principle, 0036 §3.3, applied to the lake).
- **Watermark:** drive off the Gold `source_watermark` / `computed_at` lineage columns (ADR-0036 §5A) so an export knows exactly which window is final and re-exports only what moved.

---

## 4. Reports-pipeline migration — a client repoint, not a rewrite

### 4.1 `cq-logs-bigquery`

Because the BQ path **never shipped** (§2.2), this is a **greenfield AWS-native build**, not a port:
- Replace the vendored `google-cloud-bigquery` Lambda layer with a **`boto3` / `pyathena`** layer (or query Athena via the boto3 `athena` client + `start_query_execution`).
- The Lambda already talks to Postgres via `psycopg2` and already imports `boto3` — the AWS-native shape is *closer* to what's there than the BQ shape ever was.
- Land the `cq_logs` dataset as **parquet in S3** cataloged in Glue; the Lambda reads/writes via Athena. Same SQL-over-columnar-data shape, AWS endpoint.
- **De-scope risk:** since there is no existing BQ consumer or data (staging greenfield, ADR-0026 §6), there is *nothing to parallel-run against* — the cq-logs leg is a **hard build-and-ship**, not a parity migration.

### 4.2 `reports/`

**No change.** LaTeX-only, no data tier (§2.2). Its upstream (whatever hands it numbers) reads Athena/S3 instead of BigQuery, transparently — but that upstream is not `reports/` and is not built today.

### 4.3 SQL dialect — for the *future* datasets, not today's (zero) queries

Today there is **zero** BQ SQL to port. But the value of choosing AWS-native is the *future* analytics/ML tier is born on Athena — so record the BigQuery-StandardSQL → Athena-v3 (Trino/Presto) deltas now, so future authors write portable SQL:

| BigQuery Standard SQL | Athena engine v3 (Trino/Presto) |
|---|---|
| `` `project.dataset.table` `` (backticks) | `"catalog"."database"."table"` (double-quotes) |
| `_PARTITIONTIME` / `_PARTITIONDATE` pseudo-cols | explicit partition column (`dt`) + partition projection |
| `SAFE_CAST(x AS INT64)` / `SAFE.fn(...)` | `try_cast(x AS bigint)` / `try(fn(...))` |
| `APPROX_COUNT_DISTINCT(x)` | `approx_distinct(x)` |
| `UNNEST(arr)` implicit cross join | `CROSS JOIN UNNEST(arr) AS t(col)` |
| `TIMESTAMP_SUB(ts, INTERVAL 1 DAY)` | `date_add('day', -1, ts)` |
| `FORMAT_TIMESTAMP('%Y-%m-%d', ts)` | `date_format(ts, '%Y-%m-%d')` |
| `STRUCT<...>` / `x.field` | `ROW(...)` / `x.field` (types declared in Glue) |
| `INT64` / `FLOAT64` / `STRING` | `bigint` / `double` / `varchar` |
| `QUALIFY` (window filter) | supported in engine v3 |

---

## 5. Cutover plan — phased, reversible, teardown USER-gated

Two independent legs converge on the project-close. **The BigQuery leg can proceed fully now (staging, autonomous-eligible — no GCP touched); the project can only be *closed* after the Firebase leg (ADR-0034) lands.**

| Phase | Leg | Action | Prod/GCP touch? | Reversible? |
|---|---|---|---|---|
| **L0-a** | BigQuery | Stand up staging lake: S3 bucket + Glue tables (projection) + Athena workgroup; build the gold-export job; rebuild `cq-logs` Lambda on `pyathena`/`boto3`. | **No** (new AWS infra only) | Yes (tear down AWS infra; nothing depended on it) |
| **L0-b** | BigQuery | Parity bake for the **gold export**: Athena aggregate == Timescale aggregate per tenant-day (§5.1). cq-logs itself has no legacy to compare (greenfield). | No | Yes |
| **L1** | Firebase | Cut back4-api / front4 / refdata-api / edge-node-red to Cognito. **Owned by ADR-0034** — not designed here; it is the gate for most of the teardown. | Yes (auth) | Yes (dual-verifier window) |
| **L2** | Teardown | Execute the GCP-teardown checklist (§5.2) after all consumers are cut and a bake window passes. | **Yes — USER-gated** | **No (irreversible)** |

**Parallel-run vs hard-cut, per leg:**
- **BigQuery = hard-cut** (there is no live BQ path to run in parallel — it never shipped). The only "parity" that matters is the *new* gold-export ↔ Timescale check.
- **Firebase = parallel-run** (dual Firebase+Cognito verifier during the ADR-0034 bake, then flip). Not this ADR's design.

### 5.1 Parity validation (the gold export)

For the real medallion export (the durable value; cq-logs greenfield has nothing to compare):
- **Row-count + `sum(metric)` per `(id_enterprise, dt)` partition**, Timescale vs Athena, with a tolerance band for float rounding (parquet double round-trip). Zero-drift on counts, small band on gross.
- **Checksum spot-check** on a sample of partitions (ordered hash of key columns).
- Reuse the comparator discipline from the F2/F3 parity work (byte-exact where integer, tolerance-banded where float) — same method, offline target.
- Gate teardown on a **clean bake over ≥ one full reporting cycle** (e.g. a month-boundary, since reporting is monthly-grained).

### 5.2 GCP-teardown checklist — **every step USER-gated (prod / external / irreversible)**

> None of these are executed by this ADR. Each is flagged for USER action, in dependency order.

1. ⛔ **Confirm no prod BigQuery consumer exists** — answer ADR-0026 §6 open-question #3 by inspecting the `fbpackiot`/BQ project billing + query history in the GCP console. (Staging is greenfield; prod is a separate check.) *Gate for steps 3+.*
2. ⛔ **Rotate the leaked prod Postgres password** (cq-logs git history, §2.5.3) — independent of GCP, do it regardless.
3. ⛔ **Delete the `cq_logs` BigQuery dataset** (if any exists) after step 1 confirms no consumer.
4. **Remove the vendored `google-cloud-bigquery` layer** from `cq-logs-bigquery`; ship the `pyathena` build (safe, staging, autonomous-eligible — no GCP touch).
5. ⛔ **Firebase leg (post-ADR-0034 cutover + bake):** delete `back4-api/private-key.json` from the tree **and purge from git history**; **revoke** SA key `firebase-adminsdk-31o62@…`; disable Firebase sign-in providers; remove `FIREBASE_*` env from `compose.staging.yml`.
6. ⛔ **Pub/Sub leg cleanup:** delete any real `packiot-dev` topics/subscriptions (`oee-topic`/`oeecloud-sub`); remove the dev emulator + `pubsub-queue` node + `PUBSUB_*`/`GCP_PROJECT_ID` env; **archive** `oeecloud-node-red`; drop the `node-red-contrib-google-cloud` dep. Update the stale README PubSub narrative → RabbitMQ.
7. ⛔ **Revoke all remaining GCP SA keys**; remove any `GOOGLE_APPLICATION_CREDENTIALS` secrets from every deploy target.
8. (Cosmetic) repoint `gcr.io/cadvisor/cadvisor` to a non-GCR mirror — not a real dependency (public image), do opportunistically.
9. ⛔ **Close the GCP billing account / delete the `fbpackiot` + `packiot-dev` projects** — **last step**, only after steps 1–8 and a bake window. Irreversible; the definition of "off GCP."

---

## 6. Cost sketch — the exit is about seams, not dollars

**Tie-in:** the deferred cost-optimization tracker (`docs/ops/aws-cost-optimization.md`, run-rate ~**$1,670/mo**) lists **no BigQuery line item** — because BQ never shipped (§2.2), **current BigQuery spend is effectively $0.** Firebase Auth verification is free-tier. So the GCP exit **does not save meaningful money** — its value is *seam elimination*: one IAM, one bill, no SA keys shuttling between clouds, no cross-cloud egress/latency class.

The AWS-native replacement is a **rounding error** against the $1,670/mo run-rate:

| Component | Sizing assumption | Est. $/mo |
|---|---|---|
| **S3** (gold parquet, compressed) | ~10s of GB even at years of retention (columnar+ZSTD) | **< $2** (~$0.023/GB-mo) |
| **Athena** (pay per TB scanned) | spiky/ad-hoc + monthly reports; parquet + partition-pruning keeps scans small (< 1 TB/mo) | **< $5** ($5/TB scanned) |
| **Glue Data Catalog** | partition projection → no crawler; < 1 M objects | **~$0** (first 1 M objects free) |
| **Total new AWS** | | **~$5–15/mo ceiling, realistically < $5** |

**Net:** the lakehouse *adds* a few dollars/month to the AWS bill and *removes* an entire cloud's worth of IAM/credential/billing surface. The correct framing for the cost tracker is a **new "GCP-exit lakehouse" line at ~$5–15/mo**, offset by *removing the GCP account entirely* (whatever the `fbpackiot`/`packiot-dev` projects bill today — likely near-zero, to be confirmed by teardown step 1). **The savings are structural (one bill, one IAM), not line-item.**

---

## 7. Consequences

**Positive:**
- **100 % single-cloud (AWS)** once the Firebase leg lands — collapses the cross-cloud IAM/billing/credential/egress surface (ADR-0038 §5.9). Every future offline dataset (ML features, long-horizon OEE trend, cross-tenant benchmarking) is **born on S3+Athena inside the one-cloud boundary** instead of re-opening a GCP dependency — the real value (0036 §2.4).
- **The BigQuery leg is nearly free to execute** — no BQ SQL to port, no live consumer to migrate, `reports/` untouched. It is a greenfield AWS build gated only by the (independent) gold-export parity bake.
- **Removes checked-in secrets** — the `private-key.json` SA key and (with Cognito) the hardcoded Firebase web key leave the tree as a *consequence* of the exit.

**Negative / risks:**
- **Firebase is the long pole and is NOT owned here.** The GCP project cannot close until ADR-0034's Cognito cutover across four components (back4-api, front4, refdata-api, edge-node-red) completes and bakes. This ADR's teardown is *gated* on 0034; do not sequence step 9 before it.
- **Athena bill runaway** if an unpartitioned/`SELECT *` full-scan slips through — mitigated by the workgroup per-query bytes-scanned cap (§3.3) and partition-first schema (§3.1).
- **Export-job as a new moving part** — one more scheduled job to operate. Mitigated by making it read-only (fits prod SELECT-only), idempotent per-partition, and watermark-driven (re-export only what moved).
- **Small-files anti-pattern** if daily per-tenant writes aren't coalesced — mitigated by the 128–512 MB target sizing (§3.1).
- **Un-rotated leaked prod DB password** (§2.5.3) is a live exposure *today*, orthogonal to GCP — do not let the migration framing defer it.

---

## 8. Alternatives considered

- **Keep BigQuery for the offline tier.** Rejected (0036 §2.4 + §2.2) — re-opens a GCP dependency the rest of the stack has already left; footprint is a never-shipped stub, so exiting is cheap and the future analytics/ML tier is born AWS-native.
- **Redshift Serverless as the offline engine.** Deferred, not rejected (§3.3) — S3+Athena fits the lake+batch-reporting shape with no idle cost; layer Redshift via Spectrum over the same S3 later only if a warehouse-shaped workload emerges.
- **Full Databricks/Delta or a Spark export pipeline.** Rejected — the export is a daily read-and-write-parquet job, not a streaming/distributed-transform workload; ADR-0036 §2.2 keeps the live path in Timescale and refuses to bolt on a Spark/Delta substrate.
- **Parallel-run the BigQuery leg.** N/A — there is no live BQ path to run in parallel (§5). Hard-cut is correct; the parity effort belongs to the *new* gold-export ↔ Timescale check, not a BQ comparison.
- **Big-bang GCP project deletion.** Rejected — the two legs (BigQuery, Firebase) have different owners and readiness; the checklist (§5.2) is dependency-ordered so the irreversible project-close is the *last* gated step, behind the auth cutover and a bake.

---

## 9. Recommended phasing (the headline)

1. **Now, autonomous-eligible (staging, no GCP touch):** L0-a — stand up the staging lake (S3 + Glue projection + Athena workgroup) + the gold-export job + the `pyathena` rebuild of `cq-logs`. Build the parity harness (§5.1).
2. **Then:** L0-b — bake gold-export parity over a reporting cycle. In parallel, **rotate the leaked prod Postgres password** (§2.5.3 — don't wait for GCP).
3. **Gated on ADR-0034:** L1 — the Firebase→Cognito cutover (owned there) is the long pole; it unblocks the bulk of the teardown.
4. **USER-gated, last:** L2 — execute the teardown checklist (§5.2) in dependency order, closing the `fbpackiot`/`packiot-dev` projects only after all consumers are cut and baked.

**The single most important sequencing rule:** the BigQuery leg is *independent and cheap* — ship it now; the project-**close** waits on Firebase (ADR-0034). Don't couple the two, and don't fire an irreversible teardown step before its consumer is confirmed dead (step 1 gates step 3; step 5 gates on the 0034 bake; step 9 is last).

---

## 10. Concrete build plan — P0 → P3 (the BigQuery leg, decomposed)

§5/§9 frame the two *legs* (BigQuery vs Firebase) and the teardown gates. This section decomposes the **BigQuery leg into four shippable phases**. Full engineering detail (DDL, parquet schema, export-job algorithm, watermark, parity SQL) is in [`reference/designs/0041-lakehouse-build-plan.md`](reference/designs/0041-lakehouse-build-plan.md) §8; this is the ADR-level headline.

| Phase | Name | What lands | Prod/GCP touch | Exit criteria |
|---|---|---|---|---|
| **P0** | **Scaffold** *(this PR)* | The reference build-plan doc; the Glue DDL (`reference/migrations/0041-glue-catalog-ddl.sql`); the **unrooted** Terraform module (`terraform/modules/lakehouse/` — S3 + Glue DBs + Athena workgroup, referenced by no root → `apply` is a no-op); this §10. **No infra.** | **No** | Doc + scaffold merged; module `terraform validate`s standalone; DDL + type-mapping reviewed. |
| **P1** | **Export** | Wire the module into `terraform/staging` (a new `lakehouse.tf` calling `../modules/lakehouse`) → apply **staging only**; build the read-only, watermark-driven Bronze+Gold export job (EventBridge Scheduler → Fargate); first parquet partitions land in `s3://packiot-lake-staging/`. | **No** (new AWS infra only; nothing depends on it → fully reversible) | Job green for a tenant-day; parquet in S3; watermark advances; re-run overwrites the partition idempotently. |
| **P2** | **Athena** | Run the Glue DDL; validate partition projection prunes; run the **parity harness** (Timescale ↔ Athena per `(tenant, dt)`); enforce the workgroup bytes-scanned cap + results lifecycle. | **No** | Zero row-count drift + in-band `sum(metric)` over a bake cycle; sample checksums match; cap enforced. |
| **P3** | **Repoint `cq-logs`** *(sibling repo, own PR)* | Swap the vendored `google-cloud-bigquery` Lambda layer → `pyathena`/`boto3` handler; land the `cq_logs` dataset as parquet in the lake; ship. This makes the §5.2 teardown checklist **actionable** (all USER-gated). | **No** for the build; **teardown = USER-gated** | `cq-logs` reads the lake green → hand off §5.2 (rotate leaked pw; revoke SA key post-0034; close GCP project — each USER-gated, dependency-ordered). |

**Autonomy line:** P0–P3 are **staging + new-AWS-only, autonomous-eligible** (no GCP mutation, no prod write — matches the standing autonomy authorization). Only the §5.2 teardown steps (irreversible / prod / external) are USER-gated. **P0 is this PR — design + scaffold, zero infra provisioned.**
