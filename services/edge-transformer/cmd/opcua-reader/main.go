// opcua-reader — reads an OPC-UA server and publishes its nodes at the factory
// edge, making a real OPC-UA line look to the rest of the stack exactly like
// plc-sim / a native SparkPlug PLC. It is an additive PRODUCER: the
// edge-transformer decode→transform→publish pipeline consumes it unchanged, so
// onboarding a real OPC-UA client needs no hot-path changes. This is the OPC-UA
// sibling of cmd/s7-reader and cmd/modbus-reader — same shape, same two emit
// modes.
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
// opcua_tag_map). The endpoint URL is external (secret / env OPCUA_ENDPOINT_URL)
// so the descriptor carries no plaintext host. Security policy/mode come from the
// endpoint (default None for the MVP; see internal/opcua/client.go).
package main

import (
	"context"
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
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/opcua"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("OPCUA_EDGE_NODE", "opcua-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("OPCUA_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	endpointURL := flag.String("endpoint-url", getenv("OPCUA_ENDPOINT_URL", ""), "OPC-UA endpoint URL (opc.tcp://host:port/path)")
	tickSec := flag.Int("tick", getenvInt("OPCUA_TICK_SEC", 5), "seconds between NDATA reads")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (opcua_tag_map)")
	endpoint := flag.String("endpoint", getenv("OPCUA_ENDPOINT", ""), "plc.endpoints[].name to drive (with --client-config)")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "opcua-reader")
	if *endpointURL == "" {
		logger.Error("OPCUA_ENDPOINT_URL is required (the server endpoint) — refusing to start")
		os.Exit(1)
	}
	if *clientCfg == "" || *endpoint == "" {
		logger.Error("--client-config and --endpoint are required (opcua_tag_map is config-driven)")
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
	// The endpoint's security_policy / security_mode (when present) default the
	// OPC-UA connection so only the secret endpoint_url_ref (→ OPCUA_ENDPOINT_URL
	// env) is external, mirroring how s7-reader defaults rack/slot.
	policy, mode := "None", "None"
	if ep, ok := opcua.FindEndpoint(cfg, *endpoint); ok {
		if ep.SecurityPolicy != "" {
			policy = ep.SecurityPolicy
		}
		if ep.SecurityMode != "" {
			mode = ep.SecurityMode
		}
	}
	tags, err := opcua.TagsForEndpoint(cfg, *endpoint)
	if err != nil {
		logger.Error("compile opcua tag map", "endpoint", *endpoint, "err", err)
		os.Exit(1)
	}
	logger.Info("loaded opcua tag map from config", "path", *clientCfg, "endpoint", *endpoint, "tags", len(tags))

	poller, err := opcua.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := opcua.NewClient(*endpointURL, policy, mode, time.Duration(*tickSec)*time.Second)
	defer client.Close()

	// Dial the server up front so a bad URL / unreachable OT VLAN fails at boot
	// rather than silently skipping the first NBIRTH. A failed dial is not fatal
	// — the tick loop retries — but logging it here surfaces the misconfig fast.
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*tickSec)*time.Second)
	if err := client.Connect(ctx); err != nil {
		logger.Warn("initial OPC-UA connect failed — will retry on tick", "err", err)
	}
	cancel()

	opts := paho.NewClientOptions().AddBroker(*broker).
		SetClientID("opcua-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	// RAW-EMIT (default, ADR-0042 Option A): publish plain-JSON raw-tag
	// envelopes to the loopback topic edge/raw/<tenant> and let the local
	// sparkplug-agent own birth/alias/seq/mTLS. No NBIRTH, no birthed state
	// machine — the agent is the SparkPlug session authority.
	if *rawEmit {
		runRawEmit(logger, opts, poller, client.Read, *broker, *tenant, *endpoint, *endpointURL, policy, mode, *tickSec)
		return
	}

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// Server unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (OPC-UA read failed)", "err", err)
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
	logger.Info("opcua-reader running", "endpoint_url", *endpointURL, "policy", policy, "mode", mode, "tick_sec", *tickSec)

	for {
		select {
		case <-stop:
			logger.Info("opcua-reader stopping")
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
				birthed = false // force NBIRTH once the server is reachable again
				continue
			}
			tok := mqtt.Publish("spBv1.0/"+*group+"/NDATA/"+*edgeNode, 0, false, body)
			tok.Wait()
		}
	}
}

// runRawEmit drives the ADR-0042 Option A path: each tick, sample the OPC-UA
// server and publish a plain-JSON raw-tag envelope to edge/raw/<tenant>. No
// SparkPlug, no birth — the local sparkplug-agent decodes the envelope
// (rawtag.Decode) and owns the wire protocol + uplink.
func runRawEmit(
	logger *slog.Logger,
	opts *paho.ClientOptions,
	poller *opcua.Poller,
	read opcua.ReadFunc,
	broker, tenant, endpoint, endpointURL, policy, mode string,
	tickSec int,
) {
	topic := "edge/raw/" + tenant
	// The envelope endpoint field is diagnostic (ADR-0042 open-Q4); fall back
	// to a stable literal when --endpoint is empty.
	ep := endpoint
	if ep == "" {
		ep = "opcua"
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
	logger.Info("opcua-reader running", "endpoint_url", endpointURL, "policy", policy, "mode", mode,
		"tick_sec", tickSec, "emit_mode", "raw-emit", "topic", topic, "endpoint", ep)

	published := false
	lastCount := -1
	for {
		select {
		case <-stop:
			logger.Info("opcua-reader stopping")
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
				logger.Warn("OPC-UA read failed — skipping tick", "err", err)
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
