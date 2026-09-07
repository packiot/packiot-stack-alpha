// Package rawemit drives the ADR-0042 Option A raw-emit path shared by the s7,
// modbus and opcua readers. Each factory PLC endpoint is polled on its OWN
// goroutine and published as a plain-JSON raw-tag envelope (package rawtag) to
// the loopback topic edge/raw/<tenant>, where the local sparkplug-agent owns ALL
// SparkPlug assembly + mTLS uplink + store-and-forward. The reader stays
// SparkPlug-IGNORANT: no birth, no alias table, no seq — just readings.
//
// WHY THIS PACKAGE EXISTS (ADR-0045 config-as-data, multi-PLC clients):
//
// A real client (e.g. CPACK: 9 S7 + 1 Modbus) has MANY PLC endpoints of the
// same protocol, each a distinct host. The single-endpoint reader could not
// deploy such a client. This package lets ONE protocol reader process drive
// EVERY endpoint of its protocol from the mounted client.yaml — one poller +
// one PLC connection per endpoint, all publishing to the same edge/raw/<tenant>
// topic over ONE shared MQTT connection. The agent already assembles
// per-equipment from edge/raw/<tenant>, so multi-source composition (an S7
// counter + a Modbus speed feeding one equipment) just works once both readers
// emit. N endpoints ⇒ ≤3 reader services, config-driven — no per-endpoint
// service explosion.
//
// The three cmd/*-reader mains build a []Endpoint (protocol-specific poller +
// PLC client construction) and hand it to Run; the multi-endpoint concurrency,
// the canonical_prefix→metric_suffix strip (ADR-0045 §C), and the envelope
// encoding all live HERE, once.
package rawemit

import (
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// Endpoint is one PLC endpoint to drive. Sample binds a protocol poller to its
// PLC client's Read (the reader main builds the closure so this package stays
// protocol-agnostic). CanonicalPrefix is stripped off each metric NAME so the
// reader emits the GROUP-RELATIVE metric_suffix the agent resolves by (ADR-0045
// §C — newResolver keys byName on metric_suffix; do NOT regress this). Close
// releases the underlying PLC connection at shutdown.
type Endpoint struct {
	Name            string
	CanonicalPrefix string
	Sample          func(birth bool) ([]sparkplug.SimMetric, error)
	Close           func() error
}

// HostForEndpoint resolves an endpoint's connection string. A per-endpoint
// override PLC_HOST_<NAME> (NAME upper-cased, every non-alphanumeric → '_') wins,
// so a multi-PLC client gives each endpoint its own host in .env
// (PLC_HOST_CELULA1=10.0.0.10:102, PLC_HOST_CELULA2=…). When that is unset the
// protocol-wide fallback (S7_HOST / MODBUS_HOST / OPCUA_ENDPOINT_URL, passed in)
// is used — which keeps the pre-existing single-endpoint deploys working
// byte-for-byte. Empty result ⇒ the caller skips the endpoint (no host provisioned).
func HostForEndpoint(name, fallback string) string {
	if v := os.Getenv("PLC_HOST_" + envSuffix(name)); v != "" {
		return v
	}
	return fallback
}

// envSuffix normalizes an endpoint name into an env-var suffix: upper-cased with
// every non-[A-Z0-9] rune folded to '_'. Keeps PLC_HOST_<NAME> a valid shell/env
// identifier for names that carry '-', '.' or '/' (e.g. "CELL-1" → "CELL_1").
func envSuffix(name string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(name) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

// Run drives every endpoint concurrently over ONE shared MQTT connection and
// blocks until SIGINT/SIGTERM. Each endpoint ticks independently; a read failure
// on one endpoint skips only that endpoint's tick — the others keep publishing
// (a dead PLC never silences a healthy one). paho's Publish is goroutine-safe,
// so the shared client needs no extra locking.
func Run(logger *slog.Logger, opts *paho.ClientOptions, broker, tenant string, tickSec int, endpoints []Endpoint) {
	topic := "edge/raw/" + tenant
	opts.SetOnConnectHandler(func(c paho.Client) {
		logger.Info("MQTT connected", "broker", broker, "mode", "raw-emit", "topic", topic, "endpoints", len(endpoints))
	})
	mqtt := paho.NewClient(opts)
	if tok := mqtt.Connect(); tok.Wait() && tok.Error() != nil {
		logger.Error("MQTT connect", "err", tok.Error())
		os.Exit(1)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	var wg sync.WaitGroup
	done := make(chan struct{})
	for _, ep := range endpoints {
		wg.Add(1)
		go func(ep Endpoint) {
			defer wg.Done()
			defer func() { _ = ep.Close() }()
			runEndpoint(logger, mqtt, topic, tickSec, ep, done)
		}(ep)
	}

	<-stop
	logger.Info("reader stopping", "endpoints", len(endpoints))
	close(done)
	wg.Wait()
	mqtt.Disconnect(250)
}

// runEndpoint is the per-endpoint tick loop: each tick sample the PLC, convert to
// raw OutTags (canonical_prefix stripped), encode the envelope and publish. The
// envelope's endpoint field is Endpoint.Name (diagnostic; ADR-0042 open-Q4).
func runEndpoint(logger *slog.Logger, mqtt paho.Client, topic string, tickSec int, ep Endpoint, done <-chan struct{}) {
	log := logger.With("endpoint", ep.Name)
	tick := time.NewTicker(time.Duration(tickSec) * time.Second)
	defer tick.Stop()
	log.Info("endpoint driving", "topic", topic, "tick_sec", tickSec)

	published := false
	lastCount := -1
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			// birth=true so Sample populates metric NAMES. The raw envelope is
			// name-addressed every tick (no alias table on the loopback); Sample's
			// birth flag only toggles name inclusion — no SparkPlug side effect.
			ms, err := ep.Sample(true)
			if err != nil {
				log.Warn("PLC read failed — skipping tick", "err", err)
				continue
			}
			outTags := toOutTags(ep.CanonicalPrefix, ms)
			body, err := rawtag.Encode(ep.Name, time.Now().UnixMilli(), outTags)
			if err != nil {
				log.Warn("encode raw envelope failed — skipping tick", "err", err)
				continue
			}
			tok := mqtt.Publish(topic, 0, false, body)
			tok.Wait()
			// Log the first publish and any change in tag count; stay quiet on
			// steady-state ticks to avoid per-tick log spam.
			if !published || len(outTags) != lastCount {
				log.Info("raw envelope published", "topic", topic, "tags", len(outTags))
				published = true
				lastCount = len(outTags)
			}
		}
	}
}

// toOutTags converts a poller sample into raw-tag OutTags, stripping the
// canonical_prefix off each metric NAME so the reader emits the group-relative
// metric_suffix (ADR-0045 §C). Pure + exported-to-package for testing so the §C
// contract can be asserted without a live broker or PLC. An empty prefix ⇒
// TrimPrefix is a no-op (the demo-tag / no-canonical path emits the full name).
func toOutTags(canonicalPrefix string, ms []sparkplug.SimMetric) []rawtag.OutTag {
	out := make([]rawtag.OutTag, 0, len(ms))
	for _, m := range ms {
		var v any
		switch {
		case m.IsText:
			v = m.Text
		case m.IsLong:
			v = m.Long
		default:
			v = m.Double
		}
		out = append(out, rawtag.OutTag{Metric: strings.TrimPrefix(m.Name, canonicalPrefix), Value: v, Long: m.IsLong})
	}
	return out
}
