# Self-hosted org CI runner — runbook

**Status:** scaffold (nothing applied, no runner registered yet)
**Terraform:** `terraform/production/ci_runner.tf` + `user_data/ci_runner_setup.sh`
**Owner:** platform/ops

---

## Why this exists

The `packiot` GitHub org is on the **Free plan**. Free includes a shared pool of
**2,000 GitHub-hosted Actions minutes / month** across ALL private repos. When
that pool is exhausted, **CI halts org-wide** — queued jobs simply never start
until the next billing cycle. That has already bitten us.

A **self-hosted runner** is metered differently: GitHub only counts minutes on
*GitHub-hosted* runners. A runner you host = **unlimited free minutes**. We pay
only for the tiny EC2 box (~$30/mo on-demand, ~$9/mo spot) instead of being
throttled to zero.

**First consumer:** `front4` CI. It's a **private repo with no external
contributors**, which is exactly the safe case for self-hosted (see the security
section on why public repos are dangerous). Other private repos can adopt the
same runner by using the same label — see "Scaling".

---

## What the scaffold provisions

| Resource | Detail |
|---|---|
| `aws_instance.ci_runner` | **t3.medium** (2 vCPU / **4 GB** — a 2 GB box OOMs on the front4 Vite build), **x86_64** AL2023, on-demand |
| `aws_subnet.ci_runner` | Dedicated **`10.20.20.0/24`** public subnet — isolated from prod app (`10.20.0.0/24`) and DB (`10.20.10.0/24`) subnets |
| `aws_security_group.ci_runner` | **NO inbound** (SSM-only access). Egress restricted to **443 / 80 / DNS(53) / NTP(123)** — not wide-open |
| `aws_iam_role.ci_runner` | SSM managed policy + read of **exactly one** secret (the PAT). Cannot read `packiot/production/*` app secrets |
| `aws_secretsmanager_secret.ci_runner_github_pat` | **`packiot/production/ci-runner-github-pat`** — terraform-managed with a **placeholder** value (real token never committed) |

It is **not** the prod OEE box: separate instance, separate subnet, separate SG,
separate least-privilege IAM role.

---

## PAT: scope + storage

The runner registers itself at **org scope**, which requires a token that can
manage org runners. Create **one** of:

- **Fine-grained PAT** (preferred): github.com → Settings → Developer settings →
  Fine-grained tokens → Generate. Resource owner = **`packiot`** org.
  Organization permissions → **"Self-hosted runners" = Read and write**
  (this is the `manage_runners:org` capability). Set a short expiry + calendar a
  rotation reminder.
- **Classic PAT**: github.com → Settings → Developer settings → Tokens (classic)
  → scope **`admin:org`**.

Store it in Secrets Manager (this **replaces** the terraform placeholder;
`ignore_changes = [secret_string]` means terraform will not revert it):

```bash
aws secretsmanager put-secret-value \
  --secret-id packiot/production/ci-runner-github-pat \
  --secret-string '{"pat":"github_pat_XXXXXXXX","org":"packiot"}' \
  --region us-east-1
```

> The PAT is the ONLY long-lived credential. The box exchanges it for a
> **short-lived (1h) registration token** via
> `POST /orgs/packiot/actions/runners/registration-token` on every (re-)register
> — the registration token itself is never stored.

---

## Registration approach

- **Scope:** ORG (`--url https://github.com/packiot`) — one runner serves every
  private repo in the org, not a single repo.
- **Labels:** `self-hosted, linux, x64, packiot-ci`. Workflows opt in with
  `runs-on: [self-hosted, linux, packiot-ci]`. The `packiot-ci` discriminator
  means only workflows that *explicitly ask* for this runner land on it.
- **User:** a dedicated **non-root `runner`** user (in the `docker` group).
- **Service:** installed via `svc.sh install runner` as a **systemd** unit →
  survives reboot, runs as the non-root user.
- **`--replace` + `--unattended`:** idempotent re-registration; the helper is
  safe to re-run.

### Ephemeral vs long-lived — trade-off (and our choice)

| | Long-lived (default, `ci_runner_ephemeral = false`) | Ephemeral (`--ephemeral`) |
|---|---|---|
| Per-job isolation | No — state can leak between jobs | Yes — fresh registration per job |
| After a job | Stays registered, picks up the next job | Deregisters; needs re-provision |
| Ops complexity | Simple — one box, one service | Needs JIT config or instance-replace loop to re-register |

**Recommendation: start long-lived** (the default). It's the simplest thing that
gives us unlimited minutes today. Ephemeral is the more secure posture for
untrusted workloads, but front4 is a trusted private repo, and ephemeral without
an auto-reprovision mechanism means the runner vanishes after the first job.
Revisit ephemeral (with a reprovision loop) if we ever run less-trusted jobs.

---

## Bring-up (ordered — do these in sequence)

```
1. Create the PAT (manage_runners:org / admin:org)      ← you, on github.com
2. put-secret-value → packiot/production/ci-runner-github-pat
3. cd terraform/production && terraform plan   (review; expect ONLY new ci_runner_* resources)
4. terraform apply
5. Verify the runner shows "Idle":
     https://github.com/organizations/packiot/settings/actions/runners
6. ONLY THEN flip front4's runs-on (different repo — see below)
```

> **Order matters.** If you flip front4's `runs-on` to the self-hosted label
> *before* the runner is Idle, those jobs **queue forever** (no runner with the
> label exists to pick them up).

If step 5 shows nothing after ~3–4 min, SSM in and inspect:

```bash
aws ssm start-session --target <instance-id> --region us-east-1
sudo cat /var/log/packiot-ci-runner-init.log     # bootstrap log
sudo /opt/packiot/register-ci-runner.sh          # re-run registration (idempotent)
sudo systemctl status 'actions.runner.*'         # the systemd service
```

Common causes: PAT still the placeholder (helper fail-closes with a clear
message), wrong PAT scope, or wrong org name.

---

## The front4 consumer flip (DO NOT do it in this repo — different repo)

After the runner is **Idle**, in the **front4** repo edit
`.github/workflows/ci.yml`:

```yaml
# before
jobs:
  build:
    runs-on: ubuntu-latest
# after
jobs:
  build:
    runs-on: [self-hosted, linux, packiot-ci]
```

This flip **must come after** the runner is online (else jobs queue forever).
Any other private repo can adopt the same runner by using the same
`runs-on: [self-hosted, linux, packiot-ci]` label — no new infra needed.

---

## Cost

| Option | ~Monthly | Notes |
|---|---|---|
| t3.medium **on-demand** | ~$30 | Simple, always available |
| t3.medium **spot** | ~$9 | ~70% cheaper; a spot interruption only kills the in-flight job (GitHub re-queues it). Safe here — no data on the box. To use: add a `spot_price` / `instance_market_options` block, or an ASG with a spot request |
| gp3 40 GB root | ~$3.20 | Docker/npm cache headroom |

Either way it pays for itself the first time the 2,000-min Free cap would have
halted CI org-wide.

---

## Security notes

- **Private-repo-only.** Self-hosted runners are safe for repos where you trust
  every contributor. **Never** attach a self-hosted runner to a **public** repo
  (or one that accepts fork PRs): a forked pull request can run arbitrary code in
  its workflow, and that code executes **on your runner, inside your VPC, with
  your IAM role**. GitHub explicitly warns against this. front4 is a private repo
  with no external contributors → safe. Gate adoption of new repos on this rule.
- **Non-root user.** The runner runs as the `runner` user, not root. It IS in the
  `docker` group (so jobs can build containers) — which is effectively
  root-equivalent via the Docker socket. Accepted trade-off for a trusted-repo CI
  box; if you later run less-trusted jobs, drop `docker` group + use rootless
  Docker or a sandbox.
- **No inbound.** The SG has zero ingress rules. Access is **SSM Session Manager
  only** (pure egress — the agent dials out). No SSH, no public listener.
- **Egress-restricted.** Only 443/80/DNS/NTP out — not the wide-open `-1` the
  app/db boxes use.
- **Least-privilege IAM.** The instance role reads **only** the one PAT secret;
  it cannot read the prod DB/Hasura/edge-api secrets.
- **Isolated subnet.** Its own `10.20.20.0/24`, separate from prod app/DB.

---

## Teardown / deregister

```bash
# 1. Deregister the runner cleanly (removes it from the org list):
aws ssm start-session --target <instance-id> --region us-east-1
cd /opt/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
# fetch a REMOVE token the same way registration does, then:
sudo -u runner ./config.sh remove --token <removal-token>
#   (removal token: POST /orgs/packiot/actions/runners/remove-token)

# 2. Destroy the infra (targeted, so you don't touch the rest of prod):
cd terraform/production
terraform destroy \
  -target=aws_instance.ci_runner \
  -target=aws_iam_instance_profile.ci_runner \
  -target=aws_security_group.ci_runner \
  -target=aws_subnet.ci_runner
# (the PAT secret has a 7-day recovery window; delete separately if desired)

# 3. Revoke the PAT on github.com.
```

If a runner box was terminated *without* a clean deregister, delete the stale
"offline" entry manually in org → Settings → Actions → Runners.

---

## Scaling to a second runner

The registration is **org-scoped** and label-driven, so a second box needs no new
workflow wiring — just more capacity behind the same `packiot-ci` label:

1. Add a second instance (either `count`/`for_each` on `aws_instance.ci_runner`,
   or copy the resource with a distinct `Name`). Each self-registers with the
   same labels and appears as its own entry in the org runners list.
2. GitHub load-balances queued jobs across all Idle runners sharing the label.
3. For elastic scale, graduate to **actions-runner-controller** (ARC) on EKS or
   an ASG of spot runners — out of scope for this scaffold, but the label
   contract (`packiot-ci`) stays the same so no consumer workflow changes.

---

## References

- GitHub — [About self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
- GitHub — [Adding self-hosted runners (org scope)](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub — [Self-hosted runner security](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners) (why public repos are dangerous)
- ADR-0005 (`docs/adr/0005-edge-nodered-self-hosted-runner-deploys.md`) — the per-factory runner pattern this reuses the shape of
- `terraform/production/ec2.tf` — the prod app box's repo-scoped runner (the pattern this generalizes to org scope on a dedicated box)
