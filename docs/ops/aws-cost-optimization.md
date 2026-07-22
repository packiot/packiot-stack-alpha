# AWS Cost-Optimization Tracker

Read-only audit 2026-07-22 (acct 639178078294). Run-rate ~**$1,670/mo**; total
addressable ~**$250–320/mo (~15–19%)**. **Every command below is a PROD change —
run them yourself, with eyes on. Nothing here was executed.**

## Briefing corrections (important)
- **Two regions**: prod TimescaleDB `ts2pg12` (`r6i.4xlarge`) is in **us-east-2**.
- **No NAT Gateway** in us-east-1 (it's a $3/mo NAT *instance*). The "$100 VPC"
  line ≈ **~$40/mo public IPv4** (24 EIPs) + small bits.
- **Savings Plan is 96% utilized** — do NOT add commitment.
- ⚠️ **No memory metrics** (no CloudWatch agent). DBs are memory-bound — the
  staging DB "swapping" is invisible to its 21% CPU. **Do NOT right-size any DB
  on CPU alone.** Install the CW agent first (`mem_used_percent`, swap).

---
## 🟢 A. Safe hygiene (low risk) — but still verify each
| # | Item | Est $/mo | Note before running |
|---|------|---------|---------------------|
| A1 | **Snapshot backup-loop** — `ts2pg12` imaged by BOTH an AMI job AND AWS Backup; spiked to ~13 snaps/day Jul 21–22. Dedupe to one; add DLM retention (7–14d) both regions. | $20–30 + stops bleed | **URGENT** (actively growing). Adding a DLM *policy* is additive/safe; **pruning the existing backlog deletes data → your call.** |
| A2 | **Orphaned CloudWatch log group** `/aws/eks/piot4/cluster` (50.9 GiB, **EKS cluster deleted**). `aws logs delete-log-group --log-group-name /aws/eks/piot4/cluster --region <r>`. Cap `Back4-API` (14.9 GiB) retention. | $2–3 + hygiene | Verify the group truly maps to a dead cluster before deleting. |
| A3 | **Phantom SimpleAD** ($9.26/mo billed, `describe-directories` empty in 8 regions). Full-region sweep, then delete. | $9 | **Locate first** — not found yet. |

## 🟡 B. Needs your console-confirm (irreversible) — commands ready, you fire
| # | Item | Est $/mo | Confirm |
|---|------|---------|---------|
| B1 | **3 dead us-east-1 ALBs** (12/12/16 requests in 14d vs 81k/7k live). Likely the EB envs behind the stopped `highbyte-tests ×2` + `grafana-upgrade`. | **$48** | Confirm the EB env in the **Elastic Beanstalk console** before terminating the env (deleting the ALB alone won't stop the env). |
| B2 | **4 stopped instances** (cloud9-'23, grafana-upgrade, highbyte-tests ×2) — still bill EBS. Terminate + their volumes. | $8–10 | Confirm none are intentionally parked. |

## 🔵 C. Structural / planned (biggest $, your decision)
| # | Item | Est $/mo | Blocker |
|---|------|---------|---------|
| C1 | **Graviton-migrate prod DB** `ts2pg12` `r6i.4xlarge` → `r7g/r8g.4xlarge`. Biggest single lever. | **$70–105** | pg-on-ARM test + **memory data first** (C0). |
| C2 | Right-size idle: `back4-api-main` (1.2% CPU) t4g.medium→small; `edge-api-main` (1.5%) t3.small→micro; `BI-Gateway` t3.large→medium; `production-app` t4g.medium→small. | $55–60 | Prod touch; **memory data first**. |
| C3 | us-east-2 NAT Gateway → NAT instance (mirror staging) or S3/ECR/Secrets VPC endpoints. | $10–25 | Plan. |
| C4 | `ts2pg12` gp3 bumped to 7000 IOPS/600 MB/s — verify DB needs it over free 3000/125. | $0–12 | Verify DB IO. |
| C5 | Trim in-use public IPv4 (24 EIPs) — move internal instances to private subnets. | ~$15 | Structural. |
| C0 | **Install CloudWatch agent** (mem/swap) — prerequisite for C1/C2 (DBs are memory-bound). | — | Do FIRST. |
| — | Savings Plan top-up | marginal | **Skip** — 96% utilized. |

**Quick+safe ≈ $80–95/mo (A + B) · structural ≈ $180–220/mo (C).**
