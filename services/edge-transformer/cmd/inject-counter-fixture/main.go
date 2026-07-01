// inject-counter-fixture — publishes a synthetic Sparkplug B NBIRTH +
// NDATA to a Mosquitto broker so we can validate the calc_production_
// counters port end-to-end.
//
// The NBIRTH establishes alias=1 for a ProdConsumedCount metric under
// a canned CPACK topic. The NDATA references alias=1 with an incremented
// value. edge-transformer's MQTT subscriber resolves alias→name via its
// StateStore, runs the Calc port (USE_GO_PORT=true), publishes to the
// shadowpub exchange, and the /metrics endpoint should show non-zero
// calc_evaluations_total counters afterward.
//
// Usage:
//
//	inject-counter-fixture --broker tcp://mosquitto:1883 --value 100
//
// Runs once and exits. No credentials by default (staging Mosquitto is
// on the compose network and unauthenticated).

package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

const (
	// Topic anatomy: spBv1.0/<GroupID>/<MessageType>/<EdgeNodeID>
	groupID    = "CPACK"
	edgeNodeID = "inject-test"

	// Counter metric name mirrors the production topic shape the port expects.
	// State machine doc §2 confirms 5+ segment convention:
	// Enterprise/Site/Area/Line/Unit/Admin/<CounterName>/<idx>/Unit
	consumedMetricName = "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"

	// Sparkplug B alias — must fit in uint64. Any small integer works.
	consumedAlias = uint64(1)
)

func main() {
	broker := flag.String("broker", "tcp://localhost:1883", "MQTT broker URL")
	value := flag.Int64("value", 100, "counter payload value for NDATA")
	clientID := flag.String("client-id", "edge-transformer-inject", "MQTT client ID")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

	if err := run(logger, *broker, *clientID, *value); err != nil {
		logger.Error("inject failed", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger, broker, clientID string, value int64) error {
	opts := paho.NewClientOptions().
		AddBroker(broker).
		SetClientID(clientID).
		SetCleanSession(true).
		SetConnectTimeout(10 * time.Second)

	client := paho.NewClient(opts)
	tok := client.Connect()
	if !tok.WaitTimeout(15 * time.Second) {
		return fmt.Errorf("connect timeout")
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	logger.Info("connected", "broker", broker, "client_id", clientID)

	// ── NBIRTH: establish the alias table ────────────────────────────────
	nbirthTopic := fmt.Sprintf("spBv1.0/%s/NBIRTH/%s", groupID, edgeNodeID)
	nbirthTs := uint64(time.Now().UnixMilli())
	nbirthPayload := &sparkplug.Payload{
		Timestamp: &nbirthTs,
		Seq:       proto64(0),
		Metrics: []*sparkplug.Metric{
			{
				Name:      strPtr(consumedMetricName),
				Alias:     proto64(consumedAlias),
				Timestamp: &nbirthTs,
				Datatype:  proto32(uint32(sparkplug.DataType_Int64)),
				Value: &sparkplug.Metric_LongValue{
					LongValue: uint64(0), // NBIRTH publishes the last-known value
				},
			},
			{
				Name:      strPtr("bdSeq"),
				Timestamp: &nbirthTs,
				Datatype:  proto32(uint32(sparkplug.DataType_Int64)),
				Value: &sparkplug.Metric_LongValue{
					LongValue: 0,
				},
			},
		},
	}
	nbirthBytes, err := sparkplug.Encode(nbirthPayload)
	if err != nil {
		return fmt.Errorf("encode NBIRTH: %w", err)
	}
	// NBIRTH is RETAINED (Sparkplug spec) so subscribers coming online later
	// still see the birth.
	tok = client.Publish(nbirthTopic, 0, true, nbirthBytes)
	if !tok.WaitTimeout(5 * time.Second) {
		return fmt.Errorf("publish NBIRTH timeout")
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("publish NBIRTH: %w", err)
	}
	logger.Info("published NBIRTH",
		"topic", nbirthTopic,
		"bytes", len(nbirthBytes),
		"metric_name", consumedMetricName,
		"alias", consumedAlias,
	)

	// Wait long enough for the transformer to process the NBIRTH before we
	// publish the NDATA. Empirically 500ms is enough.
	time.Sleep(500 * time.Millisecond)

	// ── NDATA: increment the counter, reference alias ────────────────────
	ndataTopic := fmt.Sprintf("spBv1.0/%s/NDATA/%s", groupID, edgeNodeID)
	ndataTs := uint64(time.Now().UnixMilli())
	ndataPayload := &sparkplug.Payload{
		Timestamp: &ndataTs,
		Seq:       proto64(1),
		Metrics: []*sparkplug.Metric{
			{
				Alias:     proto64(consumedAlias),
				Timestamp: &ndataTs,
				Datatype:  proto32(uint32(sparkplug.DataType_Int64)),
				Value: &sparkplug.Metric_LongValue{
					LongValue: uint64(value),
				},
			},
		},
	}
	ndataBytes, err := sparkplug.Encode(ndataPayload)
	if err != nil {
		return fmt.Errorf("encode NDATA: %w", err)
	}
	tok = client.Publish(ndataTopic, 0, false, ndataBytes)
	if !tok.WaitTimeout(5 * time.Second) {
		return fmt.Errorf("publish NDATA timeout")
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("publish NDATA: %w", err)
	}
	logger.Info("published NDATA",
		"topic", ndataTopic,
		"bytes", len(ndataBytes),
		"value", value,
	)

	// Small grace period so the transformer's Handler has time to process
	// before we disconnect (clean-session client).
	time.Sleep(200 * time.Millisecond)
	client.Disconnect(1000)
	logger.Info("inject complete — check /metrics for calc_evaluations_total")
	return nil
}

func strPtr(s string) *string { return &s }
func proto32(v uint32) *uint32 { return &v }
func proto64(v uint64) *uint64 { return &v }
