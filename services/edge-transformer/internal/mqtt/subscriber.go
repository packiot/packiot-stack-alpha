// Package mqtt is the Sparkplug B MQTT subscriber — Phase 2 of ADR-0010.
//
// SPIKE STATUS (2026-06-30):
// This is a scaffold that mirrors the shape of internal/amqp/consumer.go per
// ADR-0009 Errata Correction 2 (reuse rule). The single connection + multiple
// subscribed topics + reconnect-with-backoff pattern is lifted from the AMQP
// consumer. Only the transport (paho.mqtt.golang) and the topic-filter shape
// (Sparkplug's spBv1.0/+/+/+/+) differ.
//
// Not yet wired into main.go. Not yet handling QoS/TLS/persistent-session
// nuance. The Subscriber accepts a Handler callback that receives the raw
// Sparkplug binary body + the parsed topic components. Downstream calls
// sparkplug.Decode + normalization.
//
// Sparkplug topic namespace (from spec):
//
//	spBv1.0/<GroupID>/<MessageType>/<EdgeNodeID>[/<DeviceID>]
//
// MessageType is one of: NBIRTH, NDEATH, DBIRTH, DDEATH, NDATA, DDATA,
// NCMD, DCMD. This subscriber wildcards all four levels — decode
// downstream decides which to process.
package mqtt

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// TopicFilterAll is the wildcard subscription that matches every Sparkplug B
// message. Individual publishers within the tenant are distinguished by
// GroupID / EdgeNodeID / DeviceID in the topic components.
const TopicFilterAll = "spBv1.0/+/+/+/+"

// Config controls the Subscriber's connection + subscription behavior.
// Populated by the caller from client.yaml (per-tenant broker credentials)
// + main.go's global settings.
type Config struct {
	// BrokerURL — MQTT URL like "tcp://broker.factory:1883" or
	// "ssl://broker.factory:8883". Required.
	BrokerURL string

	// ClientID — must be unique per subscriber instance. Sparkplug spec
	// requires clean-session behavior; if the broker enforces persistent
	// sessions we clash. Default: "edge-transformer-<tenant>".
	ClientID string

	// Username / Password — plain-text creds. Read from AWS Secrets Manager
	// in production wiring; hardcoded here for the scaffold.
	Username string
	Password string

	// TopicFilter — MQTT topic pattern to subscribe to. Default:
	// TopicFilterAll ("spBv1.0/+/+/+/+"). Override for narrower testing.
	TopicFilter string

	// QoS — MQTT QoS level. Sparkplug B data messages ARE published at
	// QoS 0 per spec (broker is expected to keep them via retained
	// messages + Last Will). We match that convention.
	QoS byte

	// KeepAlive — heartbeat interval to the broker. Sparkplug spec
	// recommends 30s.
	KeepAlive time.Duration

	// ConnectTimeout — how long to wait for the initial CONNECT to
	// complete. Reconnects use exponential backoff internally.
	ConnectTimeout time.Duration
}

// DefaultConfig returns a Config with Sparkplug-spec-friendly defaults.
// Caller must set BrokerURL + ClientID + Username/Password.
func DefaultConfig() Config {
	return Config{
		TopicFilter:    TopicFilterAll,
		QoS:            0,
		KeepAlive:      30 * time.Second,
		ConnectTimeout: 10 * time.Second,
	}
}

// Handler receives every Sparkplug B message. topic is the parsed 4- or
// 5-segment Sparkplug topic; body is the raw protobuf-encoded payload
// (decode via internal/sparkplug).
//
// Return an error to log + increment the failure counter. Return nil for
// successful handling. Handlers should NOT block the MQTT event loop —
// hand work off to a channel or worker pool for anything expensive.
type Handler func(ctx context.Context, topic Topic, body []byte) error

// Topic is the parsed Sparkplug B topic. All fields are set on the
// message-received path. DeviceID is empty for node-level messages.
type Topic struct {
	Namespace   string // always "spBv1.0"
	GroupID     string // customer / site identifier
	MessageType string // NBIRTH, DBIRTH, NDATA, DDATA, NDEATH, DDEATH, NCMD, DCMD
	EdgeNodeID  string // physical edge device
	DeviceID    string // sub-device under the edge node; empty for node-level
}

// ParseTopic splits an MQTT topic into Sparkplug's canonical components.
// Returns an error for topics that don't match the spBv1.0/<...>/<...>
// namespace pattern.
func ParseTopic(s string) (Topic, error) {
	parts := strings.Split(s, "/")
	if len(parts) < 4 || len(parts) > 5 || parts[0] != "spBv1.0" {
		return Topic{}, fmt.Errorf("not a sparkplug topic: %q", s)
	}
	t := Topic{
		Namespace:   parts[0],
		GroupID:     parts[1],
		MessageType: parts[2],
		EdgeNodeID:  parts[3],
	}
	if len(parts) == 5 {
		t.DeviceID = parts[4]
	}
	return t, nil
}

// Subscriber owns the paho.mqtt.golang Client lifecycle + reconnect state.
// Mirrors internal/amqp/consumer.go's shape: single connection, N handlers,
// reconnect-with-backoff, atomic counters, /health integration hooks.
type Subscriber struct {
	cfg     Config
	handler Handler
	logger  *slog.Logger

	// Optional Prometheus hooks — nil-safe. Set via SetMetrics.
	metricsReceived func(msgType, groupID string)
	metricsHandled  func(msgType, groupID, result string)
	metricsConnect  func(outcome string) // "success" | "failure"

	// Counters — read by /health for the JSON body.
	received     atomic.Uint64
	handled      atomic.Uint64
	handleErrors atomic.Uint64
	reconnects   atomic.Uint64
	lastMessage  atomic.Int64 // unix nano

	mu        sync.RWMutex
	client    paho.Client
	connected bool
	lastErr   string
	startedAt time.Time
}

// NewSubscriber constructs a Subscriber. Call Run to start the connection
// lifecycle. Handler is invoked for every message received on the subscribed
// topic; nil handler is treated as a no-op (acks message, drops body).
func NewSubscriber(cfg Config, handler Handler, logger *slog.Logger) *Subscriber {
	if handler == nil {
		handler = func(context.Context, Topic, []byte) error { return nil }
	}
	return &Subscriber{
		cfg:       cfg,
		handler:   handler,
		logger:    logger,
		startedAt: time.Now(),
	}
}

// SetMetrics wires Prometheus callbacks. Safe to call before Run. Nil-safe.
func (s *Subscriber) SetMetrics(
	received func(msgType, groupID string),
	handled func(msgType, groupID, result string),
	connect func(outcome string),
) {
	s.metricsReceived = received
	s.metricsHandled = handled
	s.metricsConnect = connect
}

// Snapshot exposes the same fields internal/amqp/consumer.go does — the
// /health endpoint marshals both together.
type Snapshot struct {
	Connected    bool   `json:"connected"`
	BrokerURL    string `json:"broker_url"`
	ClientID     string `json:"client_id"`
	Received     uint64 `json:"received_total"`
	Handled      uint64 `json:"handled_total"`
	HandleErrors uint64 `json:"handle_errors_total"`
	Reconnects   uint64 `json:"reconnects_total"`
	LastMessage  int64  `json:"last_message_unix_nano"`
	StartedAt    string `json:"started_at"`
	LastErr      string `json:"last_error,omitempty"`
}

// SnapshotJSON is the /health-shaped view of the Subscriber's state.
func (s *Subscriber) SnapshotJSON() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Snapshot{
		Connected:    s.connected,
		BrokerURL:    s.cfg.BrokerURL,
		ClientID:     s.cfg.ClientID,
		Received:     s.received.Load(),
		Handled:      s.handled.Load(),
		HandleErrors: s.handleErrors.Load(),
		Reconnects:   s.reconnects.Load(),
		LastMessage:  s.lastMessage.Load(),
		StartedAt:    s.startedAt.Format(time.RFC3339),
		LastErr:      s.lastErr,
	}
}

// Run establishes the MQTT connection + subscribes + blocks until ctx
// is cancelled. Reconnect logic is delegated to paho's built-in
// AutoReconnect + our OnConnectionLost handler.
func (s *Subscriber) Run(ctx context.Context) error {
	if s.cfg.BrokerURL == "" {
		return errors.New("mqtt: BrokerURL is required")
	}
	if s.cfg.ClientID == "" {
		return errors.New("mqtt: ClientID is required")
	}

	opts := paho.NewClientOptions().
		AddBroker(s.cfg.BrokerURL).
		SetClientID(s.cfg.ClientID).
		SetUsername(s.cfg.Username).
		SetPassword(s.cfg.Password).
		SetCleanSession(true). // Sparkplug B requires clean session
		SetKeepAlive(s.cfg.KeepAlive).
		SetConnectTimeout(s.cfg.ConnectTimeout).
		SetAutoReconnect(true).
		SetMaxReconnectInterval(30 * time.Second).
		SetOnConnectHandler(s.onConnect).
		SetConnectionLostHandler(s.onConnectionLost).
		SetDefaultPublishHandler(s.onMessage)

	client := paho.NewClient(opts)
	s.mu.Lock()
	s.client = client
	s.mu.Unlock()

	tok := client.Connect()
	if !tok.WaitTimeout(s.cfg.ConnectTimeout) {
		if s.metricsConnect != nil {
			s.metricsConnect("failure")
		}
		return fmt.Errorf("mqtt: connect timeout to %s", s.cfg.BrokerURL)
	}
	if err := tok.Error(); err != nil {
		if s.metricsConnect != nil {
			s.metricsConnect("failure")
		}
		return fmt.Errorf("mqtt: connect: %w", err)
	}

	<-ctx.Done()
	client.Disconnect(250)
	return ctx.Err()
}

// onConnect fires on every successful connect (including reconnects).
// This is where we (re)subscribe — subscriptions do NOT survive reconnect
// with clean-session=true, so we must re-issue them here.
func (s *Subscriber) onConnect(client paho.Client) {
	s.mu.Lock()
	s.connected = true
	s.lastErr = ""
	s.mu.Unlock()

	if s.metricsConnect != nil {
		s.metricsConnect("success")
	}
	s.logger.Info("mqtt: connected",
		"broker", s.cfg.BrokerURL,
		"client_id", s.cfg.ClientID,
		"topic_filter", s.cfg.TopicFilter)

	// Re-subscribe on every (re)connect. paho's Subscribe returns a Token
	// we should not Wait() indefinitely inside the callback — spawn a
	// goroutine or use a short WaitTimeout.
	go func() {
		tok := client.Subscribe(s.cfg.TopicFilter, s.cfg.QoS, s.onMessage)
		if !tok.WaitTimeout(5 * time.Second) {
			s.logger.Error("mqtt: subscribe timeout",
				"filter", s.cfg.TopicFilter)
			return
		}
		if err := tok.Error(); err != nil {
			s.logger.Error("mqtt: subscribe failed",
				"filter", s.cfg.TopicFilter, "err", err)
		}
	}()
}

// onConnectionLost fires when the broker connection drops. paho's
// AutoReconnect will re-establish; we just track state + increment
// counters for /health visibility.
func (s *Subscriber) onConnectionLost(_ paho.Client, err error) {
	s.mu.Lock()
	s.connected = false
	s.lastErr = err.Error()
	s.mu.Unlock()
	s.reconnects.Add(1)
	s.logger.Warn("mqtt: connection lost — reconnecting", "err", err)
}

// onMessage is the per-message callback. Parses the topic + dispatches to
// the Handler. Handler errors are logged + counted; we do NOT propagate
// them upstream (there's no "nack" concept in MQTT QoS 0 anyway).
func (s *Subscriber) onMessage(_ paho.Client, msg paho.Message) {
	s.received.Add(1)
	s.lastMessage.Store(time.Now().UnixNano())

	topic, err := ParseTopic(msg.Topic())
	if err != nil {
		s.handleErrors.Add(1)
		if s.metricsHandled != nil {
			s.metricsHandled("unknown", "unknown", "parse_error")
		}
		s.logger.Warn("mqtt: unparseable topic",
			"topic", msg.Topic(), "err", err)
		return
	}
	if s.metricsReceived != nil {
		s.metricsReceived(topic.MessageType, topic.GroupID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.handler(ctx, topic, msg.Payload()); err != nil {
		s.handleErrors.Add(1)
		if s.metricsHandled != nil {
			s.metricsHandled(topic.MessageType, topic.GroupID, "error")
		}
		s.logger.Error("mqtt: handler failed",
			"topic", msg.Topic(), "err", err)
		return
	}
	s.handled.Add(1)
	if s.metricsHandled != nil {
		s.metricsHandled(topic.MessageType, topic.GroupID, "ok")
	}
}
