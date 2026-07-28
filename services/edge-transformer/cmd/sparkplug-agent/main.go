// sparkplug-agent — ADR-0042 Tier-2 transmission plane (P0 MVP).
//
// It consumes raw tag values (plain JSON) from a connectivity Node-RED over an
// INTERNAL loopback MQTT broker, runs a full SparkPlug B edge-node session
// (alias-ASSIGN, NBIRTH/NDATA/NDEATH, rolling seq + rebirth, report-by-
// exception, store-and-forward), and publishes SparkPlug B to the cloud
// edge-transformer — which decodes it exactly as it decodes plc-sim /
// s7-reader / a native PLC (one ingest contract for every tenant, ADR-0032).
//
// It is s7-reader/plc-sim with the PLC input swapped for the internal raw-tag
// feed. Everything heavy is reused: internal/{sparkplug,outbox}; the
// internal/mqtt subscriber shape; internal/{health,log}. The genuinely-new
// pieces (alias allocator, RBE, session state machine, NDEATH-via-LWT) live in
// internal/agent/*.
//
// Pipeline:
//
//	rawmqtt (internal broker) → rawtag.Decode → tagstore.Apply (RBE)
//	  tick: tagstore.DrainDirty → session.BuildNDATA → encode → outbox.Enqueue
//	  uplink: onConnect rebirth-then-drain; periodic drain; NDEATH Last-Will
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/httpingest"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/onboardapi"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawmqtt"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/uplink"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/health"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

func main() {
	// Distroless has no shell — self-probe /healthz for docker HEALTHCHECK.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfgPath := getenv("AGENT_CONFIG", "")
	if len(os.Args) > 2 && os.Args[1] == "--config" {
		cfgPath = os.Args[2]
	}
	if cfgPath == "" {
		fmt.Fprintln(os.Stderr, "sparkplug-agent: --config <path> or AGENT_CONFIG is required")
		os.Exit(1)
	}

	logger := setupLogger(getenv("LOG_LEVEL", "info"))

	cfg, err := agentcfg.Load(cfgPath)
	if err != nil {
		logger.Error("config load", "err", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// ── register-driven tag map (task #13, ADR-0009 / ADR-0042) ───────────────
	// Flag-gated + additive: default OFF keeps the static YAML raw_tag_map
	// byte-for-byte. ON builds the tag map from packml_register + the tenant
	// conversion profile — the config-not-code replacement for hand-editing the
	// per-client raw_tag_map (PR #590). A load failure here is fatal (a partial
	// tag map would silently drop metrics), the same fail-closed discipline as
	// the static loader.
	tagSource := "static_yaml"
	if getenvBool("AGENT_TAGMAP_FROM_REGISTER", false) {
		if err := loadTagMapFromRegister(ctx, cfg, logger); err != nil {
			logger.Error("register tag-map load", "err", err)
			os.Exit(1)
		}
		tagSource = "packml_register"
	}

	// ── parameter decomposition (task #54 follow-up, ADR-0042) ────────────────
	// Flag-gated + additive: default OFF = current behaviour (a bare
	// "/Status/Parameter" is unmapped → dropped, and Phase-9 line aggregation
	// never fires on real CPACK data). ON loads the tenant profile's
	// parameter_decomposition rule; the ingest closure then rewrites each
	// inbound bare-Parameter tag to its canonical numbered leaf using the tag's
	// PackML parameter id — giving the Calc its Parameter30700 (and 30701/30750/
	// 30751/30758) inputs. Load failure is fatal (fail-closed, same as above).
	var decomposer *tenantprofile.Profile
	if getenvBool("AGENT_PARAM_DECOMPOSITION", false) {
		profPath := os.Getenv("AGENT_PROFILE_PATH")
		if profPath == "" {
			logger.Error("AGENT_PARAM_DECOMPOSITION=true requires AGENT_PROFILE_PATH")
			os.Exit(1)
		}
		prof, err := tenantprofile.LoadProfile(profPath)
		if err != nil {
			logger.Error("param-decomposition profile load", "err", err)
			os.Exit(1)
		}
		// A mis-pointed AGENT_PROFILE_PATH must not silently apply another
		// tenant's decomposition. (Tenant is optional in the schema; enforce
		// only when set — the same guard the register loader uses.)
		if prof.Tenant != "" && prof.Tenant != cfg.Sparkplug.GroupID {
			logger.Error("param-decomposition profile tenant mismatch",
				"profile_tenant", prof.Tenant, "agent_group_id", cfg.Sparkplug.GroupID)
			os.Exit(1)
		}
		if prof.ParameterDecomposition.SourceLeaf == "" {
			logger.Error("AGENT_PARAM_DECOMPOSITION=true but profile has no parameter_decomposition.source_leaf",
				"profile", profPath)
			os.Exit(1)
		}
		decomposer = prof
		logger.Info("parameter decomposition enabled",
			"source_leaf", prof.ParameterDecomposition.SourceLeaf,
			"params", len(prof.ParameterDecomposition.Params))
	}

	logger.Info("sparkplug-agent starting",
		"group_id", cfg.Sparkplug.GroupID,
		"edge_node_id", cfg.Sparkplug.EdgeNodeID,
		"internal_broker", cfg.Sparkplug.InternalBroker,
		"uplink_broker", cfg.Sparkplug.UplinkBroker,
		"raw_topic", cfg.Sparkplug.RawTopic,
		"tag_source", tagSource,
		"tags", len(cfg.RawTagMap))

	// ── pipeline construction ────────────────────────────────────────────
	resolver := newResolver(cfg)
	aliases := aliasmap.New()
	pub := session.New(resolver, aliases)
	store := tagstore.New()

	ob, err := outbox.Open(outbox.Config{Path: getenv("OUTBOX_PATH", "/var/lib/edge-transformer/agent-outbox.db")})
	if err != nil {
		logger.Error("outbox open", "err", err)
		os.Exit(1)
	}
	defer ob.Close()

	// Mode-B mTLS material (ADR-0042 §6). The agentcfg descriptor holds the
	// cert/key/CA as secret:// REFERENCES only; the deploy resolves them to
	// files (AWS Secrets Manager → mounted secret) and points these env vars at
	// the RESOLVED PATHS. Unset ⇒ Mode-A loopback (tcp://, no TLS). A partial
	// set fails closed (never a silent plaintext downgrade).
	tlsCfg, err := uplink.LoadTLSConfig(uplink.TLSFiles{
		CertFile: os.Getenv("AGENT_UPLINK_TLS_CERT"),
		KeyFile:  os.Getenv("AGENT_UPLINK_TLS_KEY"),
		CAFile:   os.Getenv("AGENT_UPLINK_CA"),
	})
	if err != nil {
		logger.Error("uplink mTLS config", "err", err)
		os.Exit(1)
	}
	if tlsCfg == nil && strings.HasPrefix(cfg.Sparkplug.UplinkBroker, "ssl://") {
		// An ssl:// broker with no cert material is almost always a misconfig
		// (the WAN crossing needs the per-tenant cert). Warn loudly; paho will
		// still attempt server-auth-only TLS against the system roots.
		logger.Warn("uplink_broker is ssl:// but no AGENT_UPLINK_TLS_* files supplied — "+
			"connecting without a client cert (the broker ACL will likely reject this)",
			"broker", cfg.Sparkplug.UplinkBroker)
	}

	up := uplink.New(uplink.Config{
		BrokerURL:  cfg.Sparkplug.UplinkBroker,
		ClientID:   "sparkplug-agent-uplink-" + cfg.Sparkplug.EdgeNodeID + "-" + fmt.Sprint(os.Getpid()),
		GroupID:    cfg.Sparkplug.GroupID,
		EdgeNodeID: cfg.Sparkplug.EdgeNodeID,
		TLS:        tlsCfg,
	}, pub, ob, store.SnapshotForBirth, logger)

	// Prometheus registry (Go + process runtime + the agent drop counter).
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	dropped := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "sparkplug_agent_raw_dropped_total",
		Help: "Raw-tag messages dropped, by reason (queue_full|unmapped|decode_error).",
	}, []string{"reason"})
	reg.MustRegister(dropped)
	decomposed := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "sparkplug_agent_param_decomposed_total",
		Help: "Bare-Parameter raw tags rewritten to a canonical numbered leaf, by PackML parameter id.",
	}, []string{"param_id"})
	reg.MustRegister(decomposed)

	// task #31: rebirths triggered by an inbound "Node Control/Rebirth" NCMD.
	// This is how the cloud edge-transformer self-heals its alias/counter
	// baseline after a restart — it asks us to rebirth, we re-publish NBIRTH.
	rebirths := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "sparkplug_agent_rebirths_total",
		Help: "Full NBIRTH re-publishes triggered by an inbound Rebirth NCMD (task #31).",
	})
	reg.MustRegister(rebirths)
	up.SetRebirthMetric(rebirths.Inc)

	// ingest is the SHARED pipeline entry point: resolve each raw tag against
	// the tag_map and RBE-apply the mapped ones to the tagstore. BOTH the
	// internal MQTT subscriber (Mode-B / full architecture) and the HTTP
	// front-door (Mode-A direct-to-ingest tee) call it, so the two front-doors
	// feed one tagstore→session→uplink path. Returns (accepted, total):
	// accepted resolved to a mapped metric; the rest were dropped-with-metric.
	ingest := func(tags []rawtag.RawTag) (accepted, total int) {
		for _, t := range tags {
			// Parameter decomposition (flag-gated): rewrite a bare, id-carrying
			// "/Status/Parameter" tag to its canonical numbered leaf BEFORE the
			// allowlist lookup, so the numbered entry (e.g. Parameter30700) both
			// resolves here and publishes under the name the Calc keys on. A
			// tag that doesn't match the rule is returned unchanged. `t` is a
			// range copy, so mutating t.Metric is local to this iteration.
			if decomposer != nil && t.ParamID != 0 {
				if newSuffix, ok := decomposer.DecomposeParameterSuffix(t.Metric, t.ParamID); ok {
					t.Metric = newSuffix
					decomposed.WithLabelValues(strconv.Itoa(t.ParamID)).Inc()
				}
			}
			if _, _, ok := resolver.Resolve(t.Metric); !ok {
				dropped.WithLabelValues("unmapped").Inc()
				continue
			}
			store.Apply(t)
			accepted++
		}
		return accepted, len(tags)
	}

	// Internal-broker subscriber: decode JSON → RBE-apply mapped tags.
	subCfg := rawmqtt.DefaultConfig()
	subCfg.BrokerURL = cfg.Sparkplug.InternalBroker
	subCfg.ClientID = "sparkplug-agent-raw-" + cfg.Sparkplug.EdgeNodeID + "-" + fmt.Sprint(os.Getpid())
	subCfg.TopicFilter = cfg.Sparkplug.RawTopic
	subCfg.StaleThreshold = staleThreshold()
	sub := rawmqtt.New(subCfg, func(_ context.Context, topic string, body []byte) error {
		tags, err := rawtag.Decode(body)
		if err != nil {
			dropped.WithLabelValues("decode_error").Inc()
			return err
		}
		ingest(tags)
		return nil
	}, logger)
	sub.SetDroppedMetric(func(reason string) { dropped.WithLabelValues(reason).Inc() })

	// ── health / metrics server ──────────────────────────────────────────
	multi := health.NewMulti()
	multi.Add(sub)
	multi.Add(up)
	healthAddr := fmt.Sprintf(":%d", healthPort())
	hsrv := health.New(healthAddr, multi, reg, logger)
	hsrv.Start()

	// ── HTTP raw-tag front-door (ADR-0042 P1 — Mode-A direct-to-ingest) ───
	// The tee POSTs the rawtag envelope straight at the agent, skipping the
	// per-tenant connectivity Node-RED for the first proof. Strictly additive
	// — the MQTT subscriber above stays wired for Mode-B / the full
	// architecture. Enabled only when AGENT_HTTP_INGEST_ENABLED=true AND a key
	// is present: an enabled-but-keyless config fails closed (auth is never
	// optional), the same discipline as ingest-shim's INGEST_API_KEY.
	var ingestSrv *http.Server
	if getenvBool("AGENT_HTTP_INGEST_ENABLED", false) {
		key := os.Getenv("AGENT_INGEST_API_KEY")
		if key == "" {
			logger.Error("AGENT_HTTP_INGEST_ENABLED=true but AGENT_INGEST_API_KEY is empty — refusing to serve ingest with auth disabled")
			os.Exit(1)
		}
		ingestOutcomes := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "sparkplug_agent_http_ingest_total",
			Help: "HTTP raw-tag ingest requests by outcome (received|accepted|rejected_auth|rejected_scope|rejected_bad).",
		}, []string{"outcome"})
		reg.MustRegister(ingestOutcomes)
		hi := httpingest.New(httpingest.Config{
			APIKey:       key,
			ScopeGroup:   cfg.Sparkplug.GroupID, // agent serves exactly one tenant
			MaxBodyBytes: int64(getenvInt("AGENT_INGEST_MAX_BODY_BYTES", 0)),
		}, ingest, ingestOutcomes, logger)
		ingestAddr := fmt.Sprintf(":%d", getenvInt("AGENT_INGEST_PORT", 9104))
		ingestSrv = &http.Server{Addr: ingestAddr, Handler: hi.Handler()}
		go func() {
			logger.Info("http raw-tag ingest listening", "addr", ingestAddr, "scope", cfg.Sparkplug.GroupID)
			if err := ingestSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				logger.Error("http ingest server exited", "err", err)
				cancel()
			}
		}()
	}

	// ── onboard control-plane API (ADR-0045 P1 — config-as-data) ──────────
	// A separate, authenticated `POST /v1/onboard/generate` front-door that turns
	// one client descriptor into the four onboarding artifacts over the wire, so
	// edge-api / CS-Admin can generate a tenant's config server-to-server. It is
	// UNRELATED to the tenant ingest plane (its own listener + its own bearer
	// key), and dark by default: mounted only when ONBOARD_API_ENABLED=true AND an
	// ONBOARD_API_KEY is present (enabled-but-keyless fails closed — auth is never
	// optional, the same discipline as the ingest front-door above).
	var onboardSrv *http.Server
	if getenvBool("ONBOARD_API_ENABLED", false) {
		key := os.Getenv("ONBOARD_API_KEY")
		if key == "" {
			logger.Error("ONBOARD_API_ENABLED=true but ONBOARD_API_KEY is empty — refusing to serve the onboard API with auth disabled")
			os.Exit(1)
		}
		onboardOutcomes := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "sparkplug_agent_onboard_generate_total",
			Help: "Onboard /v1/onboard/generate requests by outcome (received|generated|rejected_auth|rejected_bad|error).",
		}, []string{"outcome"})
		reg.MustRegister(onboardOutcomes)
		oapi := onboardapi.New(onboardapi.Config{
			APIKey:       key,
			MaxBodyBytes: int64(getenvInt("ONBOARD_API_MAX_BODY_BYTES", 0)),
		}, onboardOutcomes, logger)
		onboardAddr := fmt.Sprintf(":%d", getenvInt("ONBOARD_API_PORT", 9105))
		onboardSrv = &http.Server{Addr: onboardAddr, Handler: oapi.Handler()}
		go func() {
			logger.Info("onboard API listening", "addr", onboardAddr)
			if err := onboardSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				logger.Error("onboard API server exited", "err", err)
				cancel()
			}
		}()
	}

	// ── run subscriber + uplink + tick loop ──────────────────────────────
	go func() {
		if err := sub.Run(ctx); err != nil && ctx.Err() == nil {
			logger.Error("raw subscriber exited", "err", err)
			cancel()
		}
	}()
	go func() {
		if err := up.Run(ctx); err != nil && ctx.Err() == nil {
			logger.Error("uplink exited", "err", err)
			cancel()
		}
	}()

	tick := time.NewTicker(time.Duration(getenvInt("AGENT_TICK_SEC", 5)) * time.Second)
	defer tick.Stop()
	logger.Info("sparkplug-agent running", "health_addr", healthAddr)

	for {
		select {
		case <-ctx.Done():
			logger.Info("sparkplug-agent stopping")
			shutctx, sc := context.WithTimeout(context.Background(), 5*time.Second)
			if ingestSrv != nil {
				_ = ingestSrv.Shutdown(shutctx)
			}
			if onboardSrv != nil {
				_ = onboardSrv.Shutdown(shutctx)
			}
			_ = hsrv.Shutdown(shutctx)
			sc()
			return
		case <-tick.C:
			dirty := store.DrainDirty()
			if len(dirty) == 0 {
				continue
			}
			// A brand-new tag ⇒ rebirth (freeze its alias) BEFORE any NDATA
			// references it. The rebirth's full snapshot carries the new
			// values, so we skip NDATA this tick (ADR-0042 §2.2).
			if pub.NeedsRebirth(dirty) {
				if err := up.Rebirth(ctx); err != nil {
					logger.Warn("rebirth (new tag) failed — will rebirth on next connect", "err", err)
				}
				continue
			}
			nd, err := pub.BuildNDATA(dirty)
			if err != nil {
				logger.Error("build NDATA", "err", err)
				continue
			}
			body, err := sparkplug.Encode(nd)
			if err != nil {
				logger.Error("encode NDATA", "err", err)
				continue
			}
			// Encode-then-buffer: the drain loop publishes with QoS1 + PUBACK.
			if err := up.EnqueueData(ctx, body); err != nil {
				logger.Error("outbox enqueue", "err", err)
			}
		}
	}
}

// loadTagMapFromRegister replaces cfg.RawTagMap with a map built from
// packml_register + the tenant conversion profile (task #13). It reads the
// profile from AGENT_PROFILE_PATH, dials Postgres from the DB_* env (only here,
// only when the flag is on), fetches the tenant's equipment rows, synthesizes
// the canonical suffix→type map, and installs it (re-validated). The tenant is
// scoped by the profile's enterprise_id — the cross-tenant guard.
func loadTagMapFromRegister(ctx context.Context, cfg *agentcfg.Config, logger *slog.Logger) error {
	profPath := os.Getenv("AGENT_PROFILE_PATH")
	if profPath == "" {
		return fmt.Errorf("AGENT_TAGMAP_FROM_REGISTER=true requires AGENT_PROFILE_PATH")
	}
	prof, err := tenantprofile.LoadProfile(profPath)
	if err != nil {
		return fmt.Errorf("load profile: %w", err)
	}
	// Guard: a profile's tenant must match the agent it configures, so a
	// mis-pointed AGENT_PROFILE_PATH can't silently build another tenant's map.
	if prof.Tenant != "" && prof.Tenant != cfg.Sparkplug.GroupID {
		return fmt.Errorf("profile tenant %q != agent group_id %q", prof.Tenant, cfg.Sparkplug.GroupID)
	}
	if prof.EnterpriseID == 0 {
		return fmt.Errorf("profile enterprise_id is required for the register loader")
	}

	dsn, err := registerDSN()
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("pgx pool: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("db ping: %w", err)
	}

	fetcher := agentcfg.NewPGRegisterFetcher(pool)
	rows, err := fetcher.FetchEquipment(ctx, prof.EnterpriseID, prof.TenantPrefix)
	if err != nil {
		return fmt.Errorf("fetch equipment: %w", err)
	}
	entries, err := agentcfg.BuildRawTagMapFromRegister(prof, rows)
	if err != nil {
		return fmt.Errorf("build tag map: %w", err)
	}
	if err := cfg.SetRawTagMap(entries); err != nil {
		return fmt.Errorf("install tag map: %w", err)
	}
	logger.Info("register-driven tag map built",
		"tenant", prof.Tenant,
		"enterprise_id", prof.EnterpriseID,
		"equipment_rows", len(rows),
		"tags", len(entries))
	return nil
}

// registerDSN builds a postgres DSN. AGENT_REGISTER_DSN wins if set (a full
// URL); otherwise it is assembled from DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/
// DB_NAME with proper percent-encoding — the same DB_* convention the sibling
// services use.
func registerDSN() (string, error) {
	if v := os.Getenv("AGENT_REGISTER_DSN"); v != "" {
		return v, nil
	}
	user := os.Getenv("DB_USER")
	pass := os.Getenv("DB_PASSWORD")
	if user == "" || pass == "" {
		return "", fmt.Errorf("register loader needs AGENT_REGISTER_DSN or DB_USER+DB_PASSWORD (+DB_HOST/DB_PORT/DB_NAME)")
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(user, pass),
		Host:   fmt.Sprintf("%s:%d", getenv("DB_HOST", "postgres"), getenvInt("DB_PORT", 5432)),
		Path:   "/" + getenv("DB_NAME", "packiot"),
	}
	q := u.Query()
	q.Set("sslmode", getenv("DB_SSLMODE", "disable"))
	q.Set("application_name", "sparkplug-agent-register")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// resolver implements session.Resolver over the agent's raw_tag_map.
type resolver struct {
	prefix string
	byName map[string]entry // metric suffix → resolved name + datatype
}

type entry struct {
	name string
	dt   sparkplug.DataType
}

func newResolver(cfg *agentcfg.Config) *resolver {
	r := &resolver{prefix: cfg.Sparkplug.PackMLTopic, byName: make(map[string]entry, len(cfg.RawTagMap))}
	for _, e := range cfg.RawTagMap {
		r.byName[e.MetricSuffix] = entry{name: e.FullName(cfg.Sparkplug.PackMLTopic), dt: datatypeOf(e.Type)}
	}
	return r
}

func (r *resolver) Resolve(suffix string) (string, sparkplug.DataType, bool) {
	e, ok := r.byName[suffix]
	if !ok {
		return "", 0, false
	}
	return e.name, e.dt, true
}

// datatypeOf maps a config type token to a SparkPlug datatype. Config is
// validated (agentcfg) so this is total.
func datatypeOf(t string) sparkplug.DataType {
	switch t {
	case "double":
		return sparkplug.DataType_Double
	case "float":
		return sparkplug.DataType_Float
	case "long":
		return sparkplug.DataType_Int64
	case "int":
		return sparkplug.DataType_Int32
	case "bool":
		return sparkplug.DataType_Boolean
	case "string":
		return sparkplug.DataType_String
	default:
		return sparkplug.DataType_Double
	}
}

// setupLogger builds a JSON slog logger tagged service=sparkplug-agent (the
// sibling-cmd pattern; internal/log hardcodes service=edge-transformer, which
// is wrong for this binary).
func setupLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch strings.ToLower(level) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	return slog.New(h).With(slog.String("service", "sparkplug-agent"))
}

func healthPort() int { return getenvInt("HEALTH_PORT", 9103) }

// staleThreshold: MQTT_STALE_THRESHOLD_SECONDS <= 0 disables idle checks
// (staging loopback with no live source is idle by design).
func staleThreshold() time.Duration {
	if v := os.Getenv("MQTT_STALE_THRESHOLD_SECONDS"); v != "" {
		var n int
		fmt.Sscanf(v, "%d", &n)
		return time.Duration(n) * time.Second
	}
	return 0 // rawmqtt default (60s)
}

// runHealthcheck self-probes /healthz (distroless has no shell/curl).
func runHealthcheck() int {
	url := fmt.Sprintf("http://127.0.0.1:%d/healthz", healthPort())
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: GET %s: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: read body: %v\n", err)
		return 1
	}
	var meta struct {
		Healthy bool `json:"healthy"`
	}
	if err := json.Unmarshal(body, &meta); err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: parse body: %v\n", err)
		return 1
	}
	if !meta.Healthy {
		fmt.Fprintf(os.Stderr, "healthcheck: not healthy: %s\n", string(body))
		return 1
	}
	return 0
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func getenvInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		var n int
		fmt.Sscanf(v, "%d", &n)
		return n
	}
	return d
}

// getenvBool parses a truthy env var (true/1/yes, case-insensitive). Anything
// else — including unset — is the default.
func getenvBool(k string, d bool) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(k)))
	switch v {
	case "true", "1", "yes", "on":
		return true
	case "false", "0", "no", "off":
		return false
	default:
		return d
	}
}
