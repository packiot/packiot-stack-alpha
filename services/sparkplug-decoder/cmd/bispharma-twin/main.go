// bispharma-twin — a DURABLE, CODIFIED staging TWIN producer for Bispharma
// (enterprise 5, SparkPlug group BISPHARMASTAGING) so the tenant gets a
// continuous, realistic OEE data feed on staging INDEPENDENT of the offline
// factory box. This is GAP-1 "proper fix (a)" from
// docs/clients/bispharma-production-readiness-punchlist.md: a codified
// twin/replay service analogous to CPACK's twin-injector
// (cmd/inject-counter-fixture), parameterized for Bispharma's counters-only,
// member-count-index topology.
//
// ── What it models (CPACK twin-injector parity) ──────────────────────────────
// CPACK's twin (cmd/inject-counter-fixture) publishes a synthetic SparkPlug B
// NBIRTH + NDATA straight to the internal Mosquitto broker under group CPACK;
// the shared sparkplug-decoder (subscribed to spBv1.0/#) decodes it exactly as
// it decodes a real edge tee, and stream-engine writes silver.equipment_values.
// This twin does the SAME, for group BISPHARMASTAGING: it publishes directly to
// Mosquitto (the same internal path CPACK's twin uses) rather than through the
// rawtag HTTP front-door (:8449), so it is decoded by the identical proven path
// and does not depend on the front-door being reachable from inside the VPC
// (the app box cannot hairpin its own public ingest SG). It carries a DISTINCT
// edge_node_id (bispharmastaging-twin) that stamps every row's provenance in the
// decoder logs (publisher "BISPHARMASTAGING/bispharmastaging-twin"), keeping
// twin rows distinguishable from a real feed.
//
// Unlike inject-counter-fixture (one-shot, single hardcoded CPACK metric), this
// is a LONG-RUNNING service: it births the full line member topology once, then
// advances monotonically-increasing absolute totalizers every interval, and
// re-births on an inbound Rebirth NCMD (decoder self-heal after a restart). It
// is COUNTERS-ONLY — it emits ProdConsumedCount (gross) / ProdProcessedCount
// (net) / ProdDefectiveCount (scrap) member leaves and NO MachSpeed/StateCurrent
// (Bispharma has no state/speed signal; counters_only_oee=true).
//
// ── Parameterization (config-as-data) ────────────────────────────────────────
// The set of member count-index leaves is derived at boot from the SAME agent
// tenant config the shared sparkplug-agent loads (docs/clients/tenants/
// bispharma.yaml → TWIN_TENANT_CONFIG): every raw_tag_map entry of the form
//
//	/SP/LINHAS/<LINE>/<MEMBER>/Admin/Prod{Consumed,Processed,Defective}Count/<idx>/Unit
//
// for the configured line becomes a synthetic totalizer. Using the raw_tag_map
// (the generated allowlist, itself derived from the count_index map in
// docs/clients/tenant-profiles/bispharmastaging.yaml) GUARANTEES the emitted
// metric names are exactly the ones the pipeline resolves to the member
// equipment ids that land in silver (e.g. S1INFEED .../168/Unit → equip
// 2000225) — never an unmapped drop.
//
// ── DOUBLE-SOURCE GUARD (READ THIS) ──────────────────────────────────────────
// When the real Bispharma factory box comes back online it publishes the SAME
// group (BISPHARMASTAGING) → the SAME equipment ids. Running this twin AT THE
// SAME TIME as the real feed DOUBLE-COUNTS every totalizer (two writers per
// equipment, the classic two-writer bug). The guard is a single .env flag:
//   - BISPHARMA_TWIN_ENABLED (default false). When false the process IDLES
//     (blocks) — it does not publish. When true it feeds.
// The service is ALWAYS part of the stack (no compose profile — the
// oeecloud-fanout pattern) so a normal `docker compose up -d --remove-orphans`
// deploy keeps it running (durable across deploys) instead of reaping a
// profile-disabled orphan; enabling/disabling is a pure .env flip.
// It MUST be disabled (BISPHARMA_TWIN_ENABLED=false) the moment a real
// BISPHARMASTAGING feed is wired. Its distinct edge_node_id makes twin rows
// identifiable but does NOT prevent the double-count — disabling is the guard.
//
// STAGING ONLY. Never point this at a production broker.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	// One signal-scoped context for the whole process — used by the idle path
	// (disabled) and the publish loop (enabled) alike.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// ── Master enablement gate (default OFF) — the SOLE double-source guard ───
	// This service is ALWAYS part of the staging stack (no compose profile — the
	// oeecloud-fanout pattern), so a normal `docker compose up -d --remove-orphans`
	// deploy keeps it running instead of reaping a profile-disabled orphan. When
	// disabled it IDLES (blocks until SIGTERM) rather than exiting, so
	// restart:unless-stopped never crash-loops it. Enabling is a pure .env flip
	// (BISPHARMA_TWIN_ENABLED=true). DISABLE it the moment a real BISPHARMASTAGING
	// feed is wired, or every totalizer double-counts.
	if !getenvBool("BISPHARMA_TWIN_ENABLED", false) {
		logger.Info("bispharma-twin DISABLED (BISPHARMA_TWIN_ENABLED != true) — idling (double-source guard). " +
			"Enable is a pure .env flip on staging; disable when a real BISPHARMASTAGING feed is active.")
		<-ctx.Done()
		return
	}

	cfg := loadConfig()
	logger.Info("bispharma-twin starting",
		"broker", cfg.broker,
		"group", cfg.group,
		"edge_node", cfg.edgeNode,
		"line", cfg.line,
		"tenant_config", cfg.tenantConfig,
		"interval_sec", int(cfg.interval.Seconds()),
		"rate_per_min", cfg.ratePerMin,
		"scrap_rate", cfg.scrapRate,
	)

	metrics, err := buildMembers(cfg)
	if err != nil {
		logger.Error("build member metrics", "err", err)
		os.Exit(1)
	}
	if len(metrics) == 0 {
		logger.Error("no member count-index leaves found for line — check TWIN_LINE / TWIN_TENANT_CONFIG",
			"line", cfg.line, "tenant_config", cfg.tenantConfig)
		os.Exit(1)
	}
	logger.Info("member count-index leaves resolved",
		"line", cfg.line, "metrics", len(metrics), "first", metrics[0].name)

	tw := &twin{cfg: cfg, logger: logger, metrics: metrics}
	if err := tw.run(ctx); err != nil {
		logger.Error("twin exited", "err", err)
		os.Exit(1)
	}
	logger.Info("bispharma-twin stopped")
}

// ── config ───────────────────────────────────────────────────────────────────

type config struct {
	broker       string
	group        string
	edgeNode     string
	line         string
	tenantConfig string
	interval     time.Duration
	ratePerMin   float64 // line throughput in units/min (drives the totalizer slope)
	scrapRate    float64 // fraction of gross that becomes scrap (0..1)
	clientID     string
}

func loadConfig() config {
	return config{
		broker:       getenv("TWIN_BROKER", "tcp://mosquitto:1883"),
		group:        getenv("TWIN_GROUP", "BISPHARMASTAGING"),
		edgeNode:     getenv("TWIN_EDGE_NODE", "bispharmastaging-twin"),
		line:         getenv("TWIN_LINE", "L01"),
		tenantConfig: getenv("TWIN_TENANT_CONFIG", "/etc/packiot/tenants/bispharma.yaml"),
		interval:     time.Duration(getenvInt("TWIN_INTERVAL_SEC", 15)) * time.Second,
		ratePerMin:   getenvFloat("TWIN_RATE_PER_MIN", 600),
		scrapRate:    getenvFloat("TWIN_SCRAP_RATE", 0.03),
		clientID:     getenv("TWIN_CLIENT_ID", "bispharma-twin"),
	}
}

// ── member metric model ──────────────────────────────────────────────────────

// counterKind is which of the three PackML count leaves a metric carries.
type counterKind int

const (
	kindGross counterKind = iota // ProdConsumedCount  → gross_production
	kindNet                      // ProdProcessedCount → net_production (good)
	kindScrap                    // ProdDefectiveCount → scrap
)

// member is one synthetic monotonic totalizer bound to a full SparkPlug metric
// name + its alias. Members on the same line share the line throughput; each
// carries its own absolute totalizer so gross ≥ net and scrap = gross − net
// hold on every emission (never trips the physics-invariant clamps).
type member struct {
	name  string // full SparkPlug metric name (packml_topic + suffix)
	alias uint64
	memb  string // member segment (S1INFEED, S6OUTPUT, ...)
	kind  counterKind
	val   float64 // current absolute totalizer value
}

// buildMembers parses the agent tenant config and returns one member per
// member-level count-index leaf for the configured line, alias-numbered
// deterministically (sorted by name) so NBIRTH/NDATA agree across restarts.
func buildMembers(cfg config) ([]*member, error) {
	ac, err := agentcfg.Load(cfg.tenantConfig)
	if err != nil {
		return nil, fmt.Errorf("load tenant config %s: %w", cfg.tenantConfig, err)
	}
	prefix := ac.Sparkplug.PackMLTopic // e.g. "BISPHARMASTAGING"
	lineSeg := "/LINHAS/" + cfg.line + "/"

	var out []*member
	for _, e := range ac.RawTagMap {
		s := e.MetricSuffix
		// Scope to the target line's MEMBER count-index leaves only.
		if !strings.Contains(s, lineSeg) {
			continue
		}
		kind, ok := classifyCountLeaf(s)
		if !ok {
			continue // MachSpeed / StateCurrent / Parameter → skip (counters-only)
		}
		memb := memberSegment(s, cfg.line)
		if memb == "" {
			continue // line-direct (no member segment) — twin emits member leaves
		}
		out = append(out, &member{
			name: prefix + s,
			memb: memb,
			kind: kind,
		})
	}
	// Deterministic alias assignment: sort by name, alias = 1..N.
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	for i, m := range out {
		m.alias = uint64(i + 1)
	}
	return out, nil
}

// classifyCountLeaf maps a raw_tag_map suffix to a counter kind. Only the three
// Admin count leaves qualify; everything else (MachSpeed, StateCurrent,
// Parameter…) is not a counter and is skipped (counters-only).
func classifyCountLeaf(suffix string) (counterKind, bool) {
	switch {
	case strings.Contains(suffix, "/Admin/ProdConsumedCount/"):
		return kindGross, true
	case strings.Contains(suffix, "/Admin/ProdProcessedCount/"):
		return kindNet, true
	case strings.Contains(suffix, "/Admin/ProdDefectiveCount/"):
		return kindScrap, true
	}
	return 0, false
}

// memberSegment extracts the member name (segment after the line) from a suffix
// like /SP/LINHAS/L01/S1INFEED/Admin/... → "S1INFEED". Returns "" for a
// line-direct leaf (/SP/LINHAS/L01/Admin/...), which the twin does not emit.
func memberSegment(suffix, line string) string {
	marker := "/LINHAS/" + line + "/"
	i := strings.Index(suffix, marker)
	if i < 0 {
		return ""
	}
	rest := suffix[i+len(marker):] // "S1INFEED/Admin/ProdConsumedCount/168/Unit"
	seg, _, ok := strings.Cut(rest, "/")
	if !ok || seg == "Admin" || seg == "Status" {
		return "" // line-direct
	}
	return seg
}

// ── twin runtime ─────────────────────────────────────────────────────────────

type twin struct {
	cfg     config
	logger  *slog.Logger
	metrics []*member

	mu     sync.Mutex
	seq    uint64
	client paho.Client
}

func (t *twin) run(ctx context.Context) error {
	opts := paho.NewClientOptions().
		AddBroker(t.cfg.broker).
		SetClientID(t.cfg.clientID + "-" + strconv.Itoa(os.Getpid())).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectTimeout(10 * time.Second).
		SetOnConnectHandler(func(_ paho.Client) {
			// (Re)establish the alias table on every (re)connect, then subscribe
			// to Rebirth NCMDs so the decoder can self-heal its alias baseline.
			t.publishBirth()
			t.subscribeRebirth()
			t.logger.Info("connected + NBIRTH published", "broker", t.cfg.broker, "metrics", len(t.metrics))
		})

	t.client = paho.NewClient(opts)
	tok := t.client.Connect()
	if !tok.WaitTimeout(15 * time.Second) {
		return fmt.Errorf("connect timeout to %s", t.cfg.broker)
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}

	tick := time.NewTicker(t.cfg.interval)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			t.client.Disconnect(1000)
			return nil
		case <-tick.C:
			t.advance()
			t.publishData()
		}
	}
}

// advance grows every member's absolute totalizer for one interval. Gross climbs
// at the line rate (± jitter); scrap accrues a fraction of the gross increment;
// net = gross − scrap. All three are kept internally consistent per member so
// the emitted totalizers are monotonic and never violate net ≤ gross.
func (t *twin) advance() {
	t.mu.Lock()
	defer t.mu.Unlock()
	incr := t.cfg.ratePerMin * t.cfg.interval.Minutes()
	// One shared stochastic increment per member segment so its gross/net/scrap
	// totalizers move together (they describe the same physical unit).
	byMember := map[string]float64{}
	for _, m := range t.metrics {
		if _, ok := byMember[m.memb]; !ok {
			byMember[m.memb] = math.Round(incr * (0.85 + 0.30*rand.Float64()))
		}
	}
	for _, m := range t.metrics {
		g := byMember[m.memb]
		scrap := math.Round(g * t.cfg.scrapRate)
		switch m.kind {
		case kindGross:
			m.val += g
		case kindScrap:
			m.val += scrap
		case kindNet:
			m.val += g - scrap
		}
	}
}

func (t *twin) simMetrics(birth bool) []sparkplug.SimMetric {
	out := make([]sparkplug.SimMetric, 0, len(t.metrics))
	for _, m := range t.metrics {
		sm := sparkplug.SimMetric{Alias: m.alias, IsLong: true, Long: int64(m.val)}
		if birth {
			sm.Name = m.name // NBIRTH carries name↔alias; NDATA is alias-only
		}
		out = append(out, sm)
	}
	return out
}

func (t *twin) publishBirth() {
	t.mu.Lock()
	body, err := sparkplug.EncodeSim(t.simMetrics(true), &t.seq, true)
	t.mu.Unlock()
	if err != nil {
		t.logger.Error("encode NBIRTH", "err", err)
		return
	}
	topic := fmt.Sprintf("spBv1.0/%s/NBIRTH/%s", t.cfg.group, t.cfg.edgeNode)
	// Retained per SparkPlug spec so a decoder connecting later still sees the
	// alias table without waiting for a rebirth.
	t.publish(topic, body, true)
}

func (t *twin) publishData() {
	t.mu.Lock()
	body, err := sparkplug.EncodeSim(t.simMetrics(false), &t.seq, false)
	t.mu.Unlock()
	if err != nil {
		t.logger.Error("encode NDATA", "err", err)
		return
	}
	topic := fmt.Sprintf("spBv1.0/%s/NDATA/%s", t.cfg.group, t.cfg.edgeNode)
	t.publish(topic, body, false)
}

func (t *twin) publish(topic string, body []byte, retained bool) {
	tok := t.client.Publish(topic, 0, retained, body)
	if !tok.WaitTimeout(5 * time.Second) {
		t.logger.Warn("publish timeout", "topic", topic)
		return
	}
	if err := tok.Error(); err != nil {
		t.logger.Warn("publish error", "topic", topic, "err", err)
	}
}

// subscribeRebirth wires the decoder's self-heal path: on a "Node Control/
// Rebirth" NCMD (the decoder asks for it after a restart / on an unknown alias),
// re-publish the full NBIRTH so the alias table is re-established.
func (t *twin) subscribeRebirth() {
	topic := fmt.Sprintf("spBv1.0/%s/NCMD/%s", t.cfg.group, t.cfg.edgeNode)
	t.client.Subscribe(topic, 0, func(_ paho.Client, _ paho.Message) {
		t.logger.Info("rebirth NCMD received — re-publishing NBIRTH", "topic", topic)
		t.publishBirth()
	})
}

// ── env helpers ──────────────────────────────────────────────────────────────

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func getenvBool(k string, def bool) bool {
	switch strings.TrimSpace(strings.ToLower(os.Getenv(k))) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

func getenvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			return n
		}
	}
	return def
}

func getenvFloat(k string, def float64) float64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
			return n
		}
	}
	return def
}
