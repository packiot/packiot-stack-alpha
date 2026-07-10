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

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

const groupID = "CPACK"

// line describes one simulated single-machine line (topic anatomy per
// the state-machine doc §2: Ent/Site/Area/Line/Unit/...).
type line struct {
	Line, Unit string
	Idx        int     // counter index segment
	MachSpeed  float64 // units/min
}

// The staging CPACK topology — VERIFIED against packml_register
// 2026-07-07 (the original table was fictional: it CLAIMED to mirror
// the register but only L5/BREYER/61 matched, so 4 of 5 sim lines
// published unregistered topics that skipped everywhere — the
// call-site-verification lesson, simulator edition):
//
//	CPACK/SC/LINHAS/L8              → eq 51 (line-level entry)
//	CPACK/SC/LINHAS/L5/BREYER + .../61/Unit → eq 53
//	CPACK/SC/LINHAS/L5/TEXA   + .../65/Unit → eq 57
//	CPACK/SC/LINHAS/L3/PTH    + .../81/Unit → eq 61
//	CPACK/SC/LINHAS/L4/TEXA   (line resolves; unit idx unregistered) → eq 63
var lines = []line{
	{"L8", "", 51, 120},
	{"L5", "BREYER", 61, 110},
	{"L5", "TEXA", 65, 100},
	{"L3", "PTH", 81, 90},
	{"L4", "TEXA", 66, 95},
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
		var ms []sparkplug.SimMetric
		for i, l := range lines {
			base := uint64((i + 1) * 10)
			defs := l.metrics(base)
			poText := states[i].poParam
			if poText == "" {
				poText = fmt.Sprint(l.Idx)
			}
			ms = append(ms,
				sparkplug.SimMetric{Name: defs[0].name, Alias: defs[0].alias, Double: states[i].consumed},
				sparkplug.SimMetric{Name: defs[1].name, Alias: defs[1].alias, Double: states[i].processed},
				sparkplug.SimMetric{Name: defs[2].name, Alias: defs[2].alias, Double: states[i].defective},
				sparkplug.SimMetric{Name: defs[3].name, Alias: defs[3].alias, Double: states[i].effSpeed(l.MachSpeed)},
				sparkplug.SimMetric{Name: defs[4].name, Alias: defs[4].alias, Long: states[i].state, IsLong: true},
				sparkplug.SimMetric{Name: defs[5].name, Alias: defs[5].alias, Text: poText, IsText: true},
			)
		}
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
		for i, l := range lines {
			if !strings.HasPrefix(name, l.topicPrefix()) {
				continue
			}
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
	}
	return applied, nil
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
