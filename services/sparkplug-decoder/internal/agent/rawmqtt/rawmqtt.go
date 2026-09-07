// Package rawmqtt is the agent's INTERNAL-broker subscriber (ADR-0042 §2.3):
// it consumes the plain-JSON raw-tag envelope the connectivity Node-RED
// publishes on the loopback topic (edge/raw/<tenant>/#). It is the JSON-body
// sibling of internal/mqtt (the cloud SparkPlug-B subscriber) — same
// bounded-queue + drop-with-metric + reconnect + health shape (ADR-0011
// rule 5 visible-drop pattern), only the transport payload differs (JSON, not
// protobuf; no alias/seq/session — the loopback is SparkPlug-ignorant).
package rawmqtt

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
)

// Config controls the subscriber's connection + subscription.
type Config struct {
	BrokerURL       string
	ClientID        string
	TopicFilter     string // e.g. "edge/raw/#"
	QoS             byte
	KeepAlive       time.Duration
	ConnectTimeout  time.Duration
	IngestQueueSize int
	// StaleThreshold: 0 → default (60s); negative → idle checks disabled
	// (a loopback with no live source is idle by design on staging).
	StaleThreshold time.Duration
}

// DefaultIngestQueueSize mirrors internal/mqtt's bounded-queue sizing.
const DefaultIngestQueueSize = 10_000

// StaleMessageThreshold — silence beyond this marks the subscriber degraded.
const StaleMessageThreshold = 60 * time.Second

// DefaultConfig returns sane defaults; caller sets BrokerURL + ClientID.
func DefaultConfig() Config {
	return Config{
		TopicFilter:     "edge/raw/#",
		QoS:             0,
		KeepAlive:       30 * time.Second,
		ConnectTimeout:  10 * time.Second,
		IngestQueueSize: DefaultIngestQueueSize,
	}
}

// Handler receives one raw-tag envelope body (JSON). Decode via
// internal/agent/rawtag. Return an error to bump the failure counter.
// Handlers must not block the event loop — the drainer already decouples
// them from paho's callback.
type Handler func(ctx context.Context, topic string, body []byte) error

// Subscriber owns the paho lifecycle + bounded ingestion queue. Mirrors
// internal/mqtt.Subscriber; satisfies health.ComponentSnapshotter.
type Subscriber struct {
	cfg     Config
	handler Handler
	logger  *slog.Logger

	metricsDropped func(reason string)

	queue chan queuedMsg

	received     atomic.Uint64
	handled      atomic.Uint64
	handleErrors atomic.Uint64
	reconnects   atomic.Uint64
	dropped      atomic.Uint64
	lastMessage  atomic.Int64

	mu        sync.RWMutex
	connected bool
	lastErr   string
	startedAt time.Time
}

type queuedMsg struct {
	topic string
	body  []byte
}

// New constructs a Subscriber. A nil handler is a no-op (drops the body).
func New(cfg Config, handler Handler, logger *slog.Logger) *Subscriber {
	if handler == nil {
		handler = func(context.Context, string, []byte) error { return nil }
	}
	if cfg.IngestQueueSize <= 0 {
		cfg.IngestQueueSize = DefaultIngestQueueSize
	}
	return &Subscriber{cfg: cfg, handler: handler, logger: logger, startedAt: time.Now()}
}

// SetDroppedMetric wires the ADR-0011 rule-5 drop counter (queue full).
func (s *Subscriber) SetDroppedMetric(fn func(reason string)) { s.metricsDropped = fn }

// DroppedCount returns queue-full drops. Diagnostic + scrape.
func (s *Subscriber) DroppedCount() uint64 { return s.dropped.Load() }

// Run connects, subscribes, and blocks until ctx is cancelled. Reconnect is
// delegated to paho's AutoReconnect; re-subscription happens in onConnect
// (clean-session drops subscriptions on reconnect).
func (s *Subscriber) Run(ctx context.Context) error {
	if s.cfg.BrokerURL == "" {
		return errors.New("rawmqtt: BrokerURL is required")
	}
	if s.cfg.ClientID == "" {
		return errors.New("rawmqtt: ClientID is required")
	}
	s.queue = make(chan queuedMsg, s.cfg.IngestQueueSize)
	drainerDone := make(chan struct{})
	go s.drainQueue(ctx, drainerDone)

	opts := paho.NewClientOptions().
		AddBroker(s.cfg.BrokerURL).
		SetClientID(s.cfg.ClientID).
		SetCleanSession(true).
		SetKeepAlive(s.cfg.KeepAlive).
		SetConnectTimeout(s.cfg.ConnectTimeout).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetMaxReconnectInterval(30 * time.Second).
		SetOnConnectHandler(s.onConnect).
		SetConnectionLostHandler(s.onConnectionLost)

	client := paho.NewClient(opts)
	tok := client.Connect()
	if !tok.WaitTimeout(s.cfg.ConnectTimeout) {
		return fmt.Errorf("rawmqtt: connect timeout to %s", s.cfg.BrokerURL)
	}
	if err := tok.Error(); err != nil {
		return fmt.Errorf("rawmqtt: connect: %w", err)
	}

	<-ctx.Done()
	client.Disconnect(250)
	close(s.queue)
	<-drainerDone
	return ctx.Err()
}

func (s *Subscriber) drainQueue(ctx context.Context, done chan<- struct{}) {
	defer close(done)
	for m := range s.queue {
		if ctx.Err() != nil {
			return
		}
		s.processMessage(ctx, m)
	}
}

func (s *Subscriber) processMessage(ctx context.Context, m queuedMsg) {
	defer func() {
		if r := recover(); r != nil {
			s.handleErrors.Add(1)
			s.logger.Error("rawmqtt: handler panicked", "topic", m.topic, "recover", fmt.Sprintf("%v", r))
		}
	}()
	hctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := s.handler(hctx, m.topic, m.body); err != nil {
		s.handleErrors.Add(1)
		s.logger.Warn("rawmqtt: handler failed", "topic", m.topic, "err", err)
		return
	}
	s.handled.Add(1)
}

func (s *Subscriber) onConnect(client paho.Client) {
	s.mu.Lock()
	s.connected = true
	s.lastErr = ""
	s.mu.Unlock()
	s.logger.Info("rawmqtt: connected", "broker", s.cfg.BrokerURL, "filter", s.cfg.TopicFilter)
	go func() {
		tok := client.Subscribe(s.cfg.TopicFilter, s.cfg.QoS, s.onMessage)
		if !tok.WaitTimeout(5 * time.Second) {
			s.logger.Error("rawmqtt: subscribe timeout", "filter", s.cfg.TopicFilter)
			return
		}
		if err := tok.Error(); err != nil {
			s.logger.Error("rawmqtt: subscribe failed", "filter", s.cfg.TopicFilter, "err", err)
		}
	}()
}

func (s *Subscriber) onConnectionLost(_ paho.Client, err error) {
	s.mu.Lock()
	s.connected = false
	s.lastErr = err.Error()
	s.mu.Unlock()
	s.reconnects.Add(1)
	s.logger.Warn("rawmqtt: connection lost — reconnecting", "err", err)
}

// onMessage copies topic+body onto the bounded queue and returns immediately
// (never block paho's event loop). Queue full ⇒ drop-with-metric.
func (s *Subscriber) onMessage(_ paho.Client, msg paho.Message) {
	s.received.Add(1)
	s.lastMessage.Store(time.Now().UnixNano())
	payload := make([]byte, len(msg.Payload()))
	copy(payload, msg.Payload())
	select {
	case s.queue <- queuedMsg{topic: msg.Topic(), body: payload}:
	default:
		s.dropped.Add(1)
		if s.metricsDropped != nil {
			s.metricsDropped("queue_full")
		}
		s.logger.Warn("rawmqtt: ingestion queue full — dropping message",
			"topic", msg.Topic(), "total_dropped", s.dropped.Load())
	}
}

// ── health.ComponentSnapshotter ──────────────────────────────────────────

// Component is the /healthz key.
func (s *Subscriber) Component() string { return "raw_tag_subscriber" }

// Snapshot is the /healthz JSON body for this component.
type Snapshot struct {
	Connected    bool   `json:"connected"`
	BrokerURL    string `json:"broker_url"`
	TopicFilter  string `json:"topic_filter"`
	Received     uint64 `json:"received_total"`
	Handled      uint64 `json:"handled_total"`
	HandleErrors uint64 `json:"handle_errors_total"`
	Dropped      uint64 `json:"dropped_total"`
	Reconnects   uint64 `json:"reconnects_total"`
	StartedAt    string `json:"started_at"`
	LastErr      string `json:"last_error,omitempty"`
}

// SnapshotDetail satisfies health.ComponentSnapshotter.
func (s *Subscriber) SnapshotDetail() any {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Snapshot{
		Connected:    s.connected,
		BrokerURL:    s.cfg.BrokerURL,
		TopicFilter:  s.cfg.TopicFilter,
		Received:     s.received.Load(),
		Handled:      s.handled.Load(),
		HandleErrors: s.handleErrors.Load(),
		Dropped:      s.dropped.Load(),
		Reconnects:   s.reconnects.Load(),
		StartedAt:    s.startedAt.Format(time.RFC3339),
		LastErr:      s.lastErr,
	}
}

func (s *Subscriber) staleThreshold() time.Duration {
	if s.cfg.StaleThreshold == 0 {
		return StaleMessageThreshold
	}
	return s.cfg.StaleThreshold
}

// Degraded returns a non-empty reason when unhealthy (ADR-0011 rule 4).
func (s *Subscriber) Degraded() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if !s.connected {
		if s.lastErr != "" {
			return "not connected: " + s.lastErr
		}
		return "not connected to internal broker"
	}
	threshold := s.staleThreshold()
	if threshold < 0 {
		return ""
	}
	if s.received.Load() == 0 {
		if time.Since(s.startedAt) > threshold {
			return fmt.Sprintf("no raw tags received in %v since start", time.Since(s.startedAt).Round(time.Second))
		}
		return ""
	}
	lastNs := s.lastMessage.Load()
	if lastNs == 0 {
		return ""
	}
	if age := time.Since(time.Unix(0, lastNs)); age > threshold {
		return fmt.Sprintf("last raw tag %v ago (threshold %v)", age.Round(time.Second), threshold)
	}
	return ""
}
