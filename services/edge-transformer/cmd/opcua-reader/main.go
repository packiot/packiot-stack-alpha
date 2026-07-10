// opcua-reader — reads an OPC-UA server and republishes its nodes as SparkPlug B
// over MQTT, making a real OPC-UA line look to the rest of the stack exactly like
// plc-sim / a native SparkPlug PLC. It is an additive PRODUCER: the
// edge-transformer decode→transform→publish pipeline consumes it unchanged, so
// onboarding a real OPC-UA client needs no hot-path changes. This is the OPC-UA
// sibling of cmd/s7-reader and cmd/modbus-reader — same shape, same MQTT
// protocol (retained NBIRTH with the name↔alias table on connect, NDATA with
// alias-only values every tick).
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
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

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
