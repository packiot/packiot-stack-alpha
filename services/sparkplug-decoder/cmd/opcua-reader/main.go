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
//     IGNORANT: no birth, no alias table, no seq — just readings. In this mode a
//     SINGLE opcua-reader drives EVERY OPC-UA endpoint in the mounted client.yaml
//     (one poller + server session each) — the multi-PLC path (ADR-0045). Pin one
//     with --endpoint; leave it empty to drive them all.
//   - LEGACY SparkPlug (--raw-emit=false): republish directly as SparkPlug B —
//     retained NBIRTH with the name↔alias table on connect, NDATA with
//     alias-only values every tick. Kept byte-for-byte for the plc-sim/staging
//     path and back-compat. Single endpoint only.
//
// Config-driven via --client-config (per-tenant client.yaml opcua_tag_map). Each
// endpoint's URL is external (secret): the protocol-wide OPCUA_ENDPOINT_URL env
// (single-endpoint), or a per-endpoint PLC_HOST_<NAME> override (multi-server) —
// see internal/rawemit.HostForEndpoint. Security policy/mode come from the
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

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/clientconfig"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/opcua"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/rawemit"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("OPCUA_EDGE_NODE", "opcua-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("OPCUA_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	endpointURL := flag.String("endpoint-url", getenv("OPCUA_ENDPOINT_URL", ""), "OPC-UA endpoint URL — protocol-wide fallback (opc.tcp://host:port/path)")
	tickSec := flag.Int("tick", getenvInt("OPCUA_TICK_SEC", 5), "seconds between NDATA reads")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (opcua_tag_map)")
	endpoint := flag.String("endpoint", getenv("OPCUA_ENDPOINT", ""), "plc.endpoints[].name to drive; empty = ALL OPC-UA endpoints")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "opcua-reader")
	if *clientCfg == "" {
		logger.Error("--client-config is required (opcua_tag_map is config-driven)")
		os.Exit(1)
	}
	if *tenant == "" {
		*tenant = strings.ToLower(*group)
	}

	// RAW-EMIT (default): drive every OPC-UA endpoint in the client.yaml (or the
	// one pinned by --endpoint), each publishing raw-tag envelopes to
	// edge/raw/<tenant>. The local sparkplug-agent owns birth/alias/seq/mTLS.
	if *rawEmit {
		eps := buildEndpoints(logger, *clientCfg, *endpoint, *endpointURL, *tickSec)
		opts := paho.NewClientOptions().AddBroker(*broker).
			SetClientID("opcua-reader-" + fmt.Sprint(os.Getpid())).
			SetAutoReconnect(true).SetConnectRetry(true)
		rawemit.Run(logger, opts, *broker, *tenant, *tickSec, eps)
		return
	}

	runLegacy(logger, *broker, *edgeNode, *group, *clientCfg, *endpoint, *endpointURL, *tickSec)
}

// buildEndpoints compiles the set of rawemit.Endpoints this reader drives: ALL
// OPC-UA endpoints in the client.yaml (or the single pinned --endpoint). Each
// resolves its own URL (PLC_HOST_<NAME> override → OPCUA_ENDPOINT_URL fallback)
// and its security policy/mode (from the endpoint, default None). Exits 0 when
// there is nothing to drive (umbrella `reader` profile on a client with no OPC-UA
// line); exits 1 on a real misconfig.
func buildEndpoints(logger *slog.Logger, clientCfg, endpoint, urlFallback string, tickSec int) []rawemit.Endpoint {
	timeout := time.Duration(tickSec) * time.Second

	cfg, err := clientconfig.Load(clientCfg)
	if err != nil {
		logger.Error("load client config", "path", clientCfg, "err", err)
		os.Exit(1)
	}

	names := opcua.Endpoints(cfg)
	if endpoint != "" {
		if !contains(names, endpoint) {
			logger.Info("pinned --endpoint is not an OPC-UA endpoint in client.yaml — nothing to drive", "endpoint", endpoint)
			os.Exit(0)
		}
		names = []string{endpoint}
	}
	if len(names) == 0 {
		logger.Info("no OPC-UA endpoints in client.yaml — nothing to drive", "path", clientCfg)
		os.Exit(0)
	}

	var eps []rawemit.Endpoint
	for _, name := range names {
		url := rawemit.HostForEndpoint(name, urlFallback)
		if url == "" {
			logger.Warn("no URL for OPC-UA endpoint — set PLC_HOST_<NAME> or OPCUA_ENDPOINT_URL — skipping", "endpoint", name)
			continue
		}
		policy, mode := "None", "None"
		if ep, ok := opcua.FindEndpoint(cfg, name); ok {
			if ep.SecurityPolicy != "" {
				policy = ep.SecurityPolicy
			}
			if ep.SecurityMode != "" {
				mode = ep.SecurityMode
			}
		}
		tags, err := opcua.TagsForEndpoint(cfg, name)
		if err != nil {
			logger.Error("compile opcua tag map", "endpoint", name, "err", err)
			os.Exit(1)
		}
		poller, err := opcua.NewPoller(tags)
		if err != nil {
			logger.Error("build poller", "endpoint", name, "err", err)
			os.Exit(1)
		}
		client := opcua.NewClient(url, policy, mode, timeout)
		// Best-effort dial so a bad URL / unreachable OT VLAN surfaces at boot; not
		// fatal — Read lazily reconnects per tick.
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		if err := client.Connect(ctx); err != nil {
			logger.Warn("initial OPC-UA connect failed — will retry on tick", "endpoint", name, "err", err)
		}
		cancel()
		logger.Info("opcua endpoint compiled", "endpoint", name, "tags", len(tags), "policy", policy, "mode", mode, "url_set", true)
		eps = append(eps, sampleEndpoint(name, cfg.CanonicalPrefix, poller, client))
	}
	if len(eps) == 0 {
		logger.Error("OPC-UA endpoints present in client.yaml but none had a URL — set PLC_HOST_<NAME> or OPCUA_ENDPOINT_URL", "endpoints", len(names))
		os.Exit(1)
	}
	return eps
}

// sampleEndpoint binds an opcua poller + client into a rawemit.Endpoint.
func sampleEndpoint(name, canonicalPrefix string, poller *opcua.Poller, client *opcua.Client) rawemit.Endpoint {
	return rawemit.Endpoint{
		Name:            name,
		CanonicalPrefix: canonicalPrefix,
		Sample:          func(birth bool) ([]sparkplug.SimMetric, error) { return poller.Sample(client.Read, birth) },
		Close:           client.Close,
	}
}

// runLegacy is the --raw-emit=false direct-SparkPlug path: ONE endpoint,
// retained NBIRTH + alias-only NDATA. Kept byte-for-byte for back-compat.
func runLegacy(logger *slog.Logger, broker, edgeNode, group, clientCfg, endpoint, endpointURL string, tickSec int) {
	if endpointURL == "" {
		logger.Error("OPCUA_ENDPOINT_URL is required (the server endpoint) — refusing to start")
		os.Exit(1)
	}
	if endpoint == "" {
		logger.Error("--endpoint is required on the legacy path (opcua_tag_map is config-driven)")
		os.Exit(1)
	}
	cfg, err := clientconfig.Load(clientCfg)
	if err != nil {
		logger.Error("load client config", "path", clientCfg, "err", err)
		os.Exit(1)
	}
	policy, mode := "None", "None"
	if ep, ok := opcua.FindEndpoint(cfg, endpoint); ok {
		if ep.SecurityPolicy != "" {
			policy = ep.SecurityPolicy
		}
		if ep.SecurityMode != "" {
			mode = ep.SecurityMode
		}
	}
	tags, err := opcua.TagsForEndpoint(cfg, endpoint)
	if err != nil {
		logger.Error("compile opcua tag map", "endpoint", endpoint, "err", err)
		os.Exit(1)
	}
	logger.Info("loaded opcua tag map from config", "path", clientCfg, "endpoint", endpoint, "tags", len(tags))

	poller, err := opcua.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := opcua.NewClient(endpointURL, policy, mode, time.Duration(tickSec)*time.Second)
	defer client.Close()

	// Dial the server up front so a bad URL / unreachable OT VLAN fails at boot
	// rather than silently skipping the first NBIRTH. A failed dial is not fatal
	// — the tick loop retries — but logging it here surfaces the misconfig fast.
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(tickSec)*time.Second)
	if err := client.Connect(ctx); err != nil {
		logger.Warn("initial OPC-UA connect failed — will retry on tick", "err", err)
	}
	cancel()

	opts := paho.NewClientOptions().AddBroker(broker).
		SetClientID("opcua-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// Server unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (OPC-UA read failed)", "err", err)
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
	logger.Info("opcua-reader running", "endpoint_url", endpointURL, "policy", policy, "mode", mode, "tick_sec", tickSec)

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
