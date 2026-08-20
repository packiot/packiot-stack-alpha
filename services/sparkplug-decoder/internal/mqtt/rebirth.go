package mqtt

import (
	"fmt"
	"log/slog"
	"sync"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/sparkplug"
)

// RebirthRequester is the host-application (consumer) half of the SparkPlug B
// Rebirth mechanism (task #31 / ADR-0042). When the edge-transformer detects a
// sequence gap or NDATA-before-NBIRTH for an edge node, it publishes a
// "Node Control/Rebirth"=true NCMD to
//
//	spBv1.0/<GroupID>/NCMD/<EdgeNodeID>
//
// which tells the edge node to re-publish its full NBIRTH — re-seeding this
// consumer's alias table AND (for an agent-only line) the refactored Calc
// counter baseline that would otherwise stay frozen until the next agent
// reconnect.
//
// It owns its OWN paho client (the same precedent as command.MQTTDevicePublisher):
// the ingest Subscriber's connection stays a pure consumer, and this publisher
// only exists when the feature flag is on. NCMD is published at QoS 1 — a
// rebirth request warrants the broker's PUBACK, and the request is naturally
// idempotent (a duplicate just triggers a redundant NBIRTH).
//
// Requests are throttled per edge node (minInterval) so a burst of gapped
// NDATA can't storm a node with NCMDs.
type RebirthRequester struct {
	client      paho.Client
	publish     publishFn // transport seam — real paho publish, or a fake in tests
	minInterval time.Duration
	logger      *slog.Logger

	onRequest func(group, edgeNode, trigger string) // nil-safe Prometheus hook

	mu       sync.Mutex
	lastSent map[string]time.Time // key: group + "/" + edgeNode
}

// publishFn abstracts the QoS-1 NCMD publish so the debounce + topic-shape
// logic is unit-testable without a live broker.
type publishFn func(topic string, body []byte) error

// NewRebirthRequester connects to the broker and returns a ready requester.
// Caller must Close when done. brokerURL/username/password mirror the ingest
// subscriber's (same mosquitto).
func NewRebirthRequester(brokerURL, clientID, username, password string, minInterval time.Duration, logger *slog.Logger) (*RebirthRequester, error) {
	if brokerURL == "" {
		return nil, fmt.Errorf("mqtt: rebirth requester broker URL required")
	}
	if clientID == "" {
		clientID = "edge-transformer-rebirth"
	}
	opts := paho.NewClientOptions().
		AddBroker(brokerURL).
		SetClientID(clientID).
		SetUsername(username).
		SetPassword(password).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetKeepAlive(30 * time.Second).
		SetConnectTimeout(10 * time.Second)
	c := paho.NewClient(opts)
	tok := c.Connect()
	if !tok.WaitTimeout(10 * time.Second) {
		return nil, fmt.Errorf("mqtt: rebirth requester connect timeout to %s", brokerURL)
	}
	if err := tok.Error(); err != nil {
		return nil, fmt.Errorf("mqtt: rebirth requester connect: %w", err)
	}
	logger.Info("mqtt: rebirth requester connected",
		slog.String("broker", brokerURL), slog.String("client_id", clientID),
		slog.Duration("min_interval", minInterval))
	r := newRequester(minInterval, logger)
	r.client = c
	// Real transport: QoS 1 (a rebirth request warrants the broker's PUBACK),
	// bounded by publishWait.
	const publishWait = 5 * time.Second
	r.publish = func(topic string, body []byte) error {
		tok := c.Publish(topic, 1, false, body)
		if !tok.WaitTimeout(publishWait) {
			return fmt.Errorf("mqtt: Rebirth NCMD publish timeout to %s", topic)
		}
		return tok.Error()
	}
	return r, nil
}

// newRequester builds the transport-agnostic core (debounce + hooks). The
// caller wires .publish (real paho, or a fake in tests).
func newRequester(minInterval time.Duration, logger *slog.Logger) *RebirthRequester {
	if minInterval <= 0 {
		minInterval = 30 * time.Second
	}
	return &RebirthRequester{
		minInterval: minInterval,
		logger:      logger,
		lastSent:    make(map[string]time.Time),
	}
}

// SetMetric wires the Prometheus hook fired for each request actually sent
// (after the debounce). Nil-safe.
func (r *RebirthRequester) SetMetric(fn func(group, edgeNode, trigger string)) {
	r.onRequest = fn
}

// Request publishes a Rebirth NCMD for the given edge node, unless one was sent
// within minInterval (debounce, per group/edgeNode). trigger is a short reason
// label for logs + metrics ("seq_gap" | "no_birth"). NCMD is node-level, so
// any DeviceID on the key is ignored. Safe to call from multiple goroutines
// (the seq-gap callback runs under the StateStore lock; the ErrNoBirth branch
// runs on the drainer goroutine).
func (r *RebirthRequester) Request(group, edgeNode, trigger string) {
	key := group + "/" + edgeNode
	r.mu.Lock()
	if last, ok := r.lastSent[key]; ok && time.Since(last) < r.minInterval {
		r.mu.Unlock()
		return // debounced — a rebirth for this node is already in flight/recent
	}
	r.lastSent[key] = time.Now()
	r.mu.Unlock()

	topic := "spBv1.0/" + group + "/NCMD/" + edgeNode
	body, err := sparkplug.EncodeRebirthNCMD()
	if err != nil {
		r.logger.Error("mqtt: encode Rebirth NCMD", "topic", topic, "err", err)
		return
	}
	if err := r.publish(topic, body); err != nil {
		r.logger.Error("mqtt: Rebirth NCMD publish failed", "topic", topic, "err", err)
		return
	}
	if r.onRequest != nil {
		r.onRequest(group, edgeNode, trigger)
	}
	r.logger.Info("mqtt: requested rebirth via NCMD",
		slog.String("topic", topic), slog.String("trigger", trigger))
}

// Close disconnects the MQTT client.
func (r *RebirthRequester) Close() {
	if r.client != nil {
		r.client.Disconnect(250)
	}
}
