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
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/httpingest"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawmqtt"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/unmapped"
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
	logger.Info("sparkplug-agent starting",
		"group_id", cfg.Sparkplug.GroupID,
		"edge_node_id", cfg.Sparkplug.EdgeNodeID,
		"internal_broker", cfg.Sparkplug.InternalBroker,
		"uplink_broker", cfg.Sparkplug.UplinkBroker,
		"raw_topic", cfg.Sparkplug.RawTopic,
		"tags", len(cfg.RawTagMap))

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

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

	up := uplink.New(uplink.Config{
		BrokerURL:  cfg.Sparkplug.UplinkBroker,
		ClientID:   "sparkplug-agent-uplink-" + cfg.Sparkplug.EdgeNodeID + "-" + fmt.Sprint(os.Getpid()),
		GroupID:    cfg.Sparkplug.GroupID,
		EdgeNodeID: cfg.Sparkplug.EdgeNodeID,
	}, pub, ob, store.SnapshotForBirth, logger)

	// Prometheus registry (Go + process runtime + the agent drop counter).
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	dropped := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "sparkplug_agent_raw_dropped_total",
		Help: "Raw-tag messages dropped, by reason (queue_full|unmapped|decode_error).",
	}, []string{"reason"})
	reg.MustRegister(dropped)

	// ADR-0045 §2.4a P0 — "reject-don't-drop." A tag whose suffix is not in the
	// raw_tag_map is still dropped (we can't type-and-publish an unknown tag),
	// but every drop is now OBSERVABLE: a bounded-cardinality counter + a
	// throttled WARN + an opt-in verbose /healthz dump of the distinct unmapped
	// set. This is what turns "L6's inferred count index silently vanished"
	// (#601) into a debuggable, surfaced onboarding signal.
	unmappedTags := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "sparkplug_agent_unmapped_tags_total",
		Help: "Raw tags dropped because their suffix is not in raw_tag_map, by tenant group + line/machine segment + reason. Nonzero during onboarding ⇒ a tag (often a count index) maps to nothing and its data is vanishing.",
	}, []string{"group", "segment", "reason"})
	reg.MustRegister(unmappedTags)
	unmappedReporter := unmapped.New(
		cfg.Sparkplug.GroupID,
		unmappedTags,
		logger,
		getenvBool("AGENT_UNMAPPED_VERBOSE", false),
		unmappedLogWindow(),
	)

	// ingest is the SHARED pipeline entry point: resolve each raw tag against
	// the tag_map and RBE-apply the mapped ones to the tagstore. BOTH the
	// internal MQTT subscriber (Mode-B / full architecture) and the HTTP
	// front-door (Mode-A direct-to-ingest tee) call it, so the two front-doors
	// feed one tagstore→session→uplink path — and observe unmapped drops
	// identically. Returns (accepted, total): accepted resolved to a mapped
	// metric; the rest were dropped-with-metric.
	ingest := func(tags []rawtag.RawTag) (accepted, total int) {
		return ingestTags(tags, resolver, store, func(suffix string) {
			dropped.WithLabelValues("unmapped").Inc()
			unmappedReporter.Observe(suffix)
		})
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
	multi.Add(unmappedReporter) // ADR-0045 P0: unmapped-tag DQ surface on /healthz
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

// ingestTags is the shared resolve→apply loop, extracted so both front-doors
// share ONE code path (and so it is unit-testable without a live broker). Each
// tag is resolved against the raw_tag_map: a mapped tag is RBE-applied to the
// store; an UNMAPPED tag is NOT applied (it cannot be typed/published) and is
// handed to onUnmapped for observation (metric + throttled WARN). Returns
// (accepted, total).
func ingestTags(tags []rawtag.RawTag, r *resolver, store *tagstore.Store, onUnmapped func(suffix string)) (accepted, total int) {
	for _, t := range tags {
		if _, _, ok := r.Resolve(t.Metric); !ok {
			onUnmapped(t.Metric)
			continue
		}
		store.Apply(t)
		accepted++
	}
	return accepted, len(tags)
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

// unmappedLogWindow throttles the per-suffix unmapped-tag WARN. Default is the
// package default (once/hour per distinct suffix). AGENT_UNMAPPED_LOG_WINDOW_SEC=0
// logs each distinct suffix exactly once for the process lifetime; a positive
// value re-logs every N seconds so the signal re-surfaces.
func unmappedLogWindow() time.Duration {
	if v := os.Getenv("AGENT_UNMAPPED_LOG_WINDOW_SEC"); v != "" {
		return time.Duration(getenvInt("AGENT_UNMAPPED_LOG_WINDOW_SEC", 0)) * time.Second
	}
	return unmapped.DefaultLogWindow
}

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
