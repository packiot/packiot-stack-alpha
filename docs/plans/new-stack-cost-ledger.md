# New-stack cost ledger — STAGING

Itemized monthly AWS cost of the **staging** stack (us-east-1, account
`639178078294`). Figures are on-demand run-rate; every unit price was confirmed
against the AWS Pricing API and the total cross-checked against Cost Explorer
(`Environment=staging` cost-allocation tag, which is **activated**).

> Scope: `Environment=staging` tag + `packiot-staging-*` names only. Excludes all
> `prod`/`production`/`dev` resources and the legacy `awseb-*` Elastic Beanstalk /
> Bisnago / highbyte / Integration-api estate. Staging is **3 EC2 boxes** — no RDS,
> no ALB, no NAT Gateway, no Client VPN.

_Last verified: 2026-09-02._

## Bottom line

| Category | $/mo |
|---|---|
| EC2 compute | 130.31 |
| EBS | 10.40 |
| Public IPv4 | 7.30 |
| S3 (incl. historian) | 0.09 |
| Secrets Manager | 8.80 |
| WAF | 8.70 |
| Route 53 | 0.65 |
| CloudWatch | ~1.00 |
| **Run-rate total** | **≈ $167 / mo** |
| **Range (low / high)** | **$155 – $175 / mo** |

Cost Explorer (August, `Environment=staging`) billed **$159.15** — the ~$8 gap is
Secrets Manager + IPv4 proration (both added mid-month, ramp to full next month).
Reconciliation is clean.

## EC2 compute (730 h/mo, on-demand)

| Instance | Role | Type | $/hr | $/mo |
|---|---|---|---|---|
| `i-06c9547a2c7091ab7` | app (docker-compose stack) | t4g.large | 0.0672 | 49.06 |
| `i-064bb36d1c454d861` | DB (`10.10.10.89`, self-hosted PG/Timescale) | r7g.large | 0.1071 | 78.18 |
| `i-0d85d171e8e6abaeb` | NAT **instance** | t4g.nano | 0.0042 | 3.07 |
| | | | **subtotal** | **130.31** |

Neither app nor DB is covered by the account's ~$598/mo Savings Plan — both pay
**full on-demand**.

## EBS (all gp3, 3000 IOPS + 125 MB/s baseline = free tier of the volume)

| Volume | Instance | GB | $/mo |
|---|---|---|---|
| `vol-083e14a9f14148369` | app | 64 | 5.12 |
| `vol-0865d84a717d800f6` | db | 64 | 5.12 |
| `vol-07795949eeaf9942e` | nat | 2 | 0.16 |
| | | **130** | **10.40** |

## Public IPv4 (in-use, $0.005/hr = $3.65/mo each — post-2024 charge)

| IP | Attached to | $/mo |
|---|---|---|
| `100.28.20.195` (`packiot-staging-app-eip`) | app | 3.65 |
| NAT instance public IP | nat | 3.65 |
| _(db is private-only)_ | | **7.30** |

## S3 (measured)

| Bucket | Size | $/mo |
|---|---|---|
| `packiot-staging-historian-639178078294` | 24 MB (132 objs) | ~0.00 |
| `packiot-staging-db-backups-…` | 3.69 GB | 0.085 |
| `packiot-staging-configs` | 2.6 KB | ~0.00 |
| | | **~0.09** |

The historian 180-day prune keeps the cold store tiny — 24 MB, no runaway growth.
Athena scan cost is negligible (< $0.01 account-wide).

## Other staging-attributable

| Item | Basis | $/mo |
|---|---|---|
| Secrets Manager (~24 `packiot/staging/*` × $0.40) | run-rate | ~8.80 |
| AWS WAF (staging web ACL + rules) | CE actual | 8.70 |
| Route 53 (`staging.packiot.app` + `staging.packiot.com`) | CE actual | 0.65 |
| CloudWatch (untagged share) | est. | ~1.00 |

## Top 3 cost drivers

1. **DB box `r7g.large` — $78/mo (47%).** Memory-optimized Graviton, self-hosted PG/Timescale.
2. **App box `t4g.large` — $49/mo (29%).**
3. **Fixed overhead — EBS $10.40 + Secrets $8.80 + WAF $8.70 + IPv4 $7.30 ≈ $35/mo (21%).**

## Deliberate money-saving architecture (good calls already in place)

- **DB self-hosted on EC2, not RDS.** An equivalent `db.r7g.large` Multi-AZ is ~$180+/mo — self-hosting saves ~$100/mo.
- **NAT is a `t4g.nano` instance ($3/mo), not a NAT Gateway** (~$32/mo + $0.045/GB) — saves ~$30+/mo.
- **No ALB** — nginx-on-box behind an EIP saves ~$16–25/mo.

## Savings opportunities (not yet taken)

1. **Put app + db under a Compute Savings Plan.** ~$127/mo on-demand; a 1-yr no-upfront Graviton SP is ~30–37% off → **~$40–47/mo**. The account already runs a $598 SP that simply isn't covering these — likely just needs its committed amount raised.
2. **Right-size the DB.** `r7g.large` = 16 GB for a staging DB is probably oversized. Verify utilization on the box first (`free -m` / CloudWatch), then consider `r7g.medium` (~$39/mo) → **~$40/mo**.
3. **Stop staging nights/weekends.** ~40% uptime cuts compute ~55–60% → **~$70/mo** (needs the on-box DB to tolerate clean stop/start; NAT stays up for $3).

Combined, 1+2+3 could take the stack from ~$167 to roughly **$60–90/mo**.

## Account-wide waste (NOT staging — noted for cleanup)

- ~5 **unattached, unnamed Elastic IPs** ≈ $18/mo.
- ~$135/mo of legacy `awseb-*` ALBs (prod/dev Elastic Beanstalk).
