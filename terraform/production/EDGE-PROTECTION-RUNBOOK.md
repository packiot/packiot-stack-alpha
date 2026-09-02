# Edge Protection Runbook — CloudFront + WAF + ACM in front of production

**Terraform:** `terraform/production/edge.tf` (+ minimal edits to `main.tf`,
`dns.tf`, `security_groups.tf`).

This runbook takes production from "every `<svc>.prod.packiot.app` A-record points
straight at the App EIP, 443 world-open" to "all HTTP traffic enters through a
WAF-protected CloudFront distribution and the origin only accepts CloudFront."

The dangerous parts (DNS cutover, SG lockdown) are gated behind **two default-off
variables**, so `terraform apply` on this branch is a **no-op for live traffic**.
You flip the variables one at a time, validating between each.

---

## What gets created eagerly (safe — zero traffic impact)

Applying with the defaults (`edge_cutover=false`, `edge_origin_lock=false`) creates:

| Resource | Notes |
|---|---|
| `aws_acm_certificate.edge` (+ validation records + validation) | `*.prod.packiot.app`, SANs `prod.packiot.app`, `dash.packiot.app`. us-east-1. DNS-validated into the correct zones. |
| `aws_wafv2_web_acl.edge` | scope CLOUDFRONT, us-east-1. Rate-limit (block) + 4 AWS managed groups (in **count** mode by default). |
| `aws_cloudfront_distribution.edge` | aliases `*.prod.packiot.app` + `dash.packiot.app`; origin `origin.prod.packiot.app`; CachingDisabled + AllViewer; WAF attached. |
| `aws_route53_record.origin` | `origin.prod.packiot.app` A → App EIP. The non-fronted hostname CloudFront dials. |
| `random_password.origin_verify` | Shared secret CloudFront stamps as `X-Origin-Verify`. |

None of these change where `<svc>.prod.packiot.app` resolves and none change the
SG. Live traffic is untouched.

---

## The variables you will flip

| Variable | Default | Effect when flipped |
|---|---|---|
| `edge_cutover` | `false` | `true` → `<svc>.prod.packiot.app` + `dash.packiot.app` become ALIAS → CloudFront (the A→EIP copies go dormant). **DNS cutover.** |
| `waf_managed_rules_mode` | `"count"` | `"block"` → the 4 AWS managed rule groups enforce their block actions (were observe-only). |
| `edge_origin_lock` | `false` | `true` → App SG 443 admits **only** the CloudFront prefix list `pl-3b927c52` (was `0.0.0.0/0`). **SG lockdown.** |

Rollback for any step = set the variable back to its default and `apply`.

---

## Staged rollout

### (a) Apply with everything off — creates the edge, zero prod impact

```bash
cd terraform/production
make tf-init   # (or terraform init with the production backend)
terraform apply
# edge_cutover=false, edge_origin_lock=false, waf_managed_rules_mode="count"
```

Grab the outputs:

```bash
terraform output edge_cloudfront_domain_name      # dXXXX.cloudfront.net
terraform output edge_cloudfront_distribution_id
terraform output -raw edge_origin_verify_secret   # sensitive — used in step (c)
```

Wait for the distribution to reach `Deployed` (a few minutes) and for ACM to show
`ISSUED` (DNS validation — the records are created for you).

> ⚠️ The ACM validation needs `prod.packiot.app` NS delegation live in the parent
> zone (already wired by `dns.tf`). If validation hangs, confirm delegation.

### (b) Validate CloudFront serves each vhost — BEFORE touching DNS

CloudFront is live but nothing points at it yet. Test each vhost by forcing the
Host header + resolving the alias hostname to a CloudFront IP:

```bash
CF=$(terraform output -raw edge_cloudfront_domain_name)
CF_IP=$(dig +short "$CF" | head -1)

for svc in api hasura grafana rabbitmq adminer operator csadmin; do
  echo "== $svc =="
  curl -sS -o /dev/null -w '%{http_code}\n' \
    --resolve "$svc.prod.packiot.app:443:$CF_IP" \
    "https://$svc.prod.packiot.app/"
done

# dash too:
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve "dash.packiot.app:443:$CF_IP" "https://dash.packiot.app/"
```

Expect the same status codes you'd get hitting the origin directly (200 / 302 to
SSO / 401, per service). If a service breaks, it's almost always because a header
isn't reaching nginx — the AllViewer origin-request policy forwards Host + cookies
+ auth, so this should be rare. **Do not proceed until every vhost looks right.**

### (c) Add the `X-Origin-Verify` check on the nginx host (host-managed)

CloudFront already stamps `X-Origin-Verify: <secret>` on every origin request.
Make nginx reject anything lacking it, so a direct-to-EIP caller gets 403. This is
**host-managed** (not Terraform — nginx config lives on the box).

Get the secret:

```bash
terraform output -raw edge_origin_verify_secret
```

Add to **each** `server { … }` block that serves a `*.prod.packiot.app` vhost
(ideally via a shared `include` snippet):

```nginx
# Reject anything that didn't come through CloudFront.
if ($http_x_origin_verify != "PUT-THE-SECRET-HERE") {
    return 403;
}
```

Then `nginx -t && systemctl reload nginx`.

> ⚠️ **Grace / ordering note:** add this check *after* step (b) proves CloudFront
> reaches the origin, and while DNS still points at the EIP directly. The moment
> the check is live, **direct** browser hits to `<svc>.prod.packiot.app` (still
> A→EIP at this point) will 403 — so treat (c) and (d) as a tight pair and keep the
> window short, or temporarily allow an empty value during the transition. The
> `auth.prod.packiot.app` and `ingest.prod.packiot.app` vhosts are NOT fronted by
> CloudFront (see "Out of scope" below) — do **not** add the check to those server
> blocks or you'll 403 legitimate SSO / mTLS traffic.
>
> `if` inside a `server`/`location` block is the standard nginx idiom for a bare
> `return` (this is the one `if` use nginx's "if is evil" caveat explicitly blesses).

### (d) Flip the DNS cutover → CloudFront

```bash
terraform apply -var 'edge_cutover=true'
```

`<svc>.prod.packiot.app` + `dash.packiot.app` now ALIAS → CloudFront. Watch:

```bash
for svc in api hasura grafana rabbitmq adminer operator csadmin; do
  echo "== $svc =="; curl -sS -o /dev/null -w '%{http_code}\n' "https://$svc.prod.packiot.app/"
done
curl -sS -o /dev/null -w '%{http_code}\n' "https://dash.packiot.app/"
```

Give Route53 a minute (TTL 60 on the old A-records). Verify SSO login end-to-end
through `auth.prod.packiot.app` (still direct — see scope note).

> If `dash.packiot.app` already had a **manual** A-record in the parent
> `packiot.app` zone, remove it first — an ALIAS and an A record for the same name
> conflict and the apply will error.

**Rollback:** `terraform apply -var 'edge_cutover=false'` → back to A→EIP.

### (e) Enforce the WAF managed rule groups

After watching CloudWatch (`packiot-prod-edge-*` metrics) + sampled requests for
false positives in count mode:

```bash
terraform apply -var 'edge_cutover=true' -var 'waf_managed_rules_mode=block'
```

**Rollback:** set `waf_managed_rules_mode=count`.

### (f) Lock the origin down to CloudFront — LAST

Only after (d) is proven healthy and steady:

```bash
terraform apply \
  -var 'edge_cutover=true' \
  -var 'waf_managed_rules_mode=block' \
  -var 'edge_origin_lock=true'
```

App SG 443 now admits **only** the CloudFront prefix list `pl-3b927c52`. Direct
`https://<eip>` is refused at the network layer. Ports 22 / 80 / 8883 are
untouched (80 stays open for Let's Encrypt http-01 renewals).

> ⚠️ **Before flipping this**, resolve `auth.prod.packiot.app` (and any other
> direct-to-origin 443 vhost). It is **not** in the cutover set, so it still
> resolves A→EIP. Once 443 is CloudFront-only, direct traffic to `auth.prod` is
> dropped and SSO breaks. Either (1) add `auth` to the CloudFront path first — its
> hostname is already covered by the `*.prod.packiot.app` alias + cert, so you only
> need to point its Route53 record at CloudFront — or (2) leave 443 open and rely
> on the `X-Origin-Verify` check for origin protection instead of the SG lock. Pick
> one deliberately; do not flip the lock with `auth` still direct-to-EIP.

**Rollback:** `terraform apply -var 'edge_origin_lock=false'` → 443 world-open again.

---

## Full rollback (any point)

Set all three back to defaults and apply:

```bash
terraform apply \
  -var 'edge_cutover=false' \
  -var 'edge_origin_lock=false' \
  -var 'waf_managed_rules_mode=count'
```

DNS returns to A→EIP and the SG returns to world-open 443. Removing the nginx
`X-Origin-Verify` check (step (c)) is a manual host action. The CloudFront/WAF/ACM
resources remain (harmless, unattached from live traffic) unless you `destroy` them.

---

## Out of scope / wrinkles (read before flipping (f))

- **`auth.prod.packiot.app`** — NOT in the cutover set (`dns.tf`
  `aws_route53_record.auth` still A→EIP). Covered by the wildcard cert + CloudFront
  alias, so it *can* be fronted, but this change leaves it direct. **Decide on it
  before `edge_origin_lock=true`** (see step (f) warning).
- **`ingest.prod.packiot.app:8883`** — mTLS SparkPlug, TCP not HTTP. Must **never**
  go through CloudFront. Stays A→EIP; 8883 SG rule (client `/32` allow-list)
  untouched. Do not add the nginx `X-Origin-Verify` check to it.
- **Ports 8444 / 8445** — not present in the current prod SG (`security_groups.tf`
  only has 22/80/443/8883). Nothing to do; if they're ever added, they are NOT
  fronted by CloudFront.
- **`X-Origin-Verify` rotation** — it's a `random_password`; changing it means a
  Terraform apply (new header value) + updating the nginx check in the same window.
