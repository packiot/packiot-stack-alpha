.PHONY: help init update dev dev-ps dev-down dev-reset dev-smoke \
        tf-bootstrap tf-init tf-plan tf-apply tf-destroy tf-output tf-fmt tf-validate \
        staging-deploy-key

TF_DIR      = terraform/staging
TF_BOOT_DIR = terraform/staging/bootstrap
GITHUB_REPO = packiot/packiot-stack-alpha
# Account ID is resolved lazily, at most once: the first expansion runs
# `aws sts` and re-defines the variable as its result. Was `:=` (resolved at
# parse time), which made EVERY make target — `make dev` included — call AWS.
AWS_ACCOUNT_ID  = $(eval AWS_ACCOUNT_ID := $$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null))$(AWS_ACCOUNT_ID)
TF_STATE_BUCKET = packiot-terraform-state-$(AWS_ACCOUNT_ID)

# ADR-0060 local dev environment (dev/) — the only local stack (compose.development.yml was removed in P2).
DEV_COMPOSE = docker compose -f dev/compose.yml --env-file dev/.env.dev
# Tier 0 = every service in dev/base.yml (derived, so the list never drifts).
DEV_TIER0   = $(shell docker compose -f dev/base.yml --env-file dev/.env.dev config --services 2>/dev/null)
SVC        ?=

# ── Default ───────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  packiot-stack-alpha — integration orchestration"
	@echo ""
	@echo "  Setup"
	@echo "    init             Clone/update submodules"
	@echo "    update           Pull latest commit for all submodules"
	@echo ""
	@echo "  Local dev environment (ADR-0060, dev/)"
	@echo "    dev              Tier 0 (postgres, rabbitmq, mosquitto, redis, minio)"
	@echo "    dev SVC=\"grafana\" A slice: the service(s) + their depends_on closure"
	@echo "    dev-ps           Show dev containers"
	@echo "    dev-down         Stop + remove dev containers (volumes kept)"
	@echo "    dev-smoke SVC=.. Smoke-check running slices: health + one real request each"
	@echo ""
	@echo "  Staging one-time setup"
	@echo "    staging-deploy-key  Generate + register GitHub deploy key → Secrets Manager"
	@echo ""
	@echo "  Terraform — staging infrastructure (terraform/staging/)"
	@echo "    tf-bootstrap     Create S3 state bucket (run once per AWS account)"
	@echo "    tf-init          Init Terraform with remote S3 backend"
	@echo "    tf-plan          Show execution plan (no changes applied)"
	@echo "    tf-apply         Apply infrastructure changes (prompts for confirmation)"
	@echo "    tf-destroy       Destroy all staging resources (prompts for confirmation)"
	@echo "    tf-output        Print all Terraform outputs (IPs, NS records, URLs)"
	@echo "    tf-fmt           Format all .tf files in-place"
	@echo "    tf-validate      Validate Terraform configuration"
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────
init:
	git submodule update --init --recursive

# dev-setup: first-time developer setup on the development branch.
# Checks out each submodule to its own 'development' branch (not detached HEAD),
# then wipes volumes so the fresh schema is applied on next 'make up'.
update:
	git submodule update --remote --merge

# ── Local dev environment (ADR-0060) ──────────────────────────────────────────
# make dev                  → Tier 0 only
# make dev SVC="grafana"    → grafana + its depends_on closure
# --wait blocks until every started service is healthy (one-shots: exited 0).
dev:
	$(DEV_COMPOSE) up -d --wait $(if $(strip $(SVC)),$(SVC),$(DEV_TIER0))

dev-ps:
	$(DEV_COMPOSE) ps -a

dev-down:
	$(DEV_COMPOSE) down --remove-orphans

# A stale dev volume ("Skipping initialization") never reloads the seed: wipe the dev volumes and start again.
dev-reset:
	$(DEV_COMPOSE) down --remove-orphans -v
	$(DEV_COMPOSE) up -d --wait $(if $(strip $(SVC)),$(SVC),$(DEV_TIER0))

# Health + one real request per service (ADR-0060 D8; the same script CI runs). No SVC → Tier 0.
dev-smoke:
	bash dev/e2e/smoke.sh $(SVC)

# ── Terraform — staging infrastructure ────────────────────────────────────────
# Requires: terraform >= 1.10, aws CLI configured with the packiot account.
# Run tf-bootstrap once per account, then tf-init, tf-plan, tf-apply.

tf-bootstrap:
	@echo "Creating S3 state bucket for account $(AWS_ACCOUNT_ID)..."
	cd $(TF_BOOT_DIR) && terraform init && terraform apply

tf-init:
	@echo "Initialising Terraform with S3 backend (bucket: $(TF_STATE_BUCKET))..."
	cd $(TF_DIR) && terraform init \
		-backend-config="bucket=$(TF_STATE_BUCKET)" \
		-backend-config="key=staging/terraform.tfstate" \
		-backend-config="region=us-east-1" \
		-backend-config="use_lockfile=true" \
		-backend-config="encrypt=true"

tf-validate: tf-fmt
	cd $(TF_DIR) && terraform validate

tf-plan:
	cd $(TF_DIR) && terraform plan

tf-apply:
	cd $(TF_DIR) && terraform apply

tf-destroy:
	cd $(TF_DIR) && terraform destroy

tf-output:
	cd $(TF_DIR) && terraform output

tf-fmt:
	terraform fmt -recursive $(TF_DIR)

# ── Staging one-time setup helpers ────────────────────────────────────────────

# Generate a GitHub deploy key, register it on the repo (read-only), and
# store the private key in Secrets Manager. Run once before make tf-apply.
# Requires: gh (authenticated), aws CLI (packiot account), jq.
staging-deploy-key:
	@echo "Generating ed25519 deploy key..."
	ssh-keygen -t ed25519 -C "staging-ec2-deploy" -f /tmp/staging_deploy_key -N ""
	@echo "Adding public key to $(GITHUB_REPO) deploy keys..."
	gh repo deploy-key add /tmp/staging_deploy_key.pub \
		--title "staging-ec2-deploy" \
		--repo $(GITHUB_REPO)
	@echo "Storing private key in Secrets Manager (packiot/staging/github-deploy-key)..."
	aws secretsmanager create-secret \
		--name packiot/staging/github-deploy-key \
		--region us-east-1 \
		--secret-string "$$(jq -n --arg k "$$(cat /tmp/staging_deploy_key)" '{private_key: $$k}')" \
		|| aws secretsmanager put-secret-value \
			--secret-id packiot/staging/github-deploy-key \
			--region us-east-1 \
			--secret-string "$$(jq -n --arg k "$$(cat /tmp/staging_deploy_key)" '{private_key: $$k}')"
	rm /tmp/staging_deploy_key /tmp/staging_deploy_key.pub
	@echo "Done. Private key is in Secrets Manager; local copy removed."
