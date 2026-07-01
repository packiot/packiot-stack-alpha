// Unit tests for the pure functions of the MQTT subscriber. Broker-required
// integration tests live behind the `mqtt_integration` build tag (added in a
// follow-up PR when a local mosquitto or the staging broker is wired in).

package mqtt

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"testing"
	"time"
)

func TestParseTopic(t *testing.T) {
	tests := []struct {
		name  string
		in    string
		want  Topic
		isErr bool
	}{
		{
			name: "node-level NDATA",
			in:   "spBv1.0/CPACK/NDATA/edge-01",
			want: Topic{
				Namespace:   "spBv1.0",
				GroupID:     "CPACK",
				MessageType: "NDATA",
				EdgeNodeID:  "edge-01",
			},
		},
		{
			name: "device-level DDATA",
			in:   "spBv1.0/CPACK/DDATA/edge-01/device-A",
			want: Topic{
				Namespace:   "spBv1.0",
				GroupID:     "CPACK",
				MessageType: "DDATA",
				EdgeNodeID:  "edge-01",
				DeviceID:    "device-A",
			},
		},
		{
			name: "NBIRTH",
			in:   "spBv1.0/factory-x/NBIRTH/plc-42",
			want: Topic{
				Namespace:   "spBv1.0",
				GroupID:     "factory-x",
				MessageType: "NBIRTH",
				EdgeNodeID:  "plc-42",
			},
		},
		{
			name:  "wrong namespace",
			in:    "spCv1.0/CPACK/NDATA/edge-01",
			isErr: true,
		},
		{
			name:  "too few parts",
			in:    "spBv1.0/CPACK/NDATA",
			isErr: true,
		},
		{
			name:  "too many parts",
			in:    "spBv1.0/CPACK/DDATA/edge-01/device-A/extra",
			isErr: true,
		},
		{
			name:  "empty",
			in:    "",
			isErr: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseTopic(tc.in)
			if tc.isErr {
				if err == nil {
					t.Errorf("want error, got Topic %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestDefaultConfig(t *testing.T) {
	c := DefaultConfig()
	if c.TopicFilter != TopicFilterAll {
		t.Errorf("TopicFilter: got %q, want %q", c.TopicFilter, TopicFilterAll)
	}
	// Regression guard: MUST be multi-level `#`, not the 5-segment `+/+/+/+`
	// pattern (which silently drops all node-level NBIRTH/NDATA/NDEATH).
	// See TopicFilterAll doc for the on-staging discovery story.
	if TopicFilterAll != "spBv1.0/#" {
		t.Errorf("TopicFilterAll regression: got %q, want %q — MUST use "+
			"multi-level wildcard to match both 4-segment (node) and "+
			"5-segment (device) Sparkplug topics",
			TopicFilterAll, "spBv1.0/#")
	}
	if c.QoS != 0 {
		t.Errorf("QoS: got %d, want 0 (Sparkplug spec)", c.QoS)
	}
	if c.KeepAlive != 30*time.Second {
		t.Errorf("KeepAlive: got %v, want 30s (Sparkplug spec)", c.KeepAlive)
	}
	if c.ConnectTimeout <= 0 {
		t.Errorf("ConnectTimeout: got %v, want positive", c.ConnectTimeout)
	}
}

// TestSubscriberSnapshotShape verifies the JSON keys match what the /health
// endpoint expects. If this drifts, health page rendering breaks silently.
func TestSubscriberSnapshotShape(t *testing.T) {
	s := NewSubscriber(Config{
		BrokerURL: "tcp://example:1883",
		ClientID:  "edge-transformer-cpack",
	}, nil, slog.New(slog.NewTextHandler(os.Stderr, nil)))

	snap := s.SnapshotJSON()

	if snap.Connected {
		t.Errorf("Connected: pre-Run should be false")
	}
	if snap.BrokerURL != "tcp://example:1883" {
		t.Errorf("BrokerURL: got %q", snap.BrokerURL)
	}
	if snap.ClientID != "edge-transformer-cpack" {
		t.Errorf("ClientID: got %q", snap.ClientID)
	}
	if snap.Received != 0 || snap.Handled != 0 {
		t.Errorf("counters should start at 0: %+v", snap)
	}
	if snap.StartedAt == "" {
		t.Errorf("StartedAt should be set at construction")
	}
}

// TestSubscriberHandlerNilSafe verifies the "nil handler is a no-op" contract
// documented in NewSubscriber.
func TestSubscriberHandlerNilSafe(t *testing.T) {
	s := NewSubscriber(Config{
		BrokerURL: "tcp://example:1883",
		ClientID:  "test",
	}, nil, slog.New(slog.NewTextHandler(os.Stderr, nil)))

	// Directly invoke the internal handler (avoiding paho for this unit-scope test).
	err := s.handler(context.Background(), Topic{
		Namespace:   "spBv1.0",
		GroupID:     "CPACK",
		MessageType: "NDATA",
		EdgeNodeID:  "edge-01",
	}, []byte{0x08, 0x2a})
	if err != nil {
		t.Errorf("nil handler should be no-op, got err: %v", err)
	}
}

// TestSubscriberRunRejectsBadConfig verifies Run's precondition checks.
func TestSubscriberRunRejectsBadConfig(t *testing.T) {
	tests := []struct {
		name string
		cfg  Config
		want string
	}{
		{
			name: "no broker",
			cfg:  Config{ClientID: "x"},
			want: "BrokerURL is required",
		},
		{
			name: "no client ID",
			cfg:  Config{BrokerURL: "tcp://x:1883"},
			want: "ClientID is required",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := NewSubscriber(tc.cfg, nil, slog.New(slog.NewTextHandler(os.Stderr, nil)))
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			err := s.Run(ctx)
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.want)
			}
			if !contains(err.Error(), tc.want) {
				t.Errorf("want error containing %q, got %v", tc.want, err)
			}
		})
	}
}

// contains is a tiny alternative to strings.Contains — avoids importing
// strings just for tests.
func contains(hay, needle string) bool {
	for i := 0; i+len(needle) <= len(hay); i++ {
		if hay[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// unusedErrors keeps `errors` import live for the future integration test.
var _ = errors.New
