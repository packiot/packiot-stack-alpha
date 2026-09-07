// capture-fixtures is a standalone binary that subscribes to a Sparkplug B
// MQTT broker (typically staging Mosquitto), filters messages for those that
// would feed calc_production_counters.Calc(), and writes them as JSON
// fixtures under testdata/fixtures/<scenario>/input-N.json.
//
// Usage:
//
//	go run ./cmd/capture-fixtures \
//	    --broker tcp://mosquitto.staging.packiot.app:1883 \
//	    --duration 30m \
//	    --output ./internal/transforms/calc_production_counters/testdata/fixtures \
//	    --max-per-scenario 20
//
// The binary matches messages against a scenario table (see topicScenario)
// and writes ONE input.json per capture. The expected.json companion is
// authored by hand from the state machine reference doc — the binary does
// not attempt to compute expected outputs.
//
// WHY THIS DESIGN:
//
//   - We can't tap Node-RED's `global.*` state from outside the container
//     without an admin-API hack, so we don't try. Golden tests get
//     hand-authored per the state machine reference, using the captured
//     input.json as ground truth for the *input side only*.
//   - Filtering by scenario at capture time avoids capturing 100k random
//     messages and then hand-sorting them. Each scenario has a maximum
//     capture count to keep the fixture corpus manageable (~200 total
//     across 12 scenarios).
//   - JSON (not protobuf binary) so fixtures are diff-able in code review.
//     The Sparkplug decode happens in the port itself; fixtures store the
//     Sparkplug body already decoded to Go types via sparkplug.Decode.
//
// This binary is NOT wired into the main edge-transformer service; it runs
// standalone for capture sessions and is otherwise dormant.

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// scenarioMatcher decides whether a topic belongs to a given fixture
// scenario. Each matcher returns true iff the topic should be captured
// under scenarioID. A single topic may match multiple scenarios.
type scenarioMatcher struct {
	scenarioID string
	match      func(topic string) bool
}

// topicScenarios enumerates the fixture scenarios from the state-machine
// reference §6. Each matcher is intentionally narrow — capture only the
// message shape the scenario tests.
var topicScenarios = []scenarioMatcher{
	{"01_processed_increment_happy", func(t string) bool {
		return strings.Contains(t, "ProdProcessedCount") &&
			strings.Contains(t, "***TRIG") &&
			!hasComplexTrigSuffix(t)
	}},
	{"02_consumed_increment_happy", func(t string) bool {
		return strings.Contains(t, "ProdConsumedCount") &&
			strings.Contains(t, "***TRIG") &&
			!hasComplexTrigSuffix(t)
	}},
	{"03_defective_increment_happy", func(t string) bool {
		return strings.Contains(t, "ProdDefectiveCount") &&
			strings.Contains(t, "***TRIG") &&
			!hasComplexTrigSuffix(t)
	}},
	// Scenarios 04 (reset), 05 (SETUP mode) require state snapshots or
	// operator-triggered inputs — not naturally captured. Hand-craft
	// those from the state machine doc.
	{"06_trig_cs_forces_defective", func(t string) bool {
		return strings.Contains(t, "***TRIG_CS")
	}},
	{"07_trig_ci_forces_consumed", func(t string) bool {
		return strings.Contains(t, "***TRIG_CI")
	}},
	{"08_trig_c_equals_i", func(t string) bool {
		return strings.Contains(t, "***TRIG_C=I")
	}},
	{"09_trig_co_full_reconstruction", func(t string) bool {
		return strings.Contains(t, "***TRIG_CO") && !strings.Contains(t, "***TRIG_C=O")
	}},
	// Scenario 10 (speed > 3x) requires guard-triggering values — capture
	// any message with unusually high increments and hand-annotate.
	// Scenarios 11 + 12 (line aggregation + status) require line-topology
	// context — hand-craft from state machine doc + prod topic samples.
	{"12_statespeed_this_variant", func(t string) bool {
		return strings.Contains(t, "***STATESPEED_THIS")
	}},
}

// hasComplexTrigSuffix returns true if the topic has any of the compound
// TRIG_* suffixes so the "happy path" matchers can exclude them.
func hasComplexTrigSuffix(t string) bool {
	for _, suffix := range []string{"TRIG_CS", "TRIG_CI", "TRIG_C=I", "TRIG_C=O", "TRIG_CO", "STATESPEED_THIS"} {
		if strings.Contains(t, suffix) {
			return true
		}
	}
	return false
}

// capturedFixture is the shape written to input.json per capture.
type capturedFixture struct {
	CapturedAt time.Time `json:"captured_at"`
	Topic      string    `json:"topic"`
	PayloadHex string    `json:"payload_hex"` // Sparkplug B binary as hex
	Scenario   string    `json:"scenario"`
	SourceHost string    `json:"source_host"`
	CaptureSeq uint64    `json:"capture_seq"` // monotonic per capture run
}

// perScenarioCounter tracks how many fixtures we've captured for each
// scenario so we can stop at --max-per-scenario.
type perScenarioCounter struct {
	mu     sync.Mutex
	counts map[string]int
	max    int
	total  atomic.Uint64
}

func (c *perScenarioCounter) tryClaim(scenario string) (seq int, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := c.counts[scenario]
	if n >= c.max {
		return 0, false
	}
	c.counts[scenario] = n + 1
	c.total.Add(1)
	return n + 1, true
}

func (c *perScenarioCounter) summary() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]int, len(c.counts))
	for k, v := range c.counts {
		out[k] = v
	}
	return out
}

func main() {
	broker := flag.String("broker", "tcp://localhost:1883", "MQTT broker URL")
	username := flag.String("username", "", "MQTT username (empty for anonymous)")
	password := flag.String("password", "", "MQTT password")
	clientID := flag.String("client-id", "edge-transformer-capture-fixtures", "MQTT client ID")
	duration := flag.Duration("duration", 30*time.Minute, "how long to capture")
	outputDir := flag.String("output", "./internal/transforms/calc_production_counters/testdata/fixtures", "fixture output directory")
	maxPerScenario := flag.Int("max-per-scenario", 20, "max fixtures per scenario")
	topicFilter := flag.String("topic-filter", "spBv1.0/#", "MQTT topic filter to subscribe to")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if err := run(logger, *broker, *username, *password, *clientID, *topicFilter, *outputDir, *duration, *maxPerScenario); err != nil {
		logger.Error("capture failed", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger, broker, username, password, clientID, topicFilter, outputDir string, duration time.Duration, maxPerScenario int) error {
	// Prep output directories per scenario. Fail early if we can't write.
	for _, s := range topicScenarios {
		dir := filepath.Join(outputDir, s.scenarioID)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	counter := &perScenarioCounter{
		counts: make(map[string]int),
		max:    maxPerScenario,
	}
	var seq atomic.Uint64
	hostname, _ := os.Hostname()

	// Build MQTT client.
	opts := paho.NewClientOptions().
		AddBroker(broker).
		SetClientID(clientID).
		SetUsername(username).
		SetPassword(password).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(2 * time.Second).
		SetKeepAlive(30 * time.Second).
		SetCleanSession(true).
		SetOrderMatters(false)

	onMessage := func(_ paho.Client, msg paho.Message) {
		topic := msg.Topic()
		captureSeq := seq.Add(1)

		var matched bool
		for _, s := range topicScenarios {
			if !s.match(topic) {
				continue
			}
			scenarioSeq, ok := counter.tryClaim(s.scenarioID)
			if !ok {
				continue // already at cap for this scenario
			}
			matched = true

			// Copy the payload (paho reuses the buffer).
			payload := make([]byte, len(msg.Payload()))
			copy(payload, msg.Payload())

			fixture := capturedFixture{
				CapturedAt: time.Now().UTC(),
				Topic:      topic,
				PayloadHex: bytesToHex(payload),
				Scenario:   s.scenarioID,
				SourceHost: hostname,
				CaptureSeq: captureSeq,
			}

			path := filepath.Join(outputDir, s.scenarioID, fmt.Sprintf("input-%02d.json", scenarioSeq))
			if err := writeJSON(path, fixture); err != nil {
				logger.Error("write fixture", "path", path, "err", err)
				continue
			}
			logger.Info("captured", "scenario", s.scenarioID, "seq", scenarioSeq, "topic", topic, "path", path)
		}
		if !matched {
			// Not a scenario we care about — silently skip.
			return
		}
	}

	opts.SetDefaultPublishHandler(onMessage)

	client := paho.NewClient(opts)
	tok := client.Connect()
	if !tok.WaitTimeout(30 * time.Second) {
		return fmt.Errorf("connect timeout")
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	logger.Info("connected", "broker", broker, "client_id", clientID)

	subTok := client.Subscribe(topicFilter, 0, onMessage)
	if !subTok.WaitTimeout(10 * time.Second) {
		return fmt.Errorf("subscribe timeout")
	}
	if err := subTok.Error(); err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}
	logger.Info("subscribed", "topic_filter", topicFilter, "duration", duration, "max_per_scenario", maxPerScenario)

	// Wait for signal OR duration OR all scenarios full.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()
	deadline := time.After(duration)

loop:
	for {
		select {
		case <-ctx.Done():
			logger.Info("interrupted")
			break loop
		case <-deadline:
			logger.Info("duration elapsed")
			break loop
		case <-ticker.C:
			logger.Info("progress", "counts", counter.summary(), "total", counter.total.Load())
			if allScenariosFull(counter, maxPerScenario) {
				logger.Info("all scenarios full — stopping early")
				break loop
			}
		}
	}

	client.Disconnect(1000)
	logger.Info("done", "counts", counter.summary(), "total", counter.total.Load())
	return nil
}

func allScenariosFull(c *perScenarioCounter, cap int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.counts) < len(topicScenarios) {
		return false
	}
	for _, s := range topicScenarios {
		if c.counts[s.scenarioID] < cap {
			return false
		}
	}
	return true
}

func bytesToHex(b []byte) string {
	const hex = "0123456789abcdef"
	buf := make([]byte, len(b)*2)
	for i, c := range b {
		buf[i*2] = hex[c>>4]
		buf[i*2+1] = hex[c&0x0f]
	}
	return string(buf)
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}
