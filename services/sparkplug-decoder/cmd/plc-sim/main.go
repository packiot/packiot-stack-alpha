// plc-sim — the 10.9-staging PLC simulator: a continuous Sparkplug B
// publisher over the CPACK line topology, replacing the Node-RED
// simulator+wrap pair as the staging ingest source (MQTT becomes THE
// ingest; the AMQP wrap leg retires via AMQP_SOURCE_ENABLED=false).
//
// Behavior per line, per tick:
//   - StateCurrent: mostly 6 (execute), occasional 10/5 stretches —
//     drives the deriver/event chain.
//   - ProdConsumedCount/ProdProcessedCount: monotonic counters at
//     ~machspeed units/min with jitter; ProdDefectiveCount rare.
//   - MachSpeed constant per line (seeds the Calc port's Phase 7).
//   - Parameter30700 on the line topic (single-machine lines) so the
//     Phase 9 line aggregation fires.
//
// NBIRTH re-published on connect (alias table); NDATA every tick with
// alias references — the exact protocol shape the decoder + StateStore
// were built and parity-checked against.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"math/rand"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/birth"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

const groupID = "CPACK"

// line describes one simulated single-machine line (topic anatomy per
// the state-machine doc §2: Ent/Site/Area/Line/Unit/...).
type line struct {
	Line, Unit string
	Idx        int     // counter index segment
	MachSpeed  float64 // units/min
}

// The staging CPACK topology — VERIFIED against packml_register (staging
// packiot_analytics: L8=51, L5=47, L3=48, L4=49; members below).
//
// #16 LINE-FEED FIDELITY: each line now publishes its OWN line-scoped
// Sparkplug stream (Unit=="") — a bare-topic counter + StateCurrent that
// TopicForRegister collapses to the 4-segment line topic → the tp=3 line
// equipment directly. Before, only L8 did this; L5/L3/L4 had ONLY member
// streams, so their line equipments (47/48/49) were fed solely by fragile
// Phase-9 member-derivation and under-counted vs prod (line-STATE 20/6/8 vs
// L8's 17292; L3 line counter 0). Giving every line an own-stream makes them
// isomorphic to the proven-clean L8, so the line reads its own counter, not a
// member-sum.
//
// SINGLE-WRITER (the #456 non-regression): the line's Parameter30700 is its
// OWN Idx (the `line.Idx` field = 51/47/48/49) — a self-reference that matches
// no member index, so Phase-9 line-derivation never fires and the line's
// counter has exactly one writer (its own-stream). Members no longer publish
// Parameter30700 at all (see publishBirth). The line-counter Idx is cosmetic:
// the resolver collapses line topics to the 4-seg form, so 51/47/48/49 only
// need to not collide with a member Idx (enforced by
// TestLineParameter30700_SelfReferentialNoMemberCollision).
//
// PROD FIDELITY (verified SELECT-only, packiot40 2026-07-16): prod C-PACK
// sends NO Parameter30700 for these lines (packml_register.line_unit_seq NULL
// on every C-PACK row) — prod's line eqs are own-stream-fed, member-derivation
// OFF. Our self-referential Parameter30700 reaches the SAME end state (no
// member match ⇒ no derivation) while still serving the sim's DCMD po_setup
// write-back observability on the line topic. Benign divergence; identical
// downstream effect.
//
// Line entries carry a self-referential Idx (= the eq surrogate) and a
// prod-calibrated MachSpeed (= prod production_speed); members carry a real
// counter-path Idx and a member MachSpeed. (Idx, MachSpeed) shown below:
//
//	CPACK/SC/LINHAS/L8              (Unit="", Idx 51, spd 120) → eq 51  line own-stream
//	CPACK/SC/LINHAS/L5              (Unit="", Idx 47, spd 147) → eq 47  line own-stream (#16)
//	CPACK/SC/LINHAS/L3              (Unit="", Idx 48, spd 140) → eq 48  line own-stream (#16)
//	CPACK/SC/LINHAS/L4              (Unit="", Idx 49, spd 147) → eq 49  line own-stream (#16)
//	CPACK/SC/LINHAS/L5/BREYER + .../61/Unit → eq 53  member
//	CPACK/SC/LINHAS/L5/TEXA   + .../65/Unit → eq 57  member
//	CPACK/SC/LINHAS/L3/PTH    + .../81/Unit → eq 61  member
//	CPACK/SC/LINHAS/L4/TEXA   + .../63/Unit → eq 63  member (idx 66→63: 66 is
//	  L4/BREYER's registered counter path; 66 mis-resolved by bare-topic fallback)
//
// FEED-MAGNITUDE CALIBRATION (#77): the line MachSpeed is the own-stream's
// counter rate (units/min while StateCurrent==6) — the sim's line "feed
// magnitude". It MUST track prod's real line throughput or line-vs-prod gross
// drifts. When #16/#491 added the L5/L3/L4 line entries, their MachSpeed field
// was left holding the leftover self-ref-idx numbers (105/88/92) instead of a
// prod-calibrated machine speed — an uncalibrated feed that under-fed those
// lines ~29–37% vs prod. L8 (pre-existing) already carried 120 = prod's
// production_speed, so it was never the actual gap (the #18 "L8 −38%" figure
// predates #491 and does not reproduce: L8 now tracks prod within ~5%).
//
// MachSpeed is now set to each line's prod `equipments.production_speed`
// (SELECT-only, packiot40 2026-07-18): L8=120, L5=147, L3=140, L4=147. The
// feed_magnitude_parity_test guard pins these against a prod-calibrated band so
// a future line addition can't silently ship an uncalibrated feed again.
var lines = []line{
	{"L8", "", 51, 120},
	{"L5", "", 47, 147},
	{"L3", "", 48, 140},
	{"L4", "", 49, 147},
	{"L5", "BREYER", 61, 110},
	// L5/TEXA (eq 57): RESTORED (rollback of #611). The real CPACK tee DOES feed
	// eq 57 (F1/packiot stays fresh from the agent alone), but the refactored Calc
	// path (source_type=refactored → F2/F3) could NOT re-establish eq 57's counter
	// baseline after a deploy restarted edge-transformer: the agent never rebirths
	// (mosquitto/agent stay up across an app-stack deploy, so no reconnect → no
	// NBIRTH), edge-transformer logs a SparkPlug "sequence gap" for CPACK/cpack-tee,
	// and F2/F3 eq 57 went dark from the restart onward. plc-sim MASKED this because
	// it rebirths on every restart and its dense stream re-seeds the Calc baseline.
	// PREREQUISITE before dropping a teed line from plc-sim: the agent must issue a
	// SparkPlug rebirth on edge-transformer restart (or ET must send a Rebirth NCMD
	// on a sequence gap). See ADR-0042 / session-88. Until then, keep this entry so
	// the migration-target DB (packiot_analytics) has no dark equipment across deploys.
	{"L5", "TEXA", 65, 100},
	{"L3", "PTH", 81, 90},
	{"L4", "TEXA", 63, 95},
}

type metricDef struct {
	name  string
	alias uint64
}

// topicPrefix is the SparkPlug metric-name prefix for this line — the base a
// DCMD's metric name must start with to target this line (e.g.
// "CPACK/SC/LINHAS/L5/BREYER"). It is the same base metrics() builds from.
func (l line) topicPrefix() string {
	p := "CPACK/SC/LINHAS/" + l.Line
	if l.Unit != "" {
		p += "/" + l.Unit
	}
	return p
}

func (l line) metrics(base uint64) []metricDef {
	p := l.topicPrefix()
	return []metricDef{
		{p + fmt.Sprintf("/Admin/ProdConsumedCount/%d/Unit", l.Idx), base + 1},
		{p + fmt.Sprintf("/Admin/ProdProcessedCount/%d/Unit", l.Idx), base + 2},
		{p + fmt.Sprintf("/Admin/ProdDefectiveCount/%d/Unit", l.Idx), base + 3},
		{p + "/Status/MachSpeed", base + 4},
		{p + "/Status/StateCurrent", base + 5},
		{"CPACK/SC/LINHAS/" + l.Line + "/Status/Parameter30700", base + 6},
	}
}

type simState struct {
	consumed, processed, defective float64
	state                          int64 // PackML
	stateLeft                      int   // ticks remaining in state

	// ── DCMD-applied overrides (ADR-0019 C1 command-channel loop) ──────────
	// A DCMD from the command channel mutates these; the sim then reports the
	// new values in its next NBIRTH/NDATA, so the write is observable end to
	// end. Guarded by the package-level `mu` (the paho callback goroutine
	// writes them; the tick goroutine reads them).
	speedOverride    float64 // param_write on .../Status/MachSpeed
	hasSpeedOverride bool
	poParam          string // po_setup on .../Status/Parameter30700
}

// effSpeed is the line's effective MachSpeed — the DCMD override if one has
// been applied, else the static seed. Caller holds mu.
func (s *simState) effSpeed(seed float64) float64 {
	if s.hasSpeedOverride {
		return s.speedOverride
	}
	return seed
}

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("PLC_SIM_EDGE_NODE", "plc-sim"), "Sparkplug edge node id")
	tickSec := flag.Int("tick", getenvInt("PLC_SIM_TICK_SEC", 5), "seconds between NDATA")
	// ADR-0046 step 2 (default OFF, same env name as the sparkplug-agent's
	// EMIT_DEFINITIVE_BIRTH): when ON, each counter metric's NBIRTH carries the
	// role-typed properties (counter_role/source_ref/device_key) that the
	// birth-bound consumer (internal/birthbind) needs to route by alias. OFF ⇒
	// the birth is byte-identical to the legacy string-name form (a no-op deploy),
	// so a birth-bound flip requires flipping BOTH producer and consumer.
	emitDefinitive := flag.Bool("definitive-birth",
		getenvBool("EMIT_DEFINITIVE_BIRTH", false),
		"ADR-0046: attach counter_role/source_ref/device_key properties on NBIRTH")
	flag.Parse()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "plc-sim")

	opts := paho.NewClientOptions().AddBroker(*broker).
		SetClientID("plc-sim-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	var seq uint64
	states := make([]simState, len(lines))
	for i := range states {
		states[i] = simState{state: 6, stateLeft: 60 + rand.Intn(120)}
	}
	// mu guards `states` — the DCMD callback (paho goroutine) mutates the
	// override fields while the tick goroutine reads them. rebirth signals the
	// tick loop to republish an NBIRTH reflecting a just-applied DCMD, so the
	// command-channel write is observable in the sim's output.
	var mu sync.Mutex
	rebirth := make(chan struct{}, 1)

	publishBirth := func(c paho.Client) {
		mu.Lock()
		ms := buildBirthMetrics(lines, states, *emitDefinitive)
		mu.Unlock()
		seq = 0
		body, err := sparkplug.EncodeSim(ms, &seq, true)
		if err != nil {
			logger.Error("encode NBIRTH", "err", err)
			return
		}
		tok := c.Publish("spBv1.0/"+groupID+"/NBIRTH/"+*edgeNode, 0, true, body)
		tok.Wait()
		logger.Info("NBIRTH published", "metrics", len(ms))
	}

	// applyDCMD is the command-channel loop's receiving end (ADR-0019 C1): it
	// decodes a DCMD, matches each named metric to a line by topic prefix, and
	// applies the write to the sim's in-memory state so the effect shows up in
	// the next NBIRTH/NDATA. Only the two verbs the executor emits are mapped:
	// param_write on MachSpeed and po_setup on Parameter30700.
	applyDCMD := func(body []byte) {
		mu.Lock()
		applied, err := applyDCMDToStates(body, lines, states, logger)
		mu.Unlock()
		if err != nil {
			logger.Error("DCMD decode", "err", err)
			return
		}
		if applied > 0 {
			// Signal the tick loop to re-birth so the applied write shows up in
			// the sim's next NBIRTH/NDATA (the write is observable end to end).
			select {
			case rebirth <- struct{}{}:
			default:
			}
		}
	}

	dcmdTopic := "spBv1.0/" + groupID + "/DCMD/" + *edgeNode
	opts.SetOnConnectHandler(func(c paho.Client) {
		logger.Info("connected", "broker", *broker)
		publishBirth(c)
		// Subscribe to the device command topic — the command channel's DCMDs
		// land here. QoS 1 to match the executor's at-least-once publish.
		if tok := c.Subscribe(dcmdTopic, 1, func(_ paho.Client, msg paho.Message) {
			applyDCMD(msg.Payload())
		}); tok.WaitTimeout(5*time.Second) && tok.Error() != nil {
			logger.Error("DCMD subscribe", "err", tok.Error())
		} else {
			logger.Info("DCMD listener subscribed", "topic", dcmdTopic)
		}
	})
	client := paho.NewClient(opts)
	if tok := client.Connect(); tok.Wait() && tok.Error() != nil {
		logger.Error("connect", "err", tok.Error())
		os.Exit(1)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	tick := time.NewTicker(time.Duration(*tickSec) * time.Second)
	defer tick.Stop()
	logger.Info("plc-sim running", "lines", len(lines), "tick_sec", *tickSec)

	for {
		select {
		case <-stop:
			logger.Info("plc-sim stopping")
			client.Disconnect(250)
			return
		case <-rebirth:
			// A DCMD was just applied — republish NBIRTH so the new MachSpeed /
			// PO param is immediately visible downstream.
			publishBirth(client)
		case <-tick.C:
			var ms []sparkplug.SimMetric
			mu.Lock()
			for i, l := range lines {
				s := &states[i]
				s.stateLeft--
				if s.stateLeft <= 0 {
					// transition: running↔stopped-ish
					if s.state == 6 {
						if rand.Intn(4) == 0 {
							s.state = 5
						} else {
							s.state = 10
						}
						s.stateLeft = 6 + rand.Intn(24) // 30s–2.5min downtime
					} else {
						s.state = 6
						s.stateLeft = 60 + rand.Intn(240)
					}
				}
				if s.state == 6 {
					// Effective speed honors a DCMD MachSpeed override so a
					// param_write is observable in the counter rate too.
					inc := s.effSpeed(l.MachSpeed) / 60 * float64(*tickSec) * (0.85 + rand.Float64()*0.3)
					s.consumed += inc
					s.processed += inc * (0.97 + rand.Float64()*0.03)
					if rand.Intn(50) == 0 {
						s.defective += 1 + float64(rand.Intn(3))
					}
				}
				base := uint64((i + 1) * 10)
				ms = append(ms,
					sparkplug.SimMetric{Alias: base + 1, Double: s.consumed},
					sparkplug.SimMetric{Alias: base + 2, Double: s.processed},
					sparkplug.SimMetric{Alias: base + 3, Double: s.defective},
					sparkplug.SimMetric{Alias: base + 5, Long: s.state, IsLong: true},
				)
			}
			mu.Unlock()
			body, err := sparkplug.EncodeSim(ms, &seq, false)
			if err != nil {
				logger.Error("encode NDATA", "err", err)
				continue
			}
			tok := client.Publish("spBv1.0/"+groupID+"/NDATA/"+*edgeNode, 0, false, body)
			tok.Wait()
		}
	}
}

// buildBirthMetrics freezes the current sim state into the NBIRTH metric set —
// the pure, testable core of publishBirth (extracted so the producer↔consumer
// round-trip test can drive the REAL birth builder, not a stand-in). Caller
// holds the state mutex (states is read here without locking).
//
// When emitDefinitive is set, each canonical count-leaf metric carries its
// ADR-0046 definitive-birth PropertySet (see definitiveProps); every other
// metric — and the whole set when the flag is OFF — is byte-identical to the
// legacy string-name birth.
func buildBirthMetrics(lines []line, states []simState, emitDefinitive bool) []sparkplug.SimMetric {
	var ms []sparkplug.SimMetric
	for i, l := range lines {
		base := uint64((i + 1) * 10)
		defs := l.metrics(base)
		ms = append(ms,
			sparkplug.SimMetric{Name: defs[0].name, Alias: defs[0].alias, Double: states[i].consumed, Props: definitiveProps(defs[0].name, emitDefinitive)},
			sparkplug.SimMetric{Name: defs[1].name, Alias: defs[1].alias, Double: states[i].processed, Props: definitiveProps(defs[1].name, emitDefinitive)},
			sparkplug.SimMetric{Name: defs[2].name, Alias: defs[2].alias, Double: states[i].defective, Props: definitiveProps(defs[2].name, emitDefinitive)},
			sparkplug.SimMetric{Name: defs[3].name, Alias: defs[3].alias, Double: states[i].effSpeed(l.MachSpeed)},
			sparkplug.SimMetric{Name: defs[4].name, Alias: defs[4].alias, Long: states[i].state, IsLong: true},
		)
		// Parameter30700 (the line-machines CSV Phase-9 reads) is published
		// ONLY by line entries (Unit==""). #16: a member publishing it would
		// put a MEMBER index in the line's CSV, arming Phase-9 line-derivation
		// — a SECOND line-counter writer on top of the line's own-stream (the
		// #456 two-writer double-count, oee>1.0). A line entry publishes its
		// OWN self-referential idx, which matches no member, so member-
		// derivation never fires and the line's counter comes solely from its
		// own-stream. Single-writer per line, exactly as L8 already behaves.
		if l.Unit == "" {
			poText := states[i].poParam
			if poText == "" {
				poText = fmt.Sprint(l.Idx)
			}
			ms = append(ms,
				sparkplug.SimMetric{Name: defs[5].name, Alias: defs[5].alias, Text: poText, IsText: true},
			)
		}
	}
	return ms
}

// definitiveProps returns the ADR-0046 definitive-birth PropertySet for a metric
// NAME when emitDefinitive is on and the name is a canonical count-leaf, else nil.
// It REUSES internal/agent/birth (the sparkplug-agent's producer) so the role
// mapping (ProdConsumedCount→gross, ProdProcessedCount→net, ProdDefectiveCount→
// scrap) and the device_key = dash-joined equipment topic derivation are never
// duplicated in the sim. A non-counter metric (MachSpeed/StateCurrent/
// Parameter30700) yields nil, and OFF yields nil — either way the metric stays
// byte-clean, exactly like the agent's session.BuildNBIRTH.
func definitiveProps(name string, emitDefinitive bool) *sparkplug.PropertySet {
	if !emitDefinitive {
		return nil
	}
	// Empty declared key ⇒ the birth package derives device_key by stripping the
	// 4-segment count-leaf tail and dash-joining the remaining topic — i.e. the
	// dash-joined equipment topic (CPACK/SC/LINHAS/L5/BREYER → CPACK-SC-LINHAS-L5-
	// BREYER), which matches what the birth-bound consumer resolves against.
	if ps, ok := birth.CounterMetricProps(name); ok {
		return ps
	}
	return nil
}

// dcmdDouble extracts a numeric DCMD metric value as float64 (the executor
// encodes param_write values as Double, but tolerate the other numeric wire
// forms defensively).
// applyDCMDToStates decodes a DCMD body and applies each mapped write to the
// matching line's in-memory state, returning the number of writes applied. It
// is the pure core of the command-channel receiving end (ADR-0019 C1), split
// out of the paho callback so it can be unit-tested DIRECTLY against the
// executor's real BuildDCMD output — the one seam that was implemented on both
// ends (executor emits the DCMD, sim applies it) yet never tested TOGETHER
// (each end had only isolated tests, so a wire-format drift between them would
// have gone unnoticed). Callers hold the state mutex; this does no locking.
func applyDCMDToStates(body []byte, lines []line, states []simState, logger *slog.Logger) (int, error) {
	p, err := sparkplug.Decode(body)
	if err != nil {
		return 0, err
	}
	applied := 0
	for _, m := range p.GetMetrics() {
		name := m.GetName()
		if name == "" {
			continue
		}
		// LONGEST-PREFIX match — route the DCMD to exactly one line entry.
		// #16 added bare line-topic entries (Unit=="", prefix e.g.
		// "CPACK/SC/LINHAS/L5") whose prefix is ALSO a prefix of their members
		// ("CPACK/SC/LINHAS/L5/BREYER/..."). A naive "apply to every matching
		// prefix" would then double-apply a member-targeted DCMD to both the
		// member AND the line. Pick the MOST SPECIFIC (longest) segment-aligned
		// match instead — the same routing-table longest-prefix discipline the
		// topic resolver uses. A line-topic DCMD (".../L5/Status/...") matches
		// only the line entry; a member DCMD (".../L5/BREYER/Status/...") the
		// member.
		best := -1
		for i, l := range lines {
			if !prefixMatchSegment(name, l.topicPrefix()) {
				continue
			}
			if best < 0 || len(lines[i].topicPrefix()) > len(lines[best].topicPrefix()) {
				best = i
			}
		}
		if best < 0 {
			continue
		}
		i, l := best, lines[best]
		switch {
		case strings.HasSuffix(name, "/Status/MachSpeed"):
			if v, ok := dcmdDouble(m); ok {
				states[i].speedOverride = v
				states[i].hasSpeedOverride = true
				applied++
				logger.Info("DCMD applied: MachSpeed override",
					"line", l.Line, "unit", l.Unit, "value", v)
			}
		case strings.HasSuffix(name, "/Status/Parameter30700"):
			if s, ok := dcmdString(m); ok {
				states[i].poParam = s
				applied++
				logger.Info("DCMD applied: PO setup",
					"line", l.Line, "unit", l.Unit, "po", s)
			}
		default:
			logger.Info("DCMD received (no sim effect mapped)", "metric", name)
		}
	}
	return applied, nil
}

// prefixMatchSegment reports whether prefix is a SEGMENT-ALIGNED prefix of
// name — HasPrefix that also requires the next character to be a topic
// separator (or end-of-string), so "CPACK/SC/LINHAS/L5" matches
// "CPACK/SC/LINHAS/L5/BREYER/..." but NOT "CPACK/SC/LINHAS/L58/...". Guards
// the DCMD router against a bare line prefix bleeding onto an unrelated line
// that merely shares a leading substring.
func prefixMatchSegment(name, prefix string) bool {
	if !strings.HasPrefix(name, prefix) {
		return false
	}
	rest := name[len(prefix):]
	return rest == "" || rest[0] == '/'
}

func dcmdDouble(m *sparkplug.Metric) (float64, bool) {
	switch v := m.GetValue().(type) {
	case *sparkplug.Metric_DoubleValue:
		return v.DoubleValue, true
	case *sparkplug.Metric_FloatValue:
		return float64(v.FloatValue), true
	case *sparkplug.Metric_LongValue:
		return float64(v.LongValue), true
	case *sparkplug.Metric_IntValue:
		return float64(v.IntValue), true
	}
	return 0, false
}

// dcmdString extracts a string DCMD metric value (po_setup encodes poNumber as
// String).
func dcmdString(m *sparkplug.Metric) (string, bool) {
	if v, ok := m.GetValue().(*sparkplug.Metric_StringValue); ok {
		return v.StringValue, true
	}
	return "", false
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

// getenvBool reads a boolean env var (1/t/true/y/yes on, anything else off),
// falling back to d when unset — the same OFF-by-default gate shape the
// sparkplug-agent uses for EMIT_DEFINITIVE_BIRTH.
func getenvBool(k string, d bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(k)))
	if v == "" {
		return d
	}
	switch v {
	case "1", "t", "true", "y", "yes", "on":
		return true
	default:
		return false
	}
}
