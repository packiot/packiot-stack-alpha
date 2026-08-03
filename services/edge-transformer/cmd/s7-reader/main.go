// s7-reader — reads a Siemens S7 PLC and publishes its tags at the factory
// edge, making a real S7 line (e.g. Incoplast) look to the rest of the stack
// exactly like plc-sim. It is an additive PRODUCER: the pipeline downstream
// consumes it unchanged, so onboarding a real S7 client needs no hot-path
// changes.
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
// PR 1 (S1/#32): one endpoint, a hardcoded demo tag set. PR 2: per-tenant
// client.yaml s7_tag_map (ADR-0019 G4).
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
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/s7"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("S7_EDGE_NODE", "s7-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("S7_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	s7Host := flag.String("s7-host", getenv("S7_HOST", ""), "S7 PLC host:port (or IP)")
	s7Rack := flag.Int("s7-rack", getenvInt("S7_RACK", 0), "S7 rack")
	s7Slot := flag.Int("s7-slot", getenvInt("S7_SLOT", 2), "S7 slot")
	tickSec := flag.Int("tick", getenvInt("S7_TICK_SEC", 5), "seconds between NDATA reads")
	db := flag.Int("db", getenvInt("S7_DB", 100), "data block number for the demo tag set")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (s7_tag_map); empty = demo tags")
	endpoint := flag.String("endpoint", getenv("S7_ENDPOINT", ""), "plc.endpoints[].name to drive (with --client-config)")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "s7-reader")
	if *s7Host == "" {
		logger.Error("S7_HOST is required (the PLC endpoint) — refusing to start")
		os.Exit(1)
	}
	if *tenant == "" {
		*tenant = strings.ToLower(*group)
	}

	// Tag set: from client.yaml s7_tag_map (PR2) when --client-config is set,
	// else the PR1 hardcoded demo (one Incoplast machine). Config-driven is the
	// production-shaped path; the endpoint's rack/slot (when present) default
	// the S7 connection so only the secret host_ref (→ S7_HOST env) is external.
	var tags []s7.Tag
	if *clientCfg != "" {
		cfg, err := clientconfig.Load(*clientCfg)
		if err != nil {
			logger.Error("load client config", "path", *clientCfg, "err", err)
			os.Exit(1)
		}
		if ep, ok := s7.FindEndpoint(cfg, *endpoint); ok {
			if ep.Rack != nil {
				*s7Rack = *ep.Rack
			}
			if ep.Slot != nil {
				*s7Slot = *ep.Slot
			}
		}
		tags, err = s7.TagsForEndpoint(cfg, *endpoint)
		if err != nil {
			logger.Error("compile s7 tag map", "endpoint", *endpoint, "err", err)
			os.Exit(1)
		}
		logger.Info("loaded s7 tag map from config", "path", *clientCfg, "endpoint", *endpoint, "tags", len(tags))
	} else {
		const prefix = "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15"
		tags = []s7.Tag{
			{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, DB: *db, Offset: 0, Type: s7.TypeDInt},
			{Metric: prefix + "/Admin/ProdConsumedCount/1/Unit", Alias: 2, DB: *db, Offset: 4, Type: s7.TypeDInt},
			{Metric: prefix + "/Status/MachSpeed", Alias: 3, DB: *db, Offset: 8, Type: s7.TypeReal},
			{Metric: prefix + "/Status/StateCurrent", Alias: 4, DB: *db, Offset: 12, Type: s7.TypeInt, Long: true},
		}
	}
	poller, err := s7.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := s7.NewClient(*s7Host, *s7Rack, *s7Slot, time.Duration(*tickSec)*time.Second)
	defer client.Close()

	opts := paho.NewClientOptions().AddBroker(*broker).
		SetClientID("s7-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	// RAW-EMIT (default, ADR-0042 Option A): publish plain-JSON raw-tag
	// envelopes to the loopback topic edge/raw/<tenant> and let the local
	// sparkplug-agent own birth/alias/seq/mTLS. No NBIRTH, no birthed state
	// machine — the agent is the SparkPlug session authority.
	if *rawEmit {
		runRawEmit(logger, opts, poller, client.Read, *broker, *tenant, *endpoint, *s7Host, *s7Rack, *s7Slot, *tickSec)
		return
	}

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// PLC unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (PLC read failed)", "err", err)
			return
		}
		tok := c.Publish("spBv1.0/"+*group+"/NBIRTH/"+*edgeNode, 0, true, body)
		tok.Wait()
		logger.Info("NBIRTH published", "group", *group, "node", *edgeNode)
	}

	// birthed tracks whether a retained NBIRTH is currently valid. It drops to
	// false whenever a PLC read fails, so the next successful read re-publishes
	// the birth before any NDATA — the StateStore drops DATA seen before BIRTH.
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
	logger.Info("s7-reader running", "plc", *s7Host, "rack", *s7Rack, "slot", *s7Slot, "tick_sec", *tickSec)

	for {
		select {
		case <-stop:
			logger.Info("s7-reader stopping")
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
				birthed = false // force NBIRTH once the PLC is reachable again
				continue
			}
			tok := mqtt.Publish("spBv1.0/"+*group+"/NDATA/"+*edgeNode, 0, false, body)
			tok.Wait()
		}
	}
}

// runRawEmit drives the ADR-0042 Option A path: each tick, sample the PLC and
// publish a plain-JSON raw-tag envelope to edge/raw/<tenant>. No SparkPlug, no
// birth — the local sparkplug-agent decodes the envelope (rawtag.Decode) and
// owns the wire protocol + uplink.
func runRawEmit(
	logger *slog.Logger,
	opts *paho.ClientOptions,
	poller *s7.Poller,
	read s7.ReadFunc,
	broker, tenant, endpoint, host string,
	rack, slot, tickSec int,
) {
	topic := "edge/raw/" + tenant
	// The envelope endpoint field is diagnostic (ADR-0042 open-Q4); fall back
	// to a stable literal when --endpoint is empty (demo-tag mode).
	ep := endpoint
	if ep == "" {
		ep = "s7"
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
	logger.Info("s7-reader running", "plc", host, "rack", rack, "slot", slot,
		"tick_sec", tickSec, "mode", "raw-emit", "topic", topic, "endpoint", ep)

	published := false
	lastCount := -1
	for {
		select {
		case <-stop:
			logger.Info("s7-reader stopping")
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
				logger.Warn("PLC read failed — skipping tick", "err", err)
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
