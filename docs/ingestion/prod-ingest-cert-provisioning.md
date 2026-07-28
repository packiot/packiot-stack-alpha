# Prod ingest — per-tenant mTLS cert provisioning

**Status:** DESIGN / DOCUMENTATION ONLY. This file describes the mechanism; it
issues **no real certs** and touches nothing in production. The `openssl` blocks
are the runbook to execute deliberately, per tenant, at onboarding time.

**Anchors:** ADR-0042 §6 (per-tenant mTLS + CN-keyed ACL), production-buildout
roadmap §W2, client-edge bundle PR #624 (the consumer of these certs).

---

## What this provisions

The prod ingest front-door is a mosquitto TLS listener on `:8883`
(`configs/mosquitto/mosquitto-prod-ingest.conf`) that accepts SparkPlug B over
**mTLS** from each client's edge `sparkplug-agent`. Two cert roles exist:

| Role | Who presents it | Verified against | CN |
|------|-----------------|------------------|----|
| **Broker server cert** | the prod broker (to the client) | the client's `uplink_ca` | `ingest.prod.packiot.app` (SAN) |
| **Per-tenant client cert** | the client agent (to the broker) | the broker's `cafile` (the prod-ingest CA) | `CN=<TENANT_UPPER>` (e.g. `CN=BISPHARMA`) |

The **CN is load-bearing**: `use_identity_as_username true` turns the client
cert CN into the mosquitto username, and `prod-ingest.acl`'s `pattern readwrite
spBv1.0/%u/#` scopes that tenant to its own SparkPlug group namespace only.
The client **never names its own tenant on the wire** — the cert asserts it, the
ACL binds it (ADR-0042 §6). CN **must equal** the agent's `sparkplug.group_id`
(`BISPHARMA`), because the agent publishes to `spBv1.0/BISPHARMA/...`.

---

## Trust model (default: one private CA for both legs)

The default, self-consistent design is a **single private "prod-ingest CA"**
that signs **both** the broker server cert and every per-tenant client cert.
Then the client's `uplink_ca` = this same CA (verifies the broker), and the
broker's `cafile` = this same CA (verifies the client). This matches the agent
descriptor's explicit `uplink_ca_ref` (`secret://packiot/prod/<tenant>/uplink-ca`).

**Alternative for the server leg:** use the existing public wildcard
`*.prod.packiot.app` ACM/Let's-Encrypt cert as the broker `certfile`/`keyfile`
(public trust — the client can then verify with system roots), and keep the
private prod-ingest CA only as the broker `cafile` for **client** verification.
Pick one; the mosquitto config comments both. mTLS **always** needs the private
CA for the client leg regardless — client-cert verification cannot use public CAs.

---

## Step 1 — create the prod-ingest CA (once, kept offline)

```bash
# Root CA private key (keep OFFLINE / in a locked secret; never on the broker box).
openssl genrsa -out ingest-ca.key 4096

# Self-signed CA cert, 10-year (root CAs are long-lived; leaf certs rotate).
openssl req -x509 -new -nodes -key ingest-ca.key -sha256 -days 3650 \
  -subj "/O=Packiot/OU=prod-ingest/CN=Packiot Prod Ingest CA" \
  -out ingest-ca.pem
```

`ingest-ca.pem` (public) → the broker `cafile` **and** every client's `uplink_ca`.
`ingest-ca.key` (private) → offline; used only to sign new leaf certs.

## Step 2 — broker server cert (once per broker cert lifetime)

```bash
openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem \
  -subj "/O=Packiot/OU=prod-ingest/CN=ingest.prod.packiot.app" \
  -out server.csr
# SAN is mandatory — modern TLS clients ignore CN for hostname matching.
printf "subjectAltName=DNS:ingest.prod.packiot.app" > server-ext.cnf
openssl x509 -req -in server.csr -CA ingest-ca.pem -CAkey ingest-ca.key \
  -CAcreateserial -days 825 -sha256 -extfile server-ext.cnf -out server-cert.pem
```

`server-cert.pem` + `server-key.pem` → mounted at `/mosquitto/certs/` on the
prod broker (see mosquitto-prod-ingest.conf). Skip this step if using the
wildcard-cert alternative for the server leg.

## Step 3 — per-tenant client cert (once per tenant, at onboarding)

```bash
TENANT_UPPER=BISPHARMA         # MUST equal the agent's sparkplug.group_id
openssl genrsa -out uplink-key.pem 2048
openssl req -new -key uplink-key.pem \
  -subj "/O=Packiot/OU=client-edge/CN=${TENANT_UPPER}" \
  -out ${TENANT_UPPER}.csr
openssl x509 -req -in ${TENANT_UPPER}.csr -CA ingest-ca.pem -CAkey ingest-ca.key \
  -CAcreateserial -days 825 -sha256 -out uplink-cert.pem
```

Deliver to the client-edge bundle as the three files its `.env` resolves the
`secret://` refs to (bundle #624 `.env.template`):
`uplink-cert.pem`, `uplink-key.pem`, `uplink-ca.pem` (= `ingest-ca.pem`).

---

## Where certs live (Secrets Manager, matching the agent descriptor)

The generated `bispharma-agent.yaml` references:

```
uplink_tls_cert_ref: secret://packiot/prod/bispharma/uplink-cert
uplink_tls_key_ref:  secret://packiot/prod/bispharma/uplink-key
uplink_ca_ref:       secret://packiot/prod/bispharma/uplink-ca
```

Store each per-tenant material set as an AWS Secrets Manager secret under
`packiot/prod/<tenant>/uplink-*`. At deploy the client-edge resolves these to
files under `./certs/` (gitignored). Cloud-side, the broker `cafile`/`server-*`
material is stored under `packiot/production/ingest-broker/*` and mounted on the
App EC2. **No cert is committed to git** — `docs/clients/edge-deployment/.gitignore`
(bundle #624) and `configs/mosquitto/` carry configs only.

> Terraform note: these secrets are provisioned separately (real key material is
> not generated by `terraform apply`). Scaffold empty `aws_secretsmanager_secret`
> shells in `secrets.tf` if you want the ARNs to pre-exist, then
> `put-secret-value` the material out-of-band — same pattern as the
> `github-runner` PAT secret.

---

## Rotation

- **Client cert** (`CN=<tenant>`): re-run Step 3, `put-secret-value` the new
  material, redeploy the client-edge bundle. Old cert stops being trusted only
  when you revoke; overlap is safe (both signed by the same CA).
- **Broker server cert**: re-run Step 2, replace `/mosquitto/certs/server-*`,
  restart the broker. Clients keep trusting it (same CA).
- **CA**: expensive (every leaf re-issues). 10-year root avoids this in practice.

---

## How the pieces wire together (this PR)

| Piece | File | Role |
|-------|------|------|
| SG rule 8883 ← client /32 | `terraform/production/security_groups.tf` | admits the mTLS uplink from the client egress only |
| DNS `ingest.prod.packiot.app` → EIP | `terraform/production/dns.tf` | the host the agent dials |
| Broker TLS listener + mTLS | `configs/mosquitto/mosquitto-prod-ingest.conf` | terminates mTLS, CN→username |
| CN-keyed tenant ACL | `configs/mosquitto/prod-ingest.acl` | scopes each CN to `spBv1.0/<CN>/#` |
| Client cert consumer | client-edge bundle #624 | presents `CN=<tenant>` over the uplink |
| **This doc** | — | how the certs above are issued (do NOT issue real ones here) |
