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
//     IGNORANT: no birth, no alias table, no seq — just readings. In this mode a
//     SINGLE modbus-reader drives EVERY Modbus endpoint in the mounted
//     client.yaml (one poller + device connection each) — the multi-PLC path
//     (ADR-0045). Pin one with --endpoint; leave it empty to drive them all.
//   - LEGACY SparkPlug (--raw-emit=false): republish directly as SparkPlug B —
//     retained NBIRTH with the name↔alias table on connect, NDATA with
//     alias-only values every tick. Kept byte-for-byte for the plc-sim/staging
//     path and back-compat. Single endpoint only.
//
// Config-driven via --client-config (per-tenant client.yaml modbus_tag_map). Each
// endpoint's host is external (secret): the protocol-wide MODBUS_HOST env
// (single-endpoint), or a per-endpoint PLC_HOST_<NAME> override (multi-PLC) — see
// internal/rawemit.HostForEndpoint.
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

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/modbus"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/rawemit"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("MODBUS_EDGE_NODE", "modbus-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("MODBUS_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	mbHost := flag.String("modbus-host", getenv("MODBUS_HOST", ""), "Modbus device host:port — protocol-wide fallback host")
	mbUnit := flag.Int("modbus-unit", getenvInt("MODBUS_UNIT_ID", 1), "Modbus unit/slave id")
	tickSec := flag.Int("tick", getenvInt("MODBUS_TICK_SEC", 5), "seconds between NDATA reads")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (modbus_tag_map)")
	endpoint := flag.String("endpoint", getenv("MODBUS_ENDPOINT", ""), "plc.endpoints[].name to drive; empty = ALL Modbus endpoints")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "modbus-reader")
	if *clientCfg == "" {
		logger.Error("--client-config is required (modbus_tag_map is config-driven)")
		os.Exit(1)
	}
	if *tenant == "" {
		*tenant = strings.ToLower(*group)
	}

	// RAW-EMIT (default): drive every Modbus endpoint in the client.yaml (or the
	// one pinned by --endpoint), each publishing raw-tag envelopes to
	// edge/raw/<tenant>. The local sparkplug-agent owns birth/alias/seq/mTLS.
	if *rawEmit {
		eps := buildEndpoints(logger, *clientCfg, *endpoint, *mbHost, *mbUnit, *tickSec)
		opts := paho.NewClientOptions().AddBroker(*broker).
			SetClientID("modbus-reader-" + fmt.Sprint(os.Getpid())).
			SetAutoReconnect(true).SetConnectRetry(true)
		rawemit.Run(logger, opts, *broker, *tenant, *tickSec, eps)
		return
	}

	runLegacy(logger, *broker, *edgeNode, *group, *clientCfg, *endpoint, *mbHost, *mbUnit, *tickSec)
}

// buildEndpoints compiles the set of rawemit.Endpoints this reader drives: ALL
// Modbus endpoints in the client.yaml (or the single pinned --endpoint). Each
// resolves its own host (PLC_HOST_<NAME> override → MODBUS_HOST fallback) and its
// unit id (from the endpoint's unit_id, else MODBUS_UNIT_ID). Exits 0 when there
// is nothing to drive (umbrella `reader` profile on a client with no Modbus line);
// exits 1 on a real misconfig.
func buildEndpoints(logger *slog.Logger, clientCfg, endpoint, mbHostFallback string, unitFallback, tickSec int) []rawemit.Endpoint {
	timeout := time.Duration(tickSec) * time.Second

	cfg, err := clientconfig.Load(clientCfg)
	if err != nil {
		logger.Error("load client config", "path", clientCfg, "err", err)
		os.Exit(1)
	}

	names := modbus.Endpoints(cfg)
	if endpoint != "" {
		if !contains(names, endpoint) {
			logger.Info("pinned --endpoint is not a Modbus endpoint in client.yaml — nothing to drive", "endpoint", endpoint)
			os.Exit(0)
		}
		names = []string{endpoint}
	}
	if len(names) == 0 {
		logger.Info("no Modbus endpoints in client.yaml — nothing to drive", "path", clientCfg)
		os.Exit(0)
	}

	var eps []rawemit.Endpoint
	for _, name := range names {
		host := rawemit.HostForEndpoint(name, mbHostFallback)
		if host == "" {
			logger.Warn("no host for Modbus endpoint — set PLC_HOST_<NAME> or MODBUS_HOST — skipping", "endpoint", name)
			continue
		}
		unit := unitFallback
		if ep, ok := modbus.FindEndpoint(cfg, name); ok && ep.UnitID != nil {
			unit = *ep.UnitID
		}
		tags, err := modbus.TagsForEndpoint(cfg, name)
		if err != nil {
			logger.Error("compile modbus tag map", "endpoint", name, "err", err)
			os.Exit(1)
		}
		poller, err := modbus.NewPoller(tags)
		if err != nil {
			logger.Error("build poller", "endpoint", name, "err", err)
			os.Exit(1)
		}
		client := modbus.NewClient(host, byte(unit), timeout)
		logger.Info("modbus endpoint compiled", "endpoint", name, "tags", len(tags), "unit", unit, "host_set", true)
		eps = append(eps, sampleEndpoint(name, cfg.CanonicalPrefix, poller, client))
	}
	if len(eps) == 0 {
		logger.Error("Modbus endpoints present in client.yaml but none had a host — set PLC_HOST_<NAME> or MODBUS_HOST", "endpoints", len(names))
		os.Exit(1)
	}
	return eps
}

// sampleEndpoint binds a modbus poller + client into a rawemit.Endpoint.
func sampleEndpoint(name, canonicalPrefix string, poller *modbus.Poller, client *modbus.Client) rawemit.Endpoint {
	return rawemit.Endpoint{
		Name:            name,
		CanonicalPrefix: canonicalPrefix,
		Sample:          func(birth bool) ([]sparkplug.SimMetric, error) { return poller.Sample(client.Read, birth) },
		Close:           client.Close,
	}
}

// runLegacy is the --raw-emit=false direct-SparkPlug path: ONE endpoint,
// retained NBIRTH + alias-only NDATA. Kept byte-for-byte for back-compat.
func runLegacy(logger *slog.Logger, broker, edgeNode, group, clientCfg, endpoint, mbHost string, mbUnit, tickSec int) {
	if mbHost == "" {
		logger.Error("MODBUS_HOST is required (the device endpoint) — refusing to start")
		os.Exit(1)
	}
	if endpoint == "" {
		logger.Error("--endpoint is required on the legacy path (modbus_tag_map is config-driven)")
		os.Exit(1)
	}
	cfg, err := clientconfig.Load(clientCfg)
	if err != nil {
		logger.Error("load client config", "path", clientCfg, "err", err)
		os.Exit(1)
	}
	if ep, ok := modbus.FindEndpoint(cfg, endpoint); ok && ep.UnitID != nil {
		mbUnit = *ep.UnitID
	}
	tags, err := modbus.TagsForEndpoint(cfg, endpoint)
	if err != nil {
		logger.Error("compile modbus tag map", "endpoint", endpoint, "err", err)
		os.Exit(1)
	}
	logger.Info("loaded modbus tag map from config", "path", clientCfg, "endpoint", endpoint, "tags", len(tags))

	poller, err := modbus.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := modbus.NewClient(mbHost, byte(mbUnit), time.Duration(tickSec)*time.Second)
	defer client.Close()

	opts := paho.NewClientOptions().AddBroker(broker).
		SetClientID("modbus-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// Device unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (Modbus read failed)", "err", err)
			return
		}
		tok := c.Publish("spBv1.0/"+group+"/NBIRTH/"+edgeNode, 0, true, body)
		tok.Wait()
		logger.Info("NBIRTH published", "group", group, "node", edgeNode)
	}

	// birthed tracks whether a retained NBIRTH is currently valid. It drops to
	// false whenever a read fails, so the next successful read re-publishes the
	// birth before any NDATA — the StateStore drops DATA seen before BIRTH.
	birthed := false
	opts.SetOnConnectHandler(func(c paho.Client) {
		logger.Info("MQTT connected", "broker", broker)
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
	tick := time.NewTicker(time.Duration(tickSec) * time.Second)
	defer tick.Stop()
	logger.Info("modbus-reader running", "device", mbHost, "unit", mbUnit, "tick_sec", tickSec)

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
			tok := mqtt.Publish("spBv1.0/"+group+"/NDATA/"+edgeNode, 0, false, body)
			tok.Wait()
		}
	}
}

// contains reports whether s is in xs.
func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
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
