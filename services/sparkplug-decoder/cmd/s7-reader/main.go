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
//     IGNORANT: no birth, no alias table, no seq — just readings. In this mode a
//     SINGLE s7-reader drives EVERY S7 endpoint in the mounted client.yaml (one
//     poller + PLC connection each) — the multi-PLC path (ADR-0045). Pin one with
//     --endpoint; leave it empty to drive them all.
//   - LEGACY SparkPlug (--raw-emit=false): republish directly as SparkPlug B —
//     retained NBIRTH with the name↔alias table on connect, NDATA with
//     alias-only values every tick. Kept byte-for-byte for the plc-sim/staging
//     path and back-compat. Single endpoint only.
//
// Config-driven via --client-config (per-tenant client.yaml s7_tag_map, ADR-0019
// G4). Each endpoint's host is external (secret): the protocol-wide S7_HOST env
// (single-endpoint), or a per-endpoint PLC_HOST_<NAME> override (multi-PLC) —
// see internal/rawemit.HostForEndpoint. Empty --client-config ⇒ the PR1 demo tags.
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
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/rawemit"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/s7"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

func main() {
	broker := flag.String("broker", getenv("MQTT_BROKER_URL", "tcp://mosquitto:1883"), "MQTT broker")
	edgeNode := flag.String("edge-node", getenv("S7_EDGE_NODE", "s7-reader"), "Sparkplug edge node id")
	group := flag.String("group", getenv("S7_GROUP", "INCOPLAST"), "Sparkplug group_id (tenant)")
	s7Host := flag.String("s7-host", getenv("S7_HOST", ""), "S7 PLC host:port (or IP) — protocol-wide fallback host")
	s7Rack := flag.Int("s7-rack", getenvInt("S7_RACK", 0), "S7 rack")
	s7Slot := flag.Int("s7-slot", getenvInt("S7_SLOT", 2), "S7 slot")
	tickSec := flag.Int("tick", getenvInt("S7_TICK_SEC", 5), "seconds between NDATA reads")
	db := flag.Int("db", getenvInt("S7_DB", 100), "data block number for the demo tag set")
	clientCfg := flag.String("client-config", getenv("CLIENT_CONFIG", ""), "path to client.yaml (s7_tag_map); empty = demo tags")
	endpoint := flag.String("endpoint", getenv("S7_ENDPOINT", ""), "plc.endpoints[].name to drive (with --client-config); empty = ALL S7 endpoints")
	rawEmit := flag.Bool("raw-emit", getenvBool("RAW_EMIT", true), "emit raw-tag envelopes to edge/raw/<tenant> (agent owns SparkPlug); false = legacy direct SparkPlug B")
	tenant := flag.String("tenant", getenv("TENANT", ""), "raw-emit tenant for edge/raw/<tenant> (default: lowercased --group)")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "s7-reader")
	if *tenant == "" {
		*tenant = strings.ToLower(*group)
	}

	// RAW-EMIT (default, ADR-0042 Option A): drive every S7 endpoint in the
	// client.yaml (or the one pinned by --endpoint), each publishing raw-tag
	// envelopes to edge/raw/<tenant>. The local sparkplug-agent owns birth/alias/
	// seq/mTLS.
	if *rawEmit {
		eps := buildEndpoints(logger, *clientCfg, *endpoint, *s7Host, *s7Rack, *s7Slot, *db, *tickSec)
		opts := paho.NewClientOptions().AddBroker(*broker).
			SetClientID("s7-reader-" + fmt.Sprint(os.Getpid())).
			SetAutoReconnect(true).SetConnectRetry(true)
		rawemit.Run(logger, opts, *broker, *tenant, *tickSec, eps)
		return
	}

	runLegacy(logger, *broker, *edgeNode, *group, *clientCfg, *endpoint, *s7Host, *s7Rack, *s7Slot, *db, *tickSec)
}

// buildEndpoints compiles the set of rawemit.Endpoints this reader drives. With a
// client.yaml it drives ALL S7 endpoints (or the single pinned --endpoint); with
// none it falls back to the PR1 demo tag set (one synthetic endpoint). Each
// endpoint resolves its own host (PLC_HOST_<NAME> override → S7_HOST fallback), so
// a multi-PLC client gives each cell a distinct host. Exits 0 when there is
// nothing to drive (so the umbrella `reader` profile can start this reader for a
// client with no S7 line without crash-looping); exits 1 on a real misconfig.
func buildEndpoints(logger *slog.Logger, clientCfg, endpoint, s7HostFallback string, rack, slot, db, tickSec int) []rawemit.Endpoint {
	timeout := time.Duration(tickSec) * time.Second

	// Demo path — no client.yaml: one synthetic endpoint "s7", full-name emit.
	if clientCfg == "" {
		if s7HostFallback == "" {
			logger.Error("S7_HOST is required for the demo path (no --client-config) — refusing to start")
			os.Exit(1)
		}
		poller, err := s7.NewPoller(demoTags(db))
		if err != nil {
			logger.Error("build demo poller", "err", err)
			os.Exit(1)
		}
		client := s7.NewClient(s7HostFallback, rack, slot, timeout)
		logger.Info("s7-reader demo tags", "plc_set", true, "rack", rack, "slot", slot)
		return []rawemit.Endpoint{sampleEndpoint("s7", "", poller, client)}
	}

	cfg, err := clientconfig.Load(clientCfg)
	if err != nil {
		logger.Error("load client config", "path", clientCfg, "err", err)
		os.Exit(1)
	}

	names := s7.Endpoints(cfg)
	if endpoint != "" {
		// A pinned --endpoint restricts this reader to that one endpoint. If it is
		// not an S7 endpoint (e.g. READER_ENDPOINT names a Modbus cell under the
		// umbrella profile), there is nothing for THIS reader to drive — retire
		// cleanly rather than error.
		if !contains(names, endpoint) {
			logger.Info("pinned --endpoint is not an S7 endpoint in client.yaml — nothing to drive", "endpoint", endpoint)
			os.Exit(0)
		}
		names = []string{endpoint}
	}
	if len(names) == 0 {
		logger.Info("no S7 endpoints in client.yaml — nothing to drive", "path", clientCfg)
		os.Exit(0)
	}

	var eps []rawemit.Endpoint
	for _, name := range names {
		host := rawemit.HostForEndpoint(name, s7HostFallback)
		if host == "" {
			logger.Warn("no host for S7 endpoint — set PLC_HOST_<NAME> or S7_HOST — skipping", "endpoint", name)
			continue
		}
		r, s := rack, slot
		if ep, ok := s7.FindEndpoint(cfg, name); ok {
			if ep.Rack != nil {
				r = *ep.Rack
			}
			if ep.Slot != nil {
				s = *ep.Slot
			}
		}
		tags, err := s7.TagsForEndpoint(cfg, name)
		if err != nil {
			logger.Error("compile s7 tag map", "endpoint", name, "err", err)
			os.Exit(1)
		}
		poller, err := s7.NewPoller(tags)
		if err != nil {
			logger.Error("build poller", "endpoint", name, "err", err)
			os.Exit(1)
		}
		client := s7.NewClient(host, r, s, timeout)
		logger.Info("s7 endpoint compiled", "endpoint", name, "tags", len(tags), "rack", r, "slot", s, "host_set", true)
		eps = append(eps, sampleEndpoint(name, cfg.CanonicalPrefix, poller, client))
	}
	if len(eps) == 0 {
		logger.Error("S7 endpoints present in client.yaml but none had a host — set PLC_HOST_<NAME> or S7_HOST", "endpoints", len(names))
		os.Exit(1)
	}
	return eps
}

// sampleEndpoint binds an s7 poller + client into a rawemit.Endpoint. The Sample
// closure captures both so package rawemit stays protocol-agnostic.
func sampleEndpoint(name, canonicalPrefix string, poller *s7.Poller, client *s7.Client) rawemit.Endpoint {
	return rawemit.Endpoint{
		Name:            name,
		CanonicalPrefix: canonicalPrefix,
		Sample:          func(birth bool) ([]sparkplug.SimMetric, error) { return poller.Sample(client.Read, birth) },
		Close:           client.Close,
	}
}

// demoTags is the PR1 hardcoded demo tag set (one Incoplast machine), used when
// no --client-config is given. Full metric names (no canonical prefix to strip).
func demoTags(db int) []s7.Tag {
	const prefix = "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15"
	return []s7.Tag{
		{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, DB: db, Offset: 0, Type: s7.TypeDInt},
		{Metric: prefix + "/Admin/ProdConsumedCount/1/Unit", Alias: 2, DB: db, Offset: 4, Type: s7.TypeDInt},
		{Metric: prefix + "/Status/MachSpeed", Alias: 3, DB: db, Offset: 8, Type: s7.TypeReal},
		{Metric: prefix + "/Status/StateCurrent", Alias: 4, DB: db, Offset: 12, Type: s7.TypeInt, Long: true},
	}
}

// runLegacy is the --raw-emit=false direct-SparkPlug path: ONE endpoint,
// retained NBIRTH + alias-only NDATA. Kept byte-for-byte for the plc-sim/staging
// back-compat path (multi-endpoint is a raw-emit-only concern).
func runLegacy(logger *slog.Logger, broker, edgeNode, group, clientCfg, endpoint, s7Host string, rack, slot, db, tickSec int) {
	if s7Host == "" {
		logger.Error("S7_HOST is required (the PLC endpoint) — refusing to start")
		os.Exit(1)
	}
	var tags []s7.Tag
	if clientCfg != "" {
		cfg, err := clientconfig.Load(clientCfg)
		if err != nil {
			logger.Error("load client config", "path", clientCfg, "err", err)
			os.Exit(1)
		}
		if ep, ok := s7.FindEndpoint(cfg, endpoint); ok {
			if ep.Rack != nil {
				rack = *ep.Rack
			}
			if ep.Slot != nil {
				slot = *ep.Slot
			}
		}
		tags, err = s7.TagsForEndpoint(cfg, endpoint)
		if err != nil {
			logger.Error("compile s7 tag map", "endpoint", endpoint, "err", err)
			os.Exit(1)
		}
		logger.Info("loaded s7 tag map from config", "path", clientCfg, "endpoint", endpoint, "tags", len(tags))
	} else {
		tags = demoTags(db)
	}
	poller, err := s7.NewPoller(tags)
	if err != nil {
		logger.Error("build poller", "err", err)
		os.Exit(1)
	}

	client := s7.NewClient(s7Host, rack, slot, time.Duration(tickSec)*time.Second)
	defer client.Close()

	opts := paho.NewClientOptions().AddBroker(broker).
		SetClientID("s7-reader-" + fmt.Sprint(os.Getpid())).
		SetAutoReconnect(true).SetConnectRetry(true)

	publishBirth := func(c paho.Client) {
		body, err := poller.EncodeBirth(client.Read)
		if err != nil {
			// PLC unreachable at connect — log and let the tick loop retry;
			// the NBIRTH is re-published on the next successful read.
			logger.Warn("NBIRTH skipped (PLC read failed)", "err", err)
			return
		}
		tok := c.Publish("spBv1.0/"+group+"/NBIRTH/"+edgeNode, 0, true, body)
		tok.Wait()
		logger.Info("NBIRTH published", "group", group, "node", edgeNode)
	}

	// birthed tracks whether a retained NBIRTH is currently valid. It drops to
	// false whenever a PLC read fails, so the next successful read re-publishes
	// the birth before any NDATA — the StateStore drops DATA seen before BIRTH.
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
	logger.Info("s7-reader running", "plc", s7Host, "rack", rack, "slot", slot, "tick_sec", tickSec)

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
