# ADR-0042 P1 — CPACK Mode-A tee: front-door + cutover spec

Companion to the `sparkplug-agent-cpack` service (`compose.staging.yml`) and the
agent HTTP ingest (`services/edge-transformer/internal/agent/httpingest`). This
doc holds the two **USER-gated / operational** pieces the PR builds-and-proves
but does **not** apply: the public HTTPS front-door (nginx + cert + SG rule) and
the plc-sim cutover.

## 1. Pipeline (Mode-A, direct-to-ingest)

```
CPACK real Node-RED  ──tee (2nd wire)──▶  rawtag JSON envelope
        │  HTTPS POST /v1/tags  { X-Ingest-Key }
        ▼
nginx (:8447 TLS)  ──proxy──▶  sparkplug-agent-cpack :9104 (plaintext, packiot-net)
        │  agent: auth → tag_map resolve → tagstore(RBE) → SparkPlug B session
        ▼
INTERNAL mosquitto :1883   spBv1.0/CPACK/{NBIRTH,NDATA}/cpack-tee
        ▼
edge-transformer (MQTT_ENABLED, USE_GO_PORT, CALC_CUTOVER_REFACTORED)
        ▼
FULL prod Calc  →  F3 (source_type "refactored" → packiot_shadow)
```

**Why the agent path and not the ADR-0032 ingest-shim path?** The ingest-shim
republishes the raw envelope to `oeecloud-worker`'s *legacy-ingest decode*.
ADR-0042 P1 runs CPACK's real tags through the **real edge-transformer Calc**
(min-speed downtime, line Phase-9), closing the standing "CPACK real data
bypasses the Calc" gap. The two are different endpoints — install one.

## 2. Front-door — nginx TLS reverse-proxy (USER-gated, spec only)

The agent's `/v1/tags` server is **plaintext HTTP on packiot-net** (no host port
published in the compose service — internal-only by default). Terminate TLS at
nginx on a dedicated port, reusing the existing Let's Encrypt wildcard cert
(`terraform/staging/user_data/nginx_setup.sh`). Auth is the `X-Ingest-Key`
header (constant-time compared in the agent) — **no Authentik gate** here, same
carve-out as the `api` vhost.

> **Codified.** This vhost is now written by `nginx_setup.sh` (the
> `cpack-ingest.conf` block) on every App-EC2 (re)build — the hand-added
> `/etc/nginx/conf.d/cpack-ingest.conf` on the live host is no longer drift. The
> `server_name` and cert path are driven by `$STAGING_DOMAIN`
> (= `staging.packiot.app`). The literal below is the resolved output.

`/etc/nginx/conf.d/cpack-ingest.conf` (rendered by `nginx_setup.sh`):

```nginx
server {
    listen 8447 ssl;
    server_name cpack-ingest.staging.packiot.app;

    ssl_certificate     /etc/letsencrypt/live/staging.packiot.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/staging.packiot.app/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 1m;   # matches the agent's MaxBodyBytes cap

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

`nginx -t && systemctl reload nginx` after writing it.

### Security-group rule (codified — apply is still USER-gated)

Open **inbound TCP 8447 from CPACK's egress IP ONLY** on the staging App EC2 SG.
Everything else stays denied — the port is not world-open.

**Where it lives.** The staging App EC2 SG, Route53 zone, EIP, and Secrets
Manager bundle are all managed by **`packiot-stack-alpha/terraform/staging`**
(S3 backend) — **not** the sibling `api-terraform` repo (that tree is the
separate prod EKS infra and does not own `staging.packiot.app`). So the rule is
codified here as an **inline `ingress` block** on `aws_security_group.app`
(`terraform/staging/security_groups.tf`), not a standalone
`aws_security_group_rule` — that SG defines its rules inline, and mixing the two
forms makes Terraform revoke the standalone rule on every apply:

```hcl
# terraform/staging/security_groups.tf — inside resource "aws_security_group" "app"
ingress {
  description = "ADR-0042 P1 CPACK Node-RED tee -> sparkplug-agent /v1/tags (CPACK egress /32 only)"
  from_port   = 8447
  to_port     = 8447
  protocol    = "tcp"
  cidr_blocks = ["179.162.112.58/32"]   # CPACK egress /32
}
```

The matching DNS A record (`cpack-ingest.staging.packiot.app` →
`aws_eip.app.public_ip`) is in `terraform/staging/dns.tf`
(`aws_route53_record.cpack_ingest`).

**Still USER-gated:** committing the HCL does not open the port — someone must
`terraform apply`. Until applied, the front-door stays unreachable externally,
which is the desired state for **internal validation** (synthetic-frame test
in-cluster, port still closed). Apply only when the real CPACK tee is scheduled
to go live.

## 3. plc-sim cutover (reversible, NOT applied by default)

`sparkplug-agent-cpack` lives behind the `cpack-tee` compose profile, so a
default `docker compose up` keeps staging on **plc-sim** (synthetic ent3). The
agent uses a **distinct edge_node_id** (`cpack-tee` ≠ plc-sim's node); running
BOTH would double-source ent3 (two SparkPlug edge nodes carrying the same CPACK
metric names → double-count, oee>1.0). So the cutover **stops plc-sim first**:

```bash
# ── CUTOVER: real CPACK tee goes live ──────────────────────────────────────
docker compose -f compose.staging.yml stop plc-sim
docker compose -f compose.staging.yml --profile cpack-tee up -d sparkplug-agent-cpack
# then apply §2 (nginx vhost + SG rule) so the tee can reach :8447

# ── ROLLBACK: back to synthetic sim ────────────────────────────────────────
docker compose -f compose.staging.yml stop sparkplug-agent-cpack
docker compose -f compose.staging.yml start plc-sim
```

## 4. Expected F3 result

The agent-fed F3 should match the plc-sim-fed / prod F3 for the 8 covered
equipment ({47,48,49,51,53,57,61,63}) — the tag_map is EXACTLY plc-sim's proven
feed, and the SparkPlug bytes are decode-identical to plc-sim's cloud-side (the
`session.parity_test` + `httpingest` e2e proof). Concretely, once real data
flows: `equipment_values` (source_type "refactored" → packiot_shadow) climb for
eq 47/48/49/51 + members, the CAgg cascade fills `equipment_runtime_shift/_1hour`,
and OEE for the L8/L5/L3/L4 lines tracks the same band plc-sim produced (L8 within
~5% of prod). Divergence there = a real tag_map / topology gap to chase, not a
transport artifact.

## 5. The tee node (deliverable for the USER)

Copy-paste body: `docs/ingestion/cpack-agent-tee-function.js`. Wiring: a SECOND
wire off CPACK's existing PLC-read node → this `function` → an `http request`
node (method+url taken from `msg`). Set two Node-RED env vars:
`CPACK_AGENT_INGEST_KEY` (the agent's `AGENT_INGEST_API_KEY`, out-of-band) and
optionally `CPACK_AGENT_INGEST_URL` (defaults to the §2 endpoint). The existing
publish path stays wired and untouched.
