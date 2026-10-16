# CPACK Mode-A tee — go-live runbook (ADR-0042 P1)

**One-step coordinated cutover** to swap staging's synthetic `plc-sim` CPACK
feed (ent 3) for CPACK's **real** factory Node-RED tags, running through the
`sparkplug-agent-cpack` service → internal mosquitto → the full prod
edge-transformer Calc → **F3 (`packiot_analytics`)**.

**Scope: STAGING only.** No prod writes. This closes the standing "CPACK real
data bypasses the Calc" gap (today ent 3 is `plc-sim` synthetic).

**Companion docs — read alongside this:**
- [`docs/adr/0042-cpack-tee-frontdoor.md`](../adr/0042-cpack-tee-frontdoor.md) — the pipeline, the nginx front-door + SG-rule spec, the cutover/rollback, expected F3 result.
- [`docs/clients/cpack-agent.yaml`](../clients/cpack-agent.yaml) — the agent descriptor (group_id `CPACK`, edge_node_id `cpack-tee`, `raw_tag_map`).
- [`docs/ingestion/cpack-agent-tee-function.js`](cpack-agent-tee-function.js) — the Node-RED tee body the USER installs at CPACK.
- `compose.staging.yml` — the `sparkplug-agent-cpack` service (profile `cpack-tee`).

---

## 0. Where we are — this runbook's prerequisites are DONE

The stack side is built, merged (#580), and **proven deploy-ready** by the prep
pass. What is already true on staging **right now**:

| Item | State | Evidence |
|------|-------|----------|
| `sparkplug-agent-cpack` service | merged, behind profile `cpack-tee` (does NOT start on default bring-up) | `compose.staging.yml`; runner checkout HEAD = #580 merge |
| Ingest key wired | `AGENT_INGEST_API_KEY` appended to `/opt/packiot/.env` (additive, no clobber) | `docker compose --profile cpack-tee config` resolves it into the service env |
| Config parses + service shape | ✅ static IP `172.18.0.38`, `cpack-agent.yaml` bind mount, outbox volume, `depends_on: mosquitto` healthy, healthcheck | `docker compose --profile cpack-tee config` |
| Boot + auth + ingest + encode + publish | ✅ smoke-tested in isolation (throwaway group `CPACKTEST`, throwaway broker) — `/healthz` green, wrong key→401, real key→202 `{accepted:5}`, published `spBv1.0/CPACKTEST/NBIRTH/cpack-tee-smoke` | prep smoke test, torn down |

**Two things remain — BOTH are the coordinated cutover below:**
1. **USER applies the SG rule** (+ nginx vhost) opening the public front-door — §1.
2. **The operator runs the cutover** (`stop plc-sim` → `up sparkplug-agent-cpack`) — §2.

> ✅ **Key durability — now codified.** The hand-appended `/opt/packiot/.env`
> line used to DROP on a full instance re-init (`app_init.sh` rewriting `.env`).
> Fixed: a `packiot/staging/agent-ingest` secret + a guarded fetch in
> `app_init.sh` now re-materialize `AGENT_INGEST_API_KEY` into `.env` on every
> rebuild (`terraform/staging/secrets.tf` + `user_data/app_init.sh`). **One-time
> operator step:** populate the secret with the key CPACK is configured with
> (out-of-band — the value is never in Terraform state or git):
> ```bash
> aws secretsmanager put-secret-value --secret-id packiot/staging/agent-ingest \
>   --region us-east-1 --secret-string '{"api_key":"<AGENT_INGEST_API_KEY>"}'
> ```
> Until the secret is populated the fetch defaults to empty (agent auth stays
> closed). The §Appendix hand-append is now only a break-glass path.

---

## 1. USER-gated: open the public front-door (SG rule + nginx vhost)

The agent's `/v1/tags` is **plaintext HTTP on `packiot-net`, internal-only** (no
host port published). To let CPACK's Node-RED reach it, terminate TLS at nginx
and open the SG to CPACK's egress IP **only**. Full spec:
[`0042-cpack-tee-frontdoor.md` §2](../adr/0042-cpack-tee-frontdoor.md).

**(a) nginx vhost** — `/etc/nginx/conf.d/cpack-ingest.conf` on the staging App
EC2 (`i-06c9547a2c7091ab7`), reusing the existing Let's Encrypt wildcard cert.
**Now codified** in `terraform/staging/user_data/nginx_setup.sh` (the
`cpack-ingest.conf` block, `server_name`/cert driven by `$STAGING_DOMAIN`) — it
is rewritten on every (re)build, so this is no longer hand-added drift. Resolved
output:

```nginx
server {
    listen 8447 ssl;
    server_name cpack-ingest.staging.packiot.app;
    ssl_certificate     /etc/letsencrypt/live/staging.packiot.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/staging.packiot.app/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    client_max_body_size 1m;               # matches the agent's MaxBodyBytes cap
    location = /v1/tags {
        proxy_pass       http://172.18.0.38:9104;   # sparkplug-agent-cpack
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 30s;
    }
}
```
On a fresh build `nginx_setup.sh` runs `nginx -t && nginx -s reload` for you;
for a manual repair, write the file and run `nginx -t && systemctl reload nginx`.

**(b) Security-group rule + DNS (codified in `packiot-stack-alpha/terraform/staging`
— apply is still USER-gated).** Open inbound **TCP 8447 from CPACK's egress `/32`
ONLY** on the App EC2 SG. The staging SG/zone/EIP live in **this** repo's
`terraform/staging` (S3 backend), **not** in `api-terraform` (that is the prod
EKS tree). Codified as an inline `ingress` on `aws_security_group.app`
(`security_groups.tf`) plus the `cpack-ingest` A record (`dns.tf`):

```hcl
# terraform/staging/security_groups.tf — inside aws_security_group.app
ingress {
  description = "ADR-0042 P1 CPACK Node-RED tee -> sparkplug-agent /v1/tags (CPACK egress /32 only)"
  from_port   = 8447
  to_port     = 8447
  protocol    = "tcp"
  cidr_blocks = ["179.162.112.58/32"]   # CPACK egress /32
}
```

Committing the HCL does **not** open the port — someone must `terraform apply`.
Do NOT auto-apply.

**(c) Hand CPACK the tee.** Install [`cpack-agent-tee-function.js`](cpack-agent-tee-function.js)
as a SECOND wire off CPACK's PLC-read node (a tee, not a redirect — the existing
publish path stays wired). Set the Node-RED env var `CPACK_AGENT_INGEST_KEY` to
the agent's `AGENT_INGEST_API_KEY` **out-of-band** (never in the flow), and
optionally `CPACK_AGENT_INGEST_URL = https://cpack-ingest.staging.packiot.app:8447/v1/tags`.

---

## 2. The cutover (reversible, operator runs on the App EC2)

Run from the compose project dir on `i-06c9547a2c7091ab7`:
`/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha`.

> ⚠️ **Never run both `plc-sim` and `sparkplug-agent-cpack` at once.** They use
> the SAME group (`CPACK`) with metric names that resolve to the SAME ent-3
> equipment; two live edge nodes = **double-source** ent 3 (double-count,
> `oee > 1.0`). The cutover **stops `plc-sim` FIRST**, then starts the agent.

```bash
cd /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha

# ── CUTOVER ────────────────────────────────────────────────────────────────
docker compose -f compose.staging.yml stop plc-sim
docker compose -f compose.staging.yml --profile cpack-tee up -d sparkplug-agent-cpack
```

The agent starts, connects to mosquitto, and idles until the first real tags
arrive over the front-door (§1). `/healthz` tracks broker connectivity only
(`MQTT_STALE_THRESHOLD_SECONDS=-1` — the loopback is idle by design; a
permanently-red idle probe would train ops to ignore red).

---

## 3. Verify real data lands (F3)

Work top-to-bottom; each step feeds the next.

**3.1 Agent healthy + accepting tags.**
```bash
docker exec sparkplug-agent-cpack /usr/local/bin/sparkplug-agent --healthcheck; echo "exit=$?"   # 0 = green
docker logs --tail 50 sparkplug-agent-cpack | grep -E "tags accepted|uplink: connected|rebirth"
```
Expect `"tags accepted" accepted=N total=N` once CPACK's tee is POSTing.

**3.2 SparkPlug published to mosquitto** (the real group/node, not the smoke's):
```bash
docker run --rm --network packiot-net eclipse-mosquitto:2 \
  mosquitto_sub -h mosquitto -t 'spBv1.0/CPACK/#' -F '%t' -W 15 | sort -u
```
Expect `spBv1.0/CPACK/NBIRTH/cpack-tee` then `spBv1.0/CPACK/NDATA/cpack-tee`.
(First-ever tags emit an **NBIRTH** whose snapshot carries the values, then
NDATA on subsequent changes — per ADR-0042 §2.2.)

**3.3 ent-3 `equipment_values` advancing in F3 (`packiot_analytics`)** — the 8
covered equipment `{47,48,49,51,53,57,61,63}`, `source_type='refactored'`. On
the DB host (`i-064bb36d1c454d861`, `timescaledb` container), **SELECT-only**:
```sql
-- packiot_analytics
SELECT id_equipment, count(*), max(ts_value) AS latest
FROM equipment_values
WHERE id_equipment IN (47,48,49,51,53,57,61,63)
  AND ts_value > now() - interval '10 min'
GROUP BY id_equipment ORDER BY id_equipment;
```
Expect `latest` within the last tick for each; counts climbing over successive
runs. Then confirm the CAgg cascade fills `equipment_runtime_shift` /
`equipment_runtime_1hour` for the L8/L5/L3/L4 lines.

**3.4 DQ board clean.** Grafana → the data-quality / ingestion dashboards: no new
`unmapped` / `decode_error` drops on `sparkplug_agent_raw_dropped_total`, no F3
lag/backlog spikes on `oeecloud-worker`.

**3.5 Tempo trace agent → edge-transformer → F3.** Grafana → Explore → Tempo:
find a trace spanning the agent publish → edge-transformer decode/Calc → the
`packiot_analytics` batch write, confirming the full path end-to-end.

**3.6 Parity sanity.** OEE for L8/L5/L3/L4 should track the same band `plc-sim`
produced (L8 within ~5% of prod — the `raw_tag_map` is EXACTLY plc-sim's proven
feed, and the SparkPlug bytes are decode-identical). Divergence there = a real
`raw_tag_map` / topology gap to chase, **not** a transport artifact
(ADR-0042 §4).

---

## 4. ROLLBACK (back to synthetic sim — always available)

```bash
cd /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha
docker compose -f compose.staging.yml stop sparkplug-agent-cpack
docker compose -f compose.staging.yml start plc-sim
```
`plc-sim` resumes its synthetic ent-3 feed (`RestartPolicy=unless-stopped`;
`stop` on the agent is a clean detach — its NDEATH LWT fires so edge-transformer
sees the node go offline). Optionally revert the SG rule in §1(b) to re-close the
front-door. No data cleanup needed — F3 simply resumes receiving sim values.

---

## 5. One-line summary

> **One step from go-live = [ USER applies the SG rule (tcp/8447 → CPACK egress
> `/32`) + nginx vhost ]  AND  [ the coordinated cutover: `stop plc-sim` →
> `--profile cpack-tee up -d sparkplug-agent-cpack` ].** The ingest key is
> already wired; boot/auth/ingest/encode/publish are already proven.

---

## Appendix — re-wire the key after an instance re-init

If the App EC2 was rebuilt and `/opt/packiot/.env` was regenerated without the
key (see the durability caveat in §0), re-append it before the cutover
(additive, secret stays off git — supply the value out-of-band):

```bash
ENV=/opt/packiot/.env
grep -q '^AGENT_INGEST_API_KEY=' "$ENV" || printf 'AGENT_INGEST_API_KEY=%s\n' "$KEY" >> "$ENV"
# verify it resolves into the service env:
cd /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha
docker compose -f compose.staging.yml --profile cpack-tee config | grep -A2 -i AGENT_INGEST_API_KEY
```
The durable fix is **already codified** (see the §0 caveat): the
`packiot/staging/agent-ingest` secret + the guarded fetch in `app_init.sh` make
re-init re-materialize the key automatically. This hand-append is now only a
break-glass path for when the secret hasn't been populated yet. Prefer
populating the secret with `put-secret-value` over re-appending by hand.
