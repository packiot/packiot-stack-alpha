// modbus-reader — reads a Modbus TCP PLC and publishes its registers/coils at the
// factory edge, making a real Modbus line (e.g. a CPACK Modbus machine) look to
// the rest of the stack exactly like plc-sim / a native SparkPlug PLC. It is an
// additive PRODUCER: the edge-transformer decode→transform→publish pipeline
// consumes it unchanged, so onboarding a real Modbus client needs no hot-path
// changes. This is the Modbus sibling of cmd/s7-reader — same shape, same two
// emit modes.
//
// Two emit modes (--raw-emit, default TRUE — ADR-0042 Option A):
//
//   - RAW-EMIT (default): publish the plain-JSON raw-tag envelope (package
//     rawtag) to the LOOPBACK topic edge/raw/<tenant>. The local sparkplug-agent
//     subscribes there, decodes via rawtag.Decode, and owns ALL SparkPlug
//     assembly + mTLS uplink + store-and-forward. The reader is SparkPlug-
//     IGNORANT: no birth, no alias table, no seq — just readings.
//   - LEGACY SparkPlug (--raw-emit=false): republish directly as SparkPlug B —
//     retained NBIRTH with the name↔alias table on connect, NDATA with
//     alias-only values every tick. Kept byte-for-byte for the plc-sim/staging
//     path and back-compat.
//
// Config-driven via --client-config + --endpoint (per-tenant client.yaml
// modbus_tag_map). The device host + unit id are external (secret / env
// MODBUS_HOST + MODBUS_UNIT_ID) so the descriptor carries no plaintext host.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/modbus"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("MODBUS_EDGE_NODE", "modbus-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("MODBUS_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	mbHost := flag.String("modbus-host", getenv("MODBUS_HOST", ""), "Modbus device host:port")
	mbUnit := flag.Int("modbus-unit", getenvInt("MODBUS_UNIT_ID", 1), "Modbus unit/slave id")
	tickSec := flag.Int("tick", getenvInt("MODBUS_TICK_SEC", 5), "seconds between NDATA reads")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (modbus_tag_map)")
	endpoint := flag.String("endpoint", getenv("MODBUS_ENDPOINT", ""), "plc.endpoints[].name to drive (with --client-config)")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "modbus-reader")
	if *mbHost == "" {
		logger.Error("MODBUS_HOST is required (the device endpoint) — refusing to start")
		os.Exit(1)
	}
	if *clientCfg == "" || *endpoint == "" {
		logger.Error("--client-config and --endpoint are required (modbus_tag_map is config-driven)")
		os.Exit(1)
	}
	if *tenant == "" {
		*tenant = strings.ToLower(*group)
	}

	cfg, err := clientconfig.Load(*clientCfg)
	if err != nil {
		logger.Error("load client config", "path", *clientCfg, "err", err)
		os.Exit(1)
	}
	// The endpoint's unit_id (when present) defaults the Modbus connection so
	// only the secret host_ref (→ MODBUS_HOST env) is external, mirroring how
	// s7-reader defaults rack/slot from the endpoint.
	if ep, ok := modbus.FindEndpoint(cfg, *endpoint); ok && ep.UnitID != nil {
		*mbUnit = *ep.UnitID
	}
	tags, err := modbus.TagsForEndpoint(cfg, *endpoint)
	if err != nil {
		logger.Error("compile modbus tag map", "endpoint", *endpoint, "err", err)
		os.Exit(1)
	}
	logger.Info("loaded modbus tag map from config", "path", *clientCfg, "endpoint", *endpoint, "tags", len(tags))

	poller, err := modbus.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := modbus.NewClient(*mbHost, byte(*mbUnit), time.Duration(*tickSec)*time.Second)
	defer client.Close()

	opts := paho.NewClientOptions().AddBroker(*broker).
		SetClientID("modbus-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	// RAW-EMIT (default, ADR-0042 Option A): publish plain-JSON raw-tag
	// envelopes to the loopback topic edge/raw/<tenant> and let the local
	// sparkplug-agent own birth/alias/seq/mTLS. No NBIRTH, no birthed state
	// machine — the agent is the SparkPlug session authority.
	if *rawEmit {
		runRawEmit(logger, opts, poller, client.Read, *broker, *tenant, *endpoint, *mbHost, *mbUnit, *tickSec)
		return
	}

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// Device unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (Modbus read failed)", "err", err)
			return
		}
		tok := c.Publish("spBv1.0/"+*group+"/NBIRTH/"+*edgeNode, 0, true, body)
		tok.Wait()
		logger.Info("NBIRTH published", "group", *group, "node", *edgeNode)
	}

	// birthed tracks whether a retained NBIRTH is currently valid. It drops to
	// false whenever a read fails, so the next successful read re-publishes the
	// birth before any NDATA — the StateStore drops DATA seen before BIRTH.
	birthed := false
	opts.SetOnConnectHandler(func(c paho.Client) {
		logger.Info("MQTT connected", "broker", *broker)
		publishBirth(c)
		birthed = true
	})

	mqtt := paho.NewClient(opts)
	if tok := mqtt.Connect(); tok.Wait() && tok.Error() != nil {
		logger.Error("MQTT connect", "err", tok.Error())
		os.Exit(1)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	tick := time.NewTicker(time.Duration(*tickSec) * time.Second)
	defer tick.Stop()
	logger.Info("modbus-reader running", "device", *mbHost, "unit", *mbUnit, "tick_sec", *tickSec)

	for {
		select {
		case <-stop:
			logger.Info("modbus-reader stopping")
			mqtt.Disconnect(250)
			return
		case <-tick.C:
			if !birthed {
				// Recover from a prior read failure: re-birth before data.
				publishBirth(mqtt)
				birthed = true
				continue
			}
			body, err := poller.EncodeData(client.Read)
			if err != nil {
				logger.Warn("read/encode NDATA failed — will re-birth on recovery", "err", err)
				birthed = false // force NBIRTH once the device is reachable again
				continue
			}
			tok := mqtt.Publish("spBv1.0/"+*group+"/NDATA/"+*edgeNode, 0, false, body)
			tok.Wait()
		}
	}
}

// runRawEmit drives the ADR-0042 Option A path: each tick, sample the Modbus
// device and publish a plain-JSON raw-tag envelope to edge/raw/<tenant>. No
// SparkPlug, no birth — the local sparkplug-agent decodes the envelope
// (rawtag.Decode) and owns the wire protocol + uplink.
func runRawEmit(
	logger *slog.Logger,
	opts *paho.ClientOptions,
	poller *modbus.Poller,
	read modbus.ReadFunc,
	broker, tenant, endpoint, device string,
	unit, tickSec int,
) {
	topic := "edge/raw/" + tenant
	// The envelope endpoint field is diagnostic (ADR-0042 open-Q4); fall back
	// to a stable literal when --endpoint is empty.
	ep := endpoint
	if ep == "" {
		ep = "modbus"
	}

	opts.SetOnConnectHandler(func(c paho.Client) {
		logger.Info("MQTT connected", "broker", broker, "mode", "raw-emit", "topic", topic)
	})
	mqtt := paho.NewClient(opts)
	if tok := mqtt.Connect(); tok.Wait() && tok.Error() != nil {
		logger.Error("MQTT connect", "err", tok.Error())
		os.Exit(1)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	tick := time.NewTicker(time.Duration(tickSec) * time.Second)
	defer tick.Stop()
	logger.Info("modbus-reader running", "device", device, "unit", unit,
		"tick_sec", tickSec, "mode", "raw-emit", "topic", topic, "endpoint", ep)

	published := false
	lastCount := -1
	for {
		select {
		case <-stop:
			logger.Info("modbus-reader stopping")
			mqtt.Disconnect(250)
			return
		case <-tick.C:
			// birth=true so Sample populates metric NAMES. The raw envelope is
			// name-addressed every tick (no alias table on the loopback), and
			// Sample's birth flag only toggles name inclusion — it never touches
			// the poller seq (that lives in EncodeSim), so this has no SparkPlug
			// side effect. On read failure, skip the tick; no re-birth needed.
			ms, err := poller.Sample(read, true)
			if err != nil {
				logger.Warn("Modbus read failed — skipping tick", "err", err)
				continue
			}
			outTags := make([]rawtag.OutTag, 0, len(ms))
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
				outTags = append(outTags, rawtag.OutTag{Metric: m.Name, Value: v, Long: m.IsLong})
			}
			body, err := rawtag.Encode(ep, time.Now().UnixMilli(), outTags)
			if err != nil {
				logger.Warn("encode raw envelope failed — skipping tick", "err", err)
				continue
			}
			tok := mqtt.Publish(topic, 0, false, body)
			tok.Wait()
			// Log the first publish and any change in tag count; stay quiet on
			// steady-state ticks to avoid per-tick log spam.
			if !published || len(outTags) != lastCount {
				logger.Info("raw envelope published", "topic", topic, "endpoint", ep, "tags", len(outTags))
				published = true
				lastCount = len(outTags)
			}
		}
	}
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

// getenvBool reads a boolean env var (1/t/true/0/f/false, case-insensitive),
// falling back to d when unset or unparseable. Used for RAW_EMIT, which
// defaults to true.
func getenvBool(k string, d bool) bool {
	v := os.Getenv(k)
	if v == "" {
		return d
	}
	switch strings.ToLower(v) {
	case "1", "t", "true", "yes", "y", "on":
		return true
	case "0", "f", "false", "no", "n", "off":
		return false
	default:
		return d
	}
}
