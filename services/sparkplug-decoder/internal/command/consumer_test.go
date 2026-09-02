package command

import (
	"context"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/config"
)

// GATED: when EDGE_COMMANDS_ENABLED=false the consumer is inert — Run must NOT
// dial the broker; it blocks until ctx is done and returns nil. We prove "no
// dial" by pointing amqpURL at an unroutable address: a real dial would error
// out fast; the inert path ignores it entirely.
func TestConsumer_Disabled_IsInert(t *testing.T) {
	cfg := &config.Config{
		CommandsEnabled:  false,
		CommandsExchange: "edge.commands",
		CommandsAllowed:  []string{VerbParamWrite},
	}
	// device intentionally nil — the inert path must never touch it.
	c := NewConsumer(cfg, "amqp://guest:guest@240.0.0.1:1/", []string{"cpack"}, nil, Metrics{}, nil)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()

	// Give Run a beat; if it tried to dial the unroutable host it would still
	// be blocked in dial, but it must instead be parked on <-ctx.Done().
	select {
	case err := <-done:
		t.Fatalf("Run returned before ctx cancel (err=%v) — not inert", err)
	case <-time.After(150 * time.Millisecond):
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("inert Run should return nil on ctx cancel, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("inert Run did not return promptly after ctx cancel")
	}
}

// The consumer's Degraded reason is empty when disabled (inert-by-design must
// not read as an outage, like the disabled MQTT source).
func TestConsumer_Disabled_NotDegraded(t *testing.T) {
	cfg := &config.Config{CommandsEnabled: false, CommandsExchange: "edge.commands"}
	c := NewConsumer(cfg, "amqp://x", []string{"cpack"}, nil, Metrics{}, nil)
	if d := c.Degraded(); d != "" {
		t.Fatalf("disabled consumer should not be degraded, got %q", d)
	}
}
