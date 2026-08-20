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
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/aliasmap"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/counterderive"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/deriver"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/httpingest"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/numeric"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/onboardapi"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawmqtt"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/session"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tagstore"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/unmapped"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/uplink"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/health"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/outbox"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
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

	// ── register-driven tag map + per-tenant cutover flip (ADR-0045 P2a) ──────
	// Which tag map this tenant boots with. Precedence:
	//   AGENT_TAGMAP_FROM_REGISTER (global override) > client_descriptors.status
	//   (per-tenant, DB-driven — edge-api's cutover endpoint sets it to 'cutover').
	// register.go builds the map from packml_register + the tenant profile; the
	// default stays the static YAML raw_tag_map byte-for-byte. Fail-safe: no
	// profile / no DSN / unreachable DB / missing descriptor row / non-cutover
	// status all keep the static map — never a silent flip, never a crash. Only
	// a DEFINITE signal (override, or status==cutover) builds the register map,
	// and a register build that was explicitly selected but fails is fatal (a
	// partial map would silently drop metrics). Cutover is a BOOT read (Option A):
	// a mid-run flip applies on the agent's next restart.
	tagSrc, boot, err := resolveTagMap(ctx, cfg, logger)
	if err != nil {
		logger.Error("tag-map resolution", "err", err)
		os.Exit(1)
	}
	tagSource := "static_yaml"
	if tagSrc.UseRegister {
		tagSource = "packml_register"
	}

	// ── live-capture OBSERVE posture (ADR-0045 Phase-2b) ──────────────────────
	// Whether this boot records what count indices/topics actually arrive from a
	// live tee, so CS can promote descriptor entries inferred→confirmed. Two
	// gates: the master flag AGENT_CAPTURE_ENABLED (dark by default) AND the
	// per-tenant client_descriptors.status == "captured" (the observe posture,
	// read at boot by resolveTagMap on the SAME pool). Off ⇒ zero hot-path cost.
	// The recorder REUSES the register pool (kept alive past boot only when
	// observing) — never a second pool. Fail-safe: any DB/parse error is a
	// logged drop, never a block or crash of the ingest path.
	captureEnabled := getenvBool("AGENT_CAPTURE_ENABLED", false)
	observing := boot != nil && capture.ShouldObserve(captureEnabled, boot.status)
	// The register pool is boot-transient by default; keep it open ONLY when the
	// recorder will write through it, else close it now (Phase-2a behaviour).
	if boot != nil && boot.pool != nil {
		if observing {
			defer boot.pool.Close()
		} else {
			boot.pool.Close()
			boot.pool = nil
		}
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

	// ── agent-side DERIVE stage (ADR-0045 P2c) ────────────────────────────────
	// Additive + config-driven: built from the tenant profile's `derived` rules
	// (loaded by resolveTagMap into boot.profile). It synthesizes canonical counts
	// for equipment whose PLC emits an analog rate (integral) or split registers
	// (sum) instead of a counter. A profile with no derived rules yields an empty
	// deriver whose Process is a no-op, so this is safe to build unconditionally.
	// The Emit suffixes are already allowlisted (SynthesizeEquipment), so the
	// synthesized counts resolve on the shared ingest path like any other tag.
	var derive *deriver.Deriver
	if boot != nil && boot.profile != nil {
		derive = deriver.New(boot.profile)
		if !derive.Empty() {
			logger.Info("agent-side derive stage enabled",
				"derived_rules", len(boot.profile.Derived))
		} else {
			derive = nil // no rules → skip the Process call entirely
		}
	}

	// ── agent-side COUNTER-DERIVE stage (ADR-0045) ────────────────────────────
	// Config-driven + additive: built from the raw_tag_map entries that carry a
	// counter_derive mode (the generator stamps it from the client descriptor's
	// tag map). It synthesizes the gross/net/scrap counts a factory does NOT
	// physically sense — the declared-config replacement for CPACK's hand-written
	// Calc_Counters. A raw_tag_map with no counter_derive modes yields an empty
	// stage whose Process is a no-op, so building it unconditionally is free.
	var cderive *counterderive.Stage
	{
		entries := make([]counterderive.Entry, 0, len(cfg.RawTagMap))
		for _, e := range cfg.RawTagMap {
			if e.CounterDerive != "" {
				entries = append(entries, counterderive.Entry{Suffix: e.MetricSuffix, Mode: e.CounterDerive})
			}
		}
		if s := counterderive.New(entries); !s.Empty() {
			cderive = s
			logger.Info("agent-side counter-derive stage enabled", "count_groups", len(entries))
		}
	}

	logger.Info("sparkplug-agent starting",
		"group_id", cfg.Sparkplug.GroupID,
		"edge_node_id", cfg.Sparkplug.EdgeNodeID,
		"internal_broker", cfg.Sparkplug.InternalBroker,
		"uplink_broker", cfg.Sparkplug.UplinkBroker,
		"raw_topic", cfg.Sparkplug.RawTopic,
		"tag_source", tagSource,
		"tag_source_reason", tagSrc.Reason,
		"emit_definitive_birth", getenvBool("EMIT_DEFINITIVE_BIRTH", false),
		"birth_all_mapped", getenvBool("AGENT_BIRTH_ALL_MAPPED", false),
		"tags", len(cfg.RawTagMap))

	// ── pipeline construction ────────────────────────────────────────────
	// ADR-0046 step 2 (EMIT_DEFINITIVE_BIRTH, default OFF, following SHADOW_EMIT_*):
	// OFF ⇒ the current string-name NBIRTH, byte-unchanged (a no-op deploy).
	// ON ⇒ each NBIRTH counter metric additionally carries its role-typed
	// properties (counter_role/source_ref/device_key), the definitive birth.
	emitDefinitiveBirth := getenvBool("EMIT_DEFINITIVE_BIRTH", false)
	// ── birth-completeness (CPACK 2026-08-13 line-count regression fix) ───────
	// Default OFF = byte-unchanged births (a no-op deploy). ON makes NBIRTH cover
	// the FULL raw_tag_map — every line/machine metric gets a stable alias even if
	// it was idle at connect — so a sparse line's later NDATA is decodable at the
	// cloud immediately, independent of rebirth timing. Set on the CLIENT-box agent
	// (edge-cpack-agent), where the SparkPlug session lives.
	birthAllMapped := getenvBool("AGENT_BIRTH_ALL_MAPPED", false)
	resolver := newResolver(cfg)
	aliases := aliasmap.New()
	// ADR-0046 task #18: the DECLARED device_key per full metric name, sourced from
	// the tag map (client-descriptor origin). Passed to the session so definitive
	// birth emits the declared identity; absent entries fall back to the derivation.
	pub := session.New(resolver, aliases,
		session.WithDefinitiveBirth(emitDefinitiveBirth),
		session.WithDeviceKeys(deviceKeysFromTagMap(cfg)),
		session.WithBirthAllMapped(birthAllMapped))
	if birthAllMapped {
		logger.Info("birth-all-mapped ENABLED — NBIRTH covers the full raw_tag_map",
			"mapped_metrics", len(cfg.RawTagMap))
	}
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
	// ADR-0045 P0: turn the silent unmapped-tag drop (a suffix not in raw_tag_map,
	// so its data vanishes — the #601/onboarding failure mode) into a surfaced DQ
	// signal: a per-segment counter + a throttled WARN + a /healthz component.
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
		unmapped.DefaultLogWindow,
	)
	decomposed := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "sparkplug_agent_param_decomposed_total",
		Help: "Bare-Parameter raw tags rewritten to a canonical numbered leaf, by PackML parameter id.",
	}, []string{"param_id"})
	reg.MustRegister(decomposed)
	// ADR-0045 P2c: canonical count tags SYNTHESIZED by the agent-side derive
	// stage (integral/sum). Nonzero ⇒ the deriver is producing counts a PLC does
	// not emit directly.
	derivedSynth := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "sparkplug_agent_derived_synth_total",
		Help: "Canonical count tags synthesized by the agent-side derive stage (integral|sum).",
	})
	reg.MustRegister(derivedSynth)
	// ADR-0045 counter_derive: gross/net/scrap count tags SYNTHESIZED by the
	// agent-side counter-derive stage (a factory that senses only some of the three).
	counterDerivedSynth := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "sparkplug_agent_counter_derived_synth_total",
		Help: "Canonical count tags synthesized by the agent-side counter-derive stage (gross/net/scrap filled from the sensed subset per counter_derive).",
	})
	reg.MustRegister(counterDerivedSynth)

	// ADR-0045 P2a: whether the register-driven (config-as-data) tag map is
	// active for this tenant, and why. 1 = register-driven, 0 = static YAML.
	// Set once at boot from the resolved source (Option A — the flip is a boot
	// read). The `reason` label carries the selection outcome (env_override /
	// descriptor_cutover / descriptor_absent / descriptor_error / …).
	tagmapRegisterActive := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "sparkplug_agent_tagmap_register_active",
		Help: "1 when the register-driven (config-as-data) tag map is active for the tenant, 0 when the static YAML map is used. Labeled by tenant (SparkPlug group_id) and the selection reason.",
	}, []string{"tenant", "reason"})
	reg.MustRegister(tagmapRegisterActive)
	activeVal := 0.0
	if tagSrc.UseRegister {
		activeVal = 1.0
	}
	tagmapRegisterActive.WithLabelValues(cfg.Sparkplug.GroupID, tagSrc.Reason).Set(activeVal)

	// task #31: rebirths triggered by an inbound "Node Control/Rebirth" NCMD.
	// This is how the cloud edge-transformer self-heals its alias/counter
	// baseline after a restart — it asks us to rebirth, we re-publish NBIRTH.
	rebirths := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "sparkplug_agent_rebirths_total",
		Help: "Full NBIRTH re-publishes triggered by an inbound Rebirth NCMD (task #31).",
	})
	reg.MustRegister(rebirths)
	up.SetRebirthMetric(rebirths.Inc)

	// ── live-capture recorder (ADR-0045 Phase-2b) ────────────────────────────
	// Built only in the observe posture. It records, per equipment topic, which
	// count indices actually arrive — buffered in-memory and flushed on a ticker
	// to capture_observations via the (reused) register pool. The count-leaf
	// TEMPLATES come from the tenant profile's metric_templates ({idx}-bearing
	// leaves); with no profile there are no count families to recognize, so the
	// recorder stays nil and Observe is a no-op.
	var recorder *capture.Recorder
	if observing {
		var leaves []string
		if boot.profile != nil {
			for _, t := range boot.profile.MetricTemplates.Member {
				leaves = append(leaves, t.Leaf)
			}
			for _, t := range boot.profile.MetricTemplates.Line {
				leaves = append(leaves, t.Leaf)
			}
		}
		templates := capture.CountLeafTemplates(leaves)
		if len(templates) == 0 {
			logger.Warn("capture observe posture active but the tenant profile declares no count-metric leaves — nothing to capture",
				"enterprise_id", boot.enterpriseID)
		}
		captureObs := prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "sparkplug_agent_capture_observations_total",
			Help: "Count-bearing raw tags recorded in the ADR-0045 observe posture, by tenant (SparkPlug group_id).",
		}, []string{"tenant"})
		reg.MustRegister(captureObs)
		obsCounter := captureObs.WithLabelValues(cfg.Sparkplug.GroupID)
		recorder = capture.New(capture.Config{
			EnterpriseID: boot.enterpriseID,
			Templates:    templates,
			Sink:         capture.NewPGSink(boot.pool),
			Logger:       logger,
			OnObserved:   obsCounter.Inc,
		})
		go recorder.Run(ctx, time.Duration(getenvInt("AGENT_CAPTURE_FLUSH_SEC", 30))*time.Second)
		logger.Info("live-capture observe posture ENABLED",
			"enterprise_id", boot.enterpriseID,
			"count_leaf_templates", len(templates),
			"flush_sec", getenvInt("AGENT_CAPTURE_FLUSH_SEC", 30))
	}

	// ingest is the SHARED pipeline entry point: resolve each raw tag against
	// the tag_map and RBE-apply the mapped ones to the tagstore. BOTH the
	// internal MQTT subscriber (Mode-B / full architecture) and the HTTP
	// front-door (Mode-A direct-to-ingest tee) call it, so the two front-doors
	// feed one tagstore→session→uplink path. Returns (accepted, total):
	// accepted resolved to a mapped metric; the rest were dropped-with-metric.
	ingest := func(tags []rawtag.RawTag) (accepted, total int) {
		// Agent-side DERIVE stage (ADR-0045 P2c): synthesize canonical counts from
		// analog integrals / register sums declared per-equipment in the profile,
		// and mark the sum ADDEND suffixes as consumed (they must be dropped, not
		// republished — a partial passthrough looks like a totalizer drop to Calc).
		// It keys on the RAW arriving suffix, so it runs BEFORE parameter
		// decomposition (disjoint tag sets — counts/speeds vs bare Parameter).
		var synth []rawtag.RawTag
		var consumed map[string]bool
		if derive != nil {
			synth, consumed = derive.Process(tags)
		}
		// Counter-derive (ADR-0045): synthesize the gross/net/scrap counts the
		// factory does not sense, from the sensed subset present in this batch. It
		// keys on the SAME canonical count suffixes (post nothing — counts are never
		// decomposed), does NOT consume its inputs (a sensed count still publishes),
		// and its synth tags resolve+store on the shared path below like any tag.
		var counterSynth []rawtag.RawTag
		if cderive != nil {
			counterSynth = cderive.Process(tags)
		}
		for _, t := range tags {
			// A sum addend the deriver folded in: drop it (do not republish).
			if consumed[t.Metric] {
				continue
			}
			// Live-capture OBSERVE (ADR-0045 P2b): record what count indices
			// ACTUALLY arrive — BEFORE the allowlist, so an inferred-index tag
			// that the current map would drop as unmapped is still observed (that
			// mismatch is exactly the DQ evidence CS confirms against). No-op when
			// not observing (recorder is nil) or the tag is not count-bearing.
			// Uses the raw arriving suffix (count leaves are never decomposed).
			recorder.Observe(cfg.Sparkplug.PackMLTopic + t.Metric)

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
				unmappedReporter.Observe(t.Metric)
				continue
			}
			store.Apply(t)
			accepted++
		}
		// Synthesized counts resolve + store on the SAME path (their Emit suffixes
		// are allowlisted via SynthesizeEquipment). They are NOT observed (agent-
		// generated, not from the live tee) and do not count toward the input
		// (accepted,total) — that pair reports the incoming envelope only.
		for _, t := range synth {
			if _, _, ok := resolver.Resolve(t.Metric); !ok {
				dropped.WithLabelValues("unmapped").Inc()
				unmappedReporter.Observe(t.Metric)
				continue
			}
			store.Apply(t)
			derivedSynth.Inc()
		}
		// Counter-derived counts resolve+store on the SAME path. A synthesized
		// sibling whose suffix is NOT in raw_tag_map (the equipment's metric
		// templates omit that count leaf) surfaces as an unmapped drop — the
		// fail-safe DQ signal that the templates need the derived leaf, never a crash.
		for _, t := range counterSynth {
			if _, _, ok := resolver.Resolve(t.Metric); !ok {
				dropped.WithLabelValues("unmapped").Inc()
				unmappedReporter.Observe(t.Metric)
				continue
			}
			store.Apply(t)
			counterDerivedSynth.Inc()
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

		// ── numeric-count-index translation front-door (ADR-0045 §2.3, task #13) ──
		// Flag-gated + additive: default OFF. ON mounts POST /v1/counters, which
		// accepts a legacy numeric `counterData[{id,value}]` payload from a DUMB
		// tee and translates each numeric id → a canonical rawtag using a table
		// DERIVED from this agent's finalized raw_tag_map (every count leaf
		// `.../<X>Count/<idx>/Unit` yields idx→suffix). This is the stack-side
		// "proper translation layer" for bispharma/bisnago-class counters-only
		// tenants. A skewed/empty table is fatal here (fail-closed: a numeric
		// tenant with nothing to translate is a misconfiguration, not a silent
		// no-op).
		var translator *numeric.Translator
		var numericUnmapped prometheus.Counter
		if getenvBool("AGENT_NUMERIC_INGEST_ENABLED", false) {
			byIndex, err := numeric.BuildIndexFromTagMap(cfg.RawTagMap)
			if err != nil {
				logger.Error("numeric translation table", "err", err)
				os.Exit(1)
			}
			if len(byIndex) == 0 {
				logger.Error("AGENT_NUMERIC_INGEST_ENABLED=true but no count-leaf metrics in raw_tag_map — nothing to translate",
					"tags", len(cfg.RawTagMap))
				os.Exit(1)
			}
			translator = numeric.NewTranslator(byIndex)
			numericUnmapped = prometheus.NewCounter(prometheus.CounterOpts{
				Name: "sparkplug_agent_numeric_unmapped_total",
				Help: "Legacy numeric count ids received on /v1/counters that matched no canonical metric (onboarding DQ).",
			})
			reg.MustRegister(numericUnmapped)
			logger.Info("numeric-count-index translation enabled",
				"count_indices", translator.Len())
		}

		hi := httpingest.New(httpingest.Config{
			APIKey:          key,
			ScopeGroup:      cfg.Sparkplug.GroupID, // agent serves exactly one tenant
			MaxBodyBytes:    int64(getenvInt("AGENT_INGEST_MAX_BODY_BYTES", 0)),
			Numeric:         translator,
			NumericUnmapped: numericUnmapped,
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

// resolveTagMap decides + installs the tenant's raw_tag_map for this boot and
// returns the chosen source (for the boot log + the register-active gauge).
//
// Decision (ADR-0045 P2a): AGENT_TAGMAP_FROM_REGISTER (global override) wins;
// else the tenant's client_descriptors.status decides (cutover ⇒ register).
// The path is fail-safe to the CURRENT behaviour (the static YAML map):
//   - no AGENT_PROFILE_PATH ........ nothing to build/scope → static (no DB touched)
//   - no DB DSN .................... can't read the descriptor → static
//   - DB unreachable / read error .. → static (warn-logged)
//   - status != cutover / no row ... → static
//
// Only a DEFINITE signal (override, or status==cutover) builds the register
// map; a register build that was explicitly selected but fails is FATAL (a
// partial/absent map would silently drop metrics — the same discipline as the
// original loader). It opens ONE pgxpool and reuses it for BOTH the status read
// and (if cutover) the register fetch — never a second pool.
//
// The agent resolves its tenant from the tenant profile: prof.EnterpriseID is
// packml_register.id_enterprise, which is exactly client_descriptors.id_enterprise
// — the authoritative cross-tenant scope for both the descriptor read and the
// register fetch. (cfg.Sparkplug.GroupID is the tenant short-name / group_id;
// it must equal prof.Tenant, guarded below.)
func resolveTagMap(ctx context.Context, cfg *agentcfg.Config, logger *slog.Logger) (agentcfg.TagMapSource, *bootDB, error) {
	boot := &bootDB{}
	envOverride := getenvBool("AGENT_TAGMAP_FROM_REGISTER", false)
	profPath := os.Getenv("AGENT_PROFILE_PATH")

	// Without a profile there is no register map to build and no enterprise scope
	// to check a descriptor against. An explicit override with no profile is a
	// hard misconfig (the original loader's own guard); otherwise stay static and
	// touch no DB — un-migrated tenants keep zero DB dependency.
	if profPath == "" {
		if envOverride {
			return agentcfg.TagMapSource{}, boot, fmt.Errorf("AGENT_TAGMAP_FROM_REGISTER=true requires AGENT_PROFILE_PATH")
		}
		return agentcfg.TagMapSource{UseRegister: false, Reason: "no_profile"}, boot, nil
	}

	prof, err := tenantprofile.LoadProfile(profPath)
	if err != nil {
		return agentcfg.TagMapSource{}, boot, fmt.Errorf("load profile: %w", err)
	}
	// Guard: a profile's tenant must match the agent it configures, so a
	// mis-pointed AGENT_PROFILE_PATH can't build/scope another tenant's map.
	if prof.Tenant != "" && prof.Tenant != cfg.Sparkplug.GroupID {
		return agentcfg.TagMapSource{}, boot, fmt.Errorf("profile tenant %q != agent group_id %q", prof.Tenant, cfg.Sparkplug.GroupID)
	}
	if prof.EnterpriseID == 0 {
		return agentcfg.TagMapSource{}, boot, fmt.Errorf("profile enterprise_id is required for the register loader / cutover check")
	}
	boot.profile = prof
	boot.enterpriseID = prof.EnterpriseID

	dsn, err := registerDSN()
	if err != nil {
		if envOverride {
			return agentcfg.TagMapSource{}, boot, err
		}
		// No DB creds → can't read the descriptor. Stay static (current behaviour).
		logger.Warn("no DB DSN for the cutover-status check — staying on the static tag map", "err", err)
		return agentcfg.TagMapSource{UseRegister: false, Reason: agentcfg.ReasonDescriptorError}, boot, nil
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		if envOverride {
			return agentcfg.TagMapSource{}, boot, fmt.Errorf("pgx pool: %w", err)
		}
		logger.Warn("could not open the DB pool for the cutover-status check — staying on the static tag map", "err", err)
		return agentcfg.TagMapSource{UseRegister: false, Reason: agentcfg.ReasonDescriptorError}, boot, nil
	}
	// The pool is now owned by the caller (bootDB.pool): main keeps it alive only
	// when the capture recorder writes through it, and closes it otherwise. On
	// every fail-safe/fatal path BELOW we close it explicitly (nil pool returned)
	// — a pool only escapes on a healthy path.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		if envOverride {
			return agentcfg.TagMapSource{}, boot, fmt.Errorf("db ping: %w", err)
		}
		logger.Warn("client_descriptors DB unreachable — staying on the static tag map", "err", err)
		return agentcfg.TagMapSource{UseRegister: false, Reason: agentcfg.ReasonDescriptorError}, boot, nil
	}
	boot.pool = pool

	// Read the per-tenant descriptor status. It drives BOTH the tag-map cutover
	// flip (Phase-2a) and the capture observe posture (Phase-2b), so it is read
	// unconditionally here and stashed in bootDB — even under envOverride, where
	// SelectTagMapSource ignores it for the tag-map decision but capture still
	// needs it. A read error is a safe static fallback (never a flip).
	status, statusErr := agentcfg.NewDescriptorStatusFetcher(pool).FetchStatus(ctx, prof.EnterpriseID)
	if statusErr != nil {
		logger.Warn("client_descriptors status read failed — staying on the static tag map", "err", statusErr)
	} else {
		boot.status = status
	}
	src := agentcfg.SelectTagMapSource(envOverride, status, statusErr)
	if !src.UseRegister {
		return src, boot, nil
	}

	// Cutover (or override): build + install the register-driven map with the
	// SAME pool. A failure here is fatal — register was explicitly selected.
	if err := installRegisterTagMap(ctx, cfg, prof, pool, logger); err != nil {
		pool.Close()
		boot.pool = nil
		return agentcfg.TagMapSource{}, boot, err
	}
	return src, boot, nil
}

// bootDB carries the DB-derived boot resources that outlive resolveTagMap: the
// (optionally kept-open) register pool, the loaded tenant profile, the tenant's
// enterprise id, and the descriptor status. main owns the pool's lifetime — it
// keeps it open past boot ONLY for the capture recorder, else closes it. Any
// field may be zero/nil (static tenant, no DB, read error) — every consumer
// nil-checks. pool is non-nil ONLY on a healthy DB path.
type bootDB struct {
	pool         *pgxpool.Pool
	profile      *tenantprofile.Profile
	enterpriseID int
	status       string
}

// installRegisterTagMap replaces cfg.RawTagMap with a map built from
// packml_register + the tenant conversion profile (task #13), reusing the
// caller's already-open pool. It fetches the tenant's equipment rows,
// synthesizes the canonical suffix→type map, and installs it (re-validated).
func installRegisterTagMap(ctx context.Context, cfg *agentcfg.Config, prof *tenantprofile.Profile, pool *pgxpool.Pool, logger *slog.Logger) error {
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

// deviceKeysFromTagMap builds the full-metric-name → DECLARED device_key map the
// session consults for definitive birth (ADR-0046 task #18). Entries with no
// declared key are omitted, so the birth side derives them (the bridge). The full
// name is resolved the same way the resolver does (packml_topic + suffix, or an
// explicit Name), so the keys line up with what BuildNBIRTH looks up.
func deviceKeysFromTagMap(cfg *agentcfg.Config) map[string]string {
	m := make(map[string]string)
	for _, e := range cfg.RawTagMap {
		if e.DeviceKey == "" {
			continue
		}
		m[e.FullName(cfg.Sparkplug.PackMLTopic)] = e.DeviceKey
	}
	return m
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

// AllMapped implements session.AllResolver: the COMPLETE mapped set the agent can
// emit, in a stable suffix-sorted order. Powers birth-completeness
// (AGENT_BIRTH_ALL_MAPPED) — BuildNBIRTH births every one of these with a stable
// alias, so a line idle at connect is still aliased at the cloud the instant it
// first reports (CPACK 2026-08-13 line-count regression fix).
func (r *resolver) AllMapped() []session.MappedMetric {
	out := make([]session.MappedMetric, 0, len(r.byName))
	for suffix, e := range r.byName {
		out = append(out, session.MappedMetric{Suffix: suffix, Name: e.name, Datatype: e.dt})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Suffix < out[j].Suffix })
	return out
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
