.PHONY: help init setup up up-infra up-edge up-oeecloud up-api \
        down logs logs-edge logs-oeecloud logs-api logs-api logs-infra \
        build build-edge build-oeecloud build-api \
        restart clean status psql shell-edge shell-oeecloud shell-api \
        publish-test update

COMPOSE     = docker compose -f compose.integration.yml
ENV_FILE    = .env.local

INFRA_SVCS  = pubsub-emulator pubsub-init postgres hasura hasura-init

# ── Default ───────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  packiot-stack-alpha — integration orchestration"
	@echo ""
	@echo "  Setup"
	@echo "    init             Clone/update submodules + copy env examples"
	@echo "    setup            Copy .env.example → .env.local (safe, won't overwrite)"
	@echo "    update           Pull latest commit for all submodules"
	@echo ""
	@echo "  Full stack"
	@echo "    up               Start all services"
	@echo "    down             Stop and remove all containers"
	@echo "    restart          down + up"
	@echo "    clean            down + delete volumes (destructive)"
	@echo "    status           Show running containers"
	@echo "    build            Build all service images"
	@echo ""
	@echo "  Partial stacks (infra always included)"
	@echo "    up-infra         PubSub emulator + TimescaleDB + Hasura only"
	@echo "    up-edge          Infra + edge-nodered"
	@echo "    up-oeecloud      Infra + oeecloud"
	@echo "    up-api           Postgres + edge-api"
	@echo ""
	@echo "  Individual image builds"
	@echo "    build-edge       Build edge-nodered image"
	@echo "    build-oeecloud   Build oeecloud image"
	@echo "    build-api        Build edge-api image"
	@echo ""
	@echo "  Logs"
	@echo "    logs             Tail all logs"
	@echo "    logs-edge        Tail edge-nodered"
	@echo "    logs-oeecloud    Tail oeecloud"
	@echo "    logs-api         Tail edge-api"
	@echo "    logs-infra       Tail pubsub + postgres + hasura"
	@echo ""
	@echo "  Utilities"
	@echo "    psql             Open psql shell in the postgres container"
	@echo "    shell-edge       sh into edge-nodered container"
	@echo "    shell-oeecloud   sh into oeecloud container"
	@echo "    shell-api        sh into edge-api container"
	@echo "    publish-test     Publish a minimal test SparkPlug message to PubSub"
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────
init:
	git submodule update --init --recursive
	@$(MAKE) setup

setup:
	@[ -f $(ENV_FILE) ] \
		&& echo "$(ENV_FILE) already exists — skipping copy" \
		|| (cp .env.example $(ENV_FILE) && echo "Created $(ENV_FILE) — fill in secrets before running make up")

update:
	git submodule update --remote --merge

# ── Full stack ────────────────────────────────────────────────────────────────
up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart: down up

clean:
	$(COMPOSE) down --volumes --remove-orphans

status:
	$(COMPOSE) ps

build:
	$(COMPOSE) build

# ── Partial stacks ────────────────────────────────────────────────────────────
up-infra:
	$(COMPOSE) up -d $(INFRA_SVCS)

up-edge:
	$(COMPOSE) up -d $(INFRA_SVCS) edge-nodered

up-oeecloud:
	$(COMPOSE) up -d $(INFRA_SVCS) oeecloud

up-api:
	$(COMPOSE) up -d postgres edge-api

# ── Individual builds ─────────────────────────────────────────────────────────
build-edge:
	$(COMPOSE) build edge-nodered

build-oeecloud:
	$(COMPOSE) build oeecloud

build-api:
	$(COMPOSE) build edge-api

# ── Logs ──────────────────────────────────────────────────────────────────────
logs:
	$(COMPOSE) logs -f

logs-edge:
	$(COMPOSE) logs -f edge-nodered

logs-oeecloud:
	$(COMPOSE) logs -f oeecloud

logs-api:
	$(COMPOSE) logs -f edge-api

logs-infra:
	$(COMPOSE) logs -f pubsub-emulator postgres hasura

# ── Utilities ─────────────────────────────────────────────────────────────────
psql:
	$(COMPOSE) exec postgres psql -U postgres -d packiot

shell-edge:
	$(COMPOSE) exec edge-nodered sh

shell-oeecloud:
	$(COMPOSE) exec oeecloud sh

shell-api:
	$(COMPOSE) exec edge-api sh

# Publish a minimal test SparkPlug message to the shared PubSub emulator.
# The payload simulates a machine-01 metric update (counter reset, speed=100).
# Adjust topic + data to match your packml_register entries.
publish-test:
	@echo "Publishing test SparkPlug message to PubSub emulator..."
	@DATA=$$(printf '{"timestamp":%s,"metrics":[{"name":"30700","value":1},{"name":"30701","value":100}]}' \
		$$(date +%s%3N) | base64 -w0); \
	curl -sf -X POST \
		http://localhost:8085/v1/projects/packiot-dev/topics/oee-topic:publish \
		-H 'Content-Type: application/json' \
		-d "{\"messages\":[{\"data\":\"$$DATA\",\"attributes\":{\"topic\":\"Dev Enterprise/Dev Site/Dev Area/Line-01/Machine-01/Status/Metric[30700]***TRIGDevice\"}}]}" \
	&& echo "Message published"
