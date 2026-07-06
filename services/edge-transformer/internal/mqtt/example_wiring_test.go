// Example showing how the MQTT subscriber wires into the Sparkplug decoder.
// Serves as reference documentation for ADR-0010 Phase 2 integration.
//
// The Handler receives raw MQTT body bytes + the parsed Sparkplug topic.
// The typical implementation calls sparkplug.Decode and then dispatches
// based on the topic's MessageType (NBIRTH → build alias table, NDATA →
// resolve aliases + emit normalized envelope, etc.).
//
// This example is exercised only when the reader runs `go test -run
// ExampleSubscriberWiring`. It exists to make the wire visible AND to
// guarantee it compiles as `internal/sparkplug` evolves.

package mqtt_test

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/mqtt"
	sp "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// Example_wiring shows the canonical wire: MQTT body → sparkplug.Decode
// → dispatch by MessageType. The Subscriber's Handler is where downstream
// logic lives; here we just log summary info and (for NBIRTH) explain the
// alias-table implications.
func Example_wiring() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

	handler := func(ctx context.Context, topic mqtt.Topic, body []byte) error {
		payload, err := sp.Decode(body)
		if err != nil {
			return fmt.Errorf("sparkplug decode: %w", err)
		}

		switch topic.MessageType {
		case "NBIRTH", "DBIRTH":
			// Full metric names + aliases. Build (or refresh) the alias
			// table indexed by (GroupID, EdgeNodeID[, DeviceID]).
			logger.Info("birth",
				"group", topic.GroupID,
				"edge_node", topic.EdgeNodeID,
				"device", topic.DeviceID,
				"metrics", len(payload.GetMetrics()),
			)
		case "NDATA", "DDATA":
			// Alias-only. Resolve each metric's alias → name via the
			// per-publisher table built at NBIRTH.
			logger.Info("data",
				"group", topic.GroupID,
				"edge_node", topic.EdgeNodeID,
				"device", topic.DeviceID,
				"seq", payload.GetSeq(),
				"metrics", len(payload.GetMetrics()),
			)
		case "NDEATH", "DDEATH":
			// Node/device going away. Invalidate the alias table + wait
			// for a fresh NBIRTH.
			logger.Info("death",
				"group", topic.GroupID,
				"edge_node", topic.EdgeNodeID,
				"device", topic.DeviceID,
			)
		default:
			logger.Warn("unknown Sparkplug message type",
				"type", topic.MessageType,
				"topic", topic)
		}
		return nil
	}

	cfg := mqtt.DefaultConfig()
	cfg.BrokerURL = "tcp://broker.factory:1883"
	cfg.ClientID = "edge-transformer-cpack"
	cfg.Username = "edge-transformer"
	cfg.Password = "changeme"

	sub := mqtt.NewSubscriber(cfg, handler, logger)

	// Not actually running here — this is documentation. In production wiring,
	// this becomes a goroutine spawned from main.go under an errgroup:
	//
	//   g.Go(func() error { return sub.Run(ctx) })
	_ = sub

	fmt.Println("wired")
	// Output: wired
}
