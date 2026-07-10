// modbus-reader — reads a Modbus TCP PLC and republishes its registers/coils as
// SparkPlug B over MQTT, making a real Modbus line (e.g. a CPACK Modbus machine)
// look to the rest of the stack exactly like plc-sim / a native SparkPlug PLC.
// It is an additive PRODUCER: the edge-transformer decode→transform→publish
// pipeline consumes it unchanged, so onboarding a real Modbus client needs no
// hot-path changes. This is the Modbus sibling of cmd/s7-reader — same shape,
// same MQTT protocol (retained NBIRTH with the name↔alias table on connect,
// NDATA with alias-only values every tick).
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
	"syscall"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

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
