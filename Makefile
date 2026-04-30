.PHONY: help init setup up up-infra up-edge up-oeecloud up-api up-operator up-simulator \
        down logs logs-edge logs-oeecloud logs-api logs-infra logs-postgres logs-pubsub logs-adminer logs-operator logs-simulator \
        build build-edge build-oeecloud build-api build-operator build-simulator build-tests \
        restart clean status psql shell-edge shell-oeecloud shell-api shell-operator \
        publish-test update \
        db-equipments db-equipment-values db-packml db-enterprises db-sites db-areas \
        db-events db-uns db-orders db-count \
        watch-values watch-plc watch-pubsub \
        stress-db sim-seed test-integration

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
	@echo "    up-operator      Infra + edge-api + edge-nodered + operator UI"
	@echo "    up-simulator     Start operator activity simulator (Simulator Corp)"
	@echo ""
	@echo "  Individual image builds"
	@echo "    build-edge       Build edge-nodered image"
	@echo "    build-oeecloud   Build oeecloud image"
	@echo "    build-api        Build edge-api image"
	@echo "    build-operator   Build operator UI image"
	@echo "    build-simulator  Build simulator image"
	@echo ""
	@echo "  Logs (follow mode — Ctrl+C to stop)"
	@echo "    logs             Tail all services"
	@echo "    logs-edge        Tail edge-nodered"
	@echo "    logs-oeecloud    Tail oeecloud"
	@echo "    logs-api         Tail edge-api"
	@echo "    logs-postgres    Tail TimescaleDB"
	@echo "    logs-pubsub      Tail PubSub emulator"
	@echo "    logs-adminer     Tail Adminer"
	@echo "    logs-infra       Tail pubsub + postgres + hasura"
	@echo "    logs-simulator   Tail operator simulator"
	@echo ""
	@echo "  Database queries (one-shot)"
	@echo "    db-equipments       List all equipments"
	@echo "    db-packml           List packml_register routing table"
	@echo "    db-enterprises      List enterprises + api keys"
	@echo "    db-sites            List sites"
	@echo "    db-areas            List areas"
	@echo "    db-equipment-values Last 20 equipment_values rows"
	@echo "    db-events           Last 20 equipment_events rows"
	@echo "    db-uns              Last 20 uns_metrics rows"
	@echo "    db-orders           List production_orders"
	@echo "    db-count            Row counts for all key tables"
	@echo ""
	@echo "  Live monitoring (Ctrl+C to stop)"
	@echo "    watch-values     Refresh equipment_values every 2s"
	@echo "    watch-plc        Refresh PLC metric breakdown every 2s"
	@echo "    watch-pubsub     Stream oeecloud logs (shows PubSub activity)"
	@echo ""
	@echo "  Utilities"
	@echo "    psql             Open psql shell in the postgres container"
	@echo "    shell-edge       sh into edge-nodered container"
	@echo "    shell-operator   sh into operator container"
	@echo "    shell-oeecloud   sh into oeecloud container"
	@echo "    shell-api        sh into edge-api container"
	@echo "    publish-test     Publish a minimal test SparkPlug message to PubSub"
	@echo "    stress-db        Stress test: 1000 batch inserts + expensive aggregate"
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

up-operator:
	$(COMPOSE) up -d $(INFRA_SVCS) edge-api edge-nodered operator

up-simulator:
	$(COMPOSE) up -d simulator

# ── Individual builds ─────────────────────────────────────────────────────────
build-edge:
	$(COMPOSE) build edge-nodered

build-oeecloud:
	$(COMPOSE) build oeecloud

build-api:
	$(COMPOSE) build edge-api

build-operator:
	$(COMPOSE) build operator

build-simulator:
	$(COMPOSE) build simulator

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

logs-postgres:
	$(COMPOSE) logs -f postgres

logs-pubsub:
	$(COMPOSE) logs -f pubsub-emulator

logs-adminer:
	$(COMPOSE) logs -f adminer

logs-grafana:
	$(COMPOSE) logs -f grafana

logs-operator:
	$(COMPOSE) logs -f operator

logs-simulator:
	$(COMPOSE) logs -f simulator

# ── Utilities ─────────────────────────────────────────────────────────────────
psql:
	$(COMPOSE) exec postgres psql -U postgres -d packiot

shell-edge:
	$(COMPOSE) exec edge-nodered sh

shell-oeecloud:
	$(COMPOSE) exec oeecloud sh

shell-api:
	$(COMPOSE) exec edge-api sh

shell-operator:
	$(COMPOSE) exec operator sh

PSQL = $(COMPOSE) exec -T postgres psql -U postgres -d packiot

# ── Database queries ──────────────────────────────────────────────────────────
db-equipments:
	@$(PSQL) -c "SELECT id_equipment, nm_equipment, tp_equipment, id_area, id_site FROM equipments ORDER BY id_equipment;"

db-packml:
	@$(PSQL) -c "SELECT id_packml_register, packml_topic, id_equipment, active, id_unit, signal_quality FROM packml_register ORDER BY id_packml_register;"

db-enterprises:
	@$(PSQL) -c "SELECT id_enterprise, nm_enterprise, api_key, active FROM enterprises;"

db-sites:
	@$(PSQL) -c "SELECT id_site, id_enterprise, nm_site FROM sites ORDER BY id_site;"

db-areas:
	@$(PSQL) -c "SELECT id_area, id_site, id_enterprise, nm_area, day_begin FROM areas ORDER BY id_area;"

db-equipment-values:
	@$(PSQL) -c "SELECT ts_value, id_equipment, net_production_incr, scrap_incr, state, mode, speed FROM equipment_values ORDER BY ts_value DESC LIMIT 20;"

db-events:
	@$(PSQL) -c "SELECT id, ts_event, id_equipment, event_type, event_value, txt_event FROM equipment_events ORDER BY ts_event DESC LIMIT 20;"

db-uns:
	@$(PSQL) -c "SELECT ts_value, id_equipment, metric_name, metric_value, metric_type FROM uns_metrics ORDER BY ts_value DESC LIMIT 20;"

db-orders:
	@$(PSQL) -c "SELECT id_production_order, id_equipment, status, ts_start, ts_end FROM production_orders ORDER BY id_production_order DESC LIMIT 20;"

db-count:
	@$(PSQL) -c "\
		SELECT 'equipment_values'  AS tbl, COUNT(*) FROM equipment_values  UNION ALL \
		SELECT 'equipment_events'  AS tbl, COUNT(*) FROM equipment_events  UNION ALL \
		SELECT 'uns_metrics'       AS tbl, COUNT(*) FROM uns_metrics       UNION ALL \
		SELECT 'production_orders' AS tbl, COUNT(*) FROM production_orders UNION ALL \
		SELECT 'packml_register'   AS tbl, COUNT(*) FROM packml_register   UNION ALL \
		SELECT 'equipments'        AS tbl, COUNT(*) FROM equipments        \
		ORDER BY tbl;"

# ── Live monitoring ───────────────────────────────────────────────────────────
watch-values:
	watch -n 2 'docker compose -f compose.integration.yml exec -T postgres \
		psql -U postgres -d packiot -c \
		"SELECT ts_value, id_equipment, net_production_incr, scrap_incr, state, mode, speed \
		 FROM equipment_values ORDER BY ts_value DESC LIMIT 15;"'

watch-plc:
	watch -n 2 'docker compose -f compose.integration.yml exec -T postgres \
		psql -U postgres -d packiot -c \
		"SELECT \
		   CASE WHEN net_production_incr IS NOT NULL THEN '"'"'ProdProcessed'"'"' \
		        WHEN scrap_incr IS NOT NULL           THEN '"'"'ProdDefective'"'"' \
		        WHEN state IS NOT NULL                THEN '"'"'StateCurrent'"'"' \
		        WHEN mode  IS NOT NULL                THEN '"'"'UnitMode'"'"' \
		        WHEN speed IS NOT NULL                THEN '"'"'MachSpeed'"'"' \
		        ELSE '"'"'other'"'"' END AS metric, \
		   COUNT(*) AS rows, \
		   MAX(ts_value) AS latest \
		 FROM equipment_values \
		 GROUP BY 1 ORDER BY latest DESC;"'

watch-pubsub:
	$(COMPOSE) logs -f oeecloud

# ── Operator simulator ────────────────────────────────────────────────────────
# Seed Simulator Corp enterprise with 8 hours of historical operator activity.
# Run once to fill Grafana; the live simulator (make up-simulator) keeps it fresh.
sim-seed:
	@echo "Seeding Simulator Corp enterprise with historical operator data..."
	@$(PSQL) -f /dev/stdin < edge-node-red/db/03-operator-simulator.sql
	@echo "Done. Start live simulator with: make up-simulator"

# ── DB stress simulation ───────────────────────────────────────────────────────
# Inserts 1000 synthetic rows via generate_series, then runs an expensive
# GROUP BY aggregate (mirrors the Grafana OEE query). Useful for testing
# connection pool saturation, TimescaleDB chunk planning, and lock contention.
stress-db:
	@echo "Stress test: inserting 1000 synthetic equipment_values rows..."
	@$(PSQL) -c "INSERT INTO equipment_values (ts_value, id_equipment, net_production_incr, scrap_incr, state, speed) SELECT NOW() - (n || ' seconds')::interval, (CASE WHEN n % 2 = 0 THEN 2 ELSE 4 END), (random()*15)::int, (random()*3)::int, 6, (random()*120)::real FROM generate_series(1, 1000) n ON CONFLICT DO NOTHING; SELECT 'synthetic rows inserted' AS result;"
	@echo "Running expensive Grafana-style aggregate..."
	@$(PSQL) -c "SELECT id_equipment, date_trunc('minute', ts_value) AS bucket, SUM(net_production_incr) AS net, SUM(scrap_incr) AS scrap, ROUND((AVG(speed))::numeric, 1) AS avg_speed, ROUND((SUM(CASE WHEN state=6 THEN 1.0 ELSE 0 END) / NULLIF(COUNT(*),0) * 100)::numeric, 1) AS avail_pct FROM equipment_values WHERE ts_value > NOW() - INTERVAL '1 hour' GROUP BY id_equipment, bucket ORDER BY id_equipment, bucket DESC LIMIT 30;"
	@echo "Stress test complete. Run 'make db-count' to see updated row counts."

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

# ── Integration tests (Layer 2 — end-to-end against live stack) ───────────────
# Builds the test image, runs pytest in a one-shot container on packiot-net,
# tears it down. Stack must already be `make up` for this to be meaningful.
build-tests:
	$(COMPOSE) --profile tests build tests

test-integration: build-tests
	$(COMPOSE) --profile tests run --rm tests
