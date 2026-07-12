// Package shadowpub publishes ResolvedPayload → the edge.plc-normalized
// exchange, mirroring the envelope shape that Phase 2.5b's Node-RED publisher
// tab produces. This enables ADR-0008-style comparator validation: both
// pipelines write to the SAME exchange with the SAME shape, and the
// comparator diffs them on (metric_name, value, timestamp) tuples.
//
// The envelope is defined by docs/clients/_normalized-payload-schema.yaml v1.0.
// The only fields that differ from the Node-RED path:
//
//	envelope.source.type      "go"        (Node-RED path: "nodered")
//	envelope.source.package   "sparkplug" (Node-RED path: absent)
//	envelope.source.tab       absent      (Node-RED path: "Publish to edge...")
//	payload.equipment_id      0 (TBD)     (Node-RED path: real ID from client.yaml map)
//
// The equipment_id resolution (name → int) belongs in the ADR-0009 Phase 3
// normalizer that Phase 2.5b hard-coded as an inline const. For shadow-mode
// the comparator can ignore that field or match on metric name instead.
//
// STATUS (ADR-0010 Phase 2 + ADR-0011 P0-1):
// This publisher runs in AMQP confirm-select mode (ADR-0011 rule 1). Every
// PublishWithContext is followed by a wait for the broker's basic.ack. If
// the broker nacks or fails to confirm within ConfirmTimeout, Publish
// returns a typed error (ErrPublishNacked / ErrConfirmTimeout) so callers
// can distinguish "broker rejected" from "broker slow" — both are visible
// via counters + logs. Silent loss is impossible: either RabbitMQ took the
// message, or the caller learns of the failure.
//
// What's still deferred (later ADR-0011 phases):
//   - Local disk outbox for the retry-and-persist case (P2)
//   - In-process retry loop with bounded exponential backoff on nack (P1)
//   - Per-tenant credentials via AWS Secrets Manager (Phase 2 follow-up)
//   - Prometheus metrics wired directly (currently counter-getters only)
package shadowpub

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/amqptrace"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/sparkplug"
)

// SchemaVersion is the version tag stamped in the SourceType field so
// oeecloud-worker can distinguish the shadow-Go path from Node-RED.
const SchemaVersion = "1.0"

// Envelope is the JSON structure published to the `oee` exchange with
// routing_key = "sparkplug.data.<tenant>". Matches the shape that
// oeecloud-worker's sparkplug.Payload parser expects, so both Node-RED
// AND the Go port produce envelopes that the same consumer can handle.
//
// The `source_type: "go"` field is the load-bearing distinction that
// makes oeecloud-worker route writes into shadow_go_port.* instead of
// public.* (ADR-0010 Phase 3 shadow-mode DB comparison).
type Envelope struct {
	Timestamp  int64    `json:"timestamp"`
	Gateway    string   `json:"gateway"`
	SourceType string   `json:"source_type"`
	Metrics    []Metric `json:"metrics"`
}

// Metric mirrors oeecloud-worker's sparkplug.Metric shape — same field
// names, same JSON tags. counter/curspeed/id are pointer types so the
// omitempty behavior matches when the fields are absent.
type Metric struct {
	Name      string   `json:"name"`
	Timestamp int64    `json:"timestamp"`
	Value     any      `json:"value"`
	Counter   *float64 `json:"counter,omitempty"`
	CurSpeed  *float64 `json:"curspeed,omitempty"`
	ID        *int     `json:"id,omitempty"`
}

// DefaultConfirmTimeout is how long we wait for RabbitMQ to ack a publish
// before declaring it lost. ADR-0011 open-question default. Longer than a
// typical WAN round-trip; shorter than a stuck-broker interval.
const DefaultConfirmTimeout = 5 * time.Second

// Errors surfaced by Publish. Callers can distinguish nack (RabbitMQ said no)
// from timeout (RabbitMQ said nothing) — matters for the operator triage.
var (
	// ErrPublishNacked is returned when RabbitMQ actively refused the message
	// via basic.nack. Retries may not help — inspect the broker + resource
	// alarms (memory/disk) before re-publishing.
	ErrPublishNacked = errors.New("shadowpub: RabbitMQ nacked publish")

	// ErrConfirmTimeout is returned when RabbitMQ didn't confirm within
	// the configured deadline. Common causes: broker slow-write under load,
	// network wobble, broker restart in progress.
	ErrConfirmTimeout = errors.New("shadowpub: RabbitMQ confirm timeout")
)

// Publisher owns an AMQP Channel (single-writer) for shadow publishes.
// Not goroutine-safe — callers should hold the mutex or serialize calls.
// (In our wiring only one goroutine — the MQTT Handler — calls Publish.)
//
// ADR-0011 rule 1: this publisher runs in confirm-select mode. Every
// PublishWithContext is followed by a wait for the broker's basic.ack. If
// no ack arrives within ConfirmTimeout, or if the broker nacks, we surface
// a typed error + increment metrics. Silent loss is impossible: either
// RabbitMQ took the message, or the caller learns of the failure.
type Publisher struct {
	// amqpURL is saved so reconnect() can re-dial after a broker outage.
	// The chaos test in the deploy pipeline (RMQ stop → inject → RMQ
	// start) exposed the missing reconnect as a silent-degrade — depth
	// grew during outage but never drained after recovery.
	amqpURL string

	// mu serializes access to conn/ch/confirms during reconnect. Publish
	// paths take rlock; reconnect takes wlock.
	mu       sync.RWMutex
	conn     *amqp.Connection
	ch       *amqp.Channel
	exchange string
	instance string
	logger   *slog.Logger

	// reconnects atomic counter — Prom + /healthz observability.
	reconnects atomic.Uint64

	// ConfirmTimeout is the deadline for waiting on a broker ack per publish.
	// Falls back to DefaultConfirmTimeout when zero.
	ConfirmTimeout time.Duration

	// confirms is the ordered stream of Confirmation events from the broker.
	// The library guarantees delivery-tag order matches publish order on the
	// same channel, so we drain sequentially (one per Publish body iteration).
	confirms chan amqp.Confirmation

	// atomic counters — read by /health JSON body.
	published       atomic.Uint64
	confirmed       atomic.Uint64
	nacked          atomic.Uint64
	confirmTimeouts atomic.Uint64
	failed          atomic.Uint64
}

// New opens an AMQP connection + channel, puts the channel in confirm-select
// mode, and returns a Publisher ready for Publish calls. Caller must Close
// when done.
//
// amqpURL is the same shape amqp.Consumer uses (built from Secrets).
// exchange is typically "edge.plc-normalized" (matches Phase 2.5b topology).
func New(amqpURL, exchange string, logger *slog.Logger) (*Publisher, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("shadowpub: dial: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("shadowpub: channel: %w", err)
	}
	// ADR-0011 rule 1 — enable AMQP confirm-select mode. Without this,
	// PublishWithContext returns nil the moment the message leaves our TCP
	// socket, whether or not RabbitMQ received it. Silent loss.
	if err := ch.Confirm(false); err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return nil, fmt.Errorf("shadowpub: enable confirm mode: %w", err)
	}
	// Buffer of 64 is well above our sequential publish rate but small
	// enough to serve as a bounded queue if the broker's ack stream stalls.
	confirms := ch.NotifyPublish(make(chan amqp.Confirmation, 64))
	instance, _ := os.Hostname()
	if instance == "" {
		instance = "edge-transformer"
	}
	return &Publisher{
		amqpURL:        amqpURL,
		conn:           conn,
		ch:             ch,
		exchange:       exchange,
		instance:       instance,
		logger:         logger,
		ConfirmTimeout: DefaultConfirmTimeout,
		confirms:       confirms,
	}, nil
}

// StartConnectionMonitor spawns a background goroutine that watches the
// AMQP connection's NotifyClose channel and proactively reconnects when
// the broker drops the connection. Should be called ONCE after New().
// Returns immediately; the goroutine dies when ctx is cancelled.
//
// This is the load-bearing fix for the ADR-0011 P3 chaos test: without
// this, an RMQ 'docker stop' silently kills the channel, publishes
// error out via ErrConfirmTimeout (which isn't a connection error), and
// the outbox drain never recovers. With this, NotifyClose fires the
// moment TCP closes, triggering an immediate reconnect attempt loop.
func (p *Publisher) StartConnectionMonitor(ctx context.Context, logger *slog.Logger) {
	go p.connectionMonitor(ctx, logger)
}

func (p *Publisher) connectionMonitor(ctx context.Context, logger *slog.Logger) {
	backoff := 500 * time.Millisecond
	const backoffCap = 15 * time.Second

	for {
		p.mu.RLock()
		conn := p.conn
		p.mu.RUnlock()
		if conn == nil {
			// No live conn — try to reconnect after backoff.
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			if err := p.reconnect(logger); err != nil {
				if logger != nil {
					logger.Warn("shadowpub: reconnect attempt failed — will retry",
						slog.String("err", err.Error()),
						slog.Duration("next_backoff", backoff))
				}
				if backoff *= 2; backoff > backoffCap {
					backoff = backoffCap
				}
				continue
			}
			backoff = 500 * time.Millisecond // reset on success
			continue
		}

		notifyClose := conn.NotifyClose(make(chan *amqp.Error, 1))
		select {
		case <-ctx.Done():
			return
		case err := <-notifyClose:
			if err != nil && logger != nil {
				logger.Warn("shadowpub: connection closed — will reconnect",
					slog.String("err", err.Error()))
			}
			// Nil out conn so next iteration triggers a reconnect.
			p.mu.Lock()
			p.conn = nil
			p.ch = nil
			p.mu.Unlock()
		}
	}
}

// reconnect closes the current AMQP connection + channel and re-opens
// them. Under the wlock — concurrent PublishBytes callers block until
// reconnect completes.
//
// Best-effort: if reconnect fails, the Publisher is left in a bad state
// (ch is nil) and subsequent publishes will fail cleanly. The next
// publish that hits the reconnect path will try again.
func (p *Publisher) reconnect(logger *slog.Logger) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Best-effort close of the old conn + channel.
	if p.ch != nil {
		_ = p.ch.Close()
		p.ch = nil
	}
	if p.conn != nil {
		_ = p.conn.Close()
		p.conn = nil
	}

	conn, err := amqp.Dial(p.amqpURL)
	if err != nil {
		return fmt.Errorf("shadowpub reconnect: dial: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return fmt.Errorf("shadowpub reconnect: channel: %w", err)
	}
	if err := ch.Confirm(false); err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return fmt.Errorf("shadowpub reconnect: enable confirm mode: %w", err)
	}
	p.conn = conn
	p.ch = ch
	p.confirms = ch.NotifyPublish(make(chan amqp.Confirmation, 64))
	p.reconnects.Add(1)
	if logger != nil {
		logger.Info("shadowpub: reconnected to RMQ")
	}
	return nil
}

// isConnectionError decides whether an AMQP error is worth triggering
// a reconnect for. The amqp091-go library returns a variety of shapes;
// the most common ones after a broker restart are "channel/connection
// closed" errors.
func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "channel/connection is not open") ||
		strings.Contains(s, "channel closed") ||
		strings.Contains(s, "connection closed") ||
		strings.Contains(s, "EOF") ||
		strings.Contains(s, "broken pipe") ||
		strings.Contains(s, "use of closed network connection")
}

// Close releases the AMQP channel + connection.
func (p *Publisher) Close() error {
	if p.ch != nil {
		_ = p.ch.Close()
	}
	if p.conn != nil {
		return p.conn.Close()
	}
	return nil
}

// Counter getters — read by /health snapshots.
// PublishedCount is the count of publishes sent to the broker (may or may
// not be confirmed). ConfirmedCount is the subset that RabbitMQ acked.
// The gap between them is the "in flight" set at any given moment.
func (p *Publisher) PublishedCount() uint64      { return p.published.Load() }
func (p *Publisher) ConfirmedCount() uint64      { return p.confirmed.Load() }
func (p *Publisher) NackedCount() uint64         { return p.nacked.Load() }
func (p *Publisher) ConfirmTimeoutCount() uint64 { return p.confirmTimeouts.Load() }
func (p *Publisher) FailedCount() uint64         { return p.failed.Load() }

// InFlightBacklog is publishing sent minus confirmed. Under steady state
// this hovers near zero; a growing gap means RabbitMQ is slow-writing or
// the confirm goroutine is stuck.
func (p *Publisher) InFlightBacklog() uint64 {
	pub := p.published.Load()
	conf := p.confirmed.Load()
	if pub < conf {
		// Should never happen but guard against reader race on the two
		// atomics — treat as caught-up.
		return 0
	}
	return pub - conf
}

// BacklogDegradedThreshold — publish count minus confirm count above this
// number is considered degraded. Set for typical Sparkplug rates (~10 msg/s
// per PLC × dozens of PLCs = hundreds/s peak). More than 100 outstanding
// = confirms channel wedged or RMQ struggling.
const BacklogDegradedThreshold = 100

// ── ADR-0011 P0-4: ComponentSnapshotter for /healthz ─────────────────────────

// Component satisfies health.ComponentSnapshotter.
func (p *Publisher) Component() string { return "shadow_publisher" }

// SnapshotDetail returns the per-component JSON body.
func (p *Publisher) SnapshotDetail() any {
	return map[string]any{
		"exchange":               p.exchange,
		"instance":               p.instance,
		"published_total":        p.published.Load(),
		"confirmed_total":        p.confirmed.Load(),
		"nacked_total":           p.nacked.Load(),
		"confirm_timeouts_total": p.confirmTimeouts.Load(),
		"failed_total":           p.failed.Load(),
		"in_flight_backlog":      p.InFlightBacklog(),
	}
}

// Degraded returns non-empty when publisher-side reliability is at risk.
// ADR-0011 rule 4: silent-degrade is a bug.
//
// Degraded conditions:
//   - In-flight backlog > BacklogDegradedThreshold (broker slow / stuck)
//   - Non-zero nacks (broker resource alarm) → ops should investigate
//   - Non-zero confirm timeouts (broker slow-write, may recover) → warn
func (p *Publisher) Degraded() string {
	if backlog := p.InFlightBacklog(); backlog > BacklogDegradedThreshold {
		return fmt.Sprintf("in-flight backlog %d > threshold %d (broker may be slow)",
			backlog, BacklogDegradedThreshold)
	}
	if nacked := p.nacked.Load(); nacked > 0 {
		return fmt.Sprintf("RabbitMQ has NACKED %d publish(es) — check resource alarms",
			nacked)
	}
	// Confirm timeouts are advisory but not degraded on their own — brief
	// network wobbles cause a few. The nack path is the actionable one.
	return ""
}

// Publish fans out a ResolvedPayload into per-metric envelopes and publishes
// each to edge.plc-normalized.<tenant>, awaiting broker confirms per publish.
//
// Errors on the first publish failure — remaining metrics in the batch are
// NOT retried by this call (upstream caller decides retry semantics; ADR-0011
// Phase 3 will add a local outbox for the retry-and-persist case).
//
// Semantics (ADR-0011 rule 1):
//   - PublishWithContext succeeds → count as published + wait for confirm
//   - Confirm arrives with Ack=true → count as confirmed + advance
//   - Confirm arrives with Ack=false → count as nacked + return ErrPublishNacked
//   - No confirm within ConfirmTimeout → count as timeout + return ErrConfirmTimeout
//   - ctx cancelled during wait → return ctx.Err()
//
// Tenant is derived from the publisher key's GroupID (lowercased). This
// matches the Phase 2.5b publisher's env-var-driven CLIENT_TENANT_ID default
// of "cpack" when GroupID is "CPACK".
// Publish publishes ONE oeecloud-compatible envelope per ResolvedPayload.
// The envelope carries all metrics under `metrics[]` (matching Node-RED's
// output shape), routed to `sparkplug.data.<tenant>` on the `oee`
// exchange so oeecloud-worker's existing per-tenant queue picks it up.
// SourceType="go" tells oeecloud-worker to dispatch writes into
// shadow_go_port.* instead of public.* (ADR-0010 Phase 3 DB comparison).
func (p *Publisher) Publish(ctx context.Context, resolved *sparkplug.ResolvedPayload) error {
	tenant := strings.ToLower(resolved.PublisherKey.GroupID)
	// oeecloud-worker's per-tenant queue binding is `sparkplug.data.<tenant>`
	// on the `oee` exchange. The p.exchange field is passed at New() and
	// must equal "oee" to match.
	routingKey := fmt.Sprintf("sparkplug.data.%s", tenant)

	env := BuildEnvelope(EnvelopeInput{
		Tenant:          tenant,
		PublisherKey:    resolved.PublisherKey.String(),
		Instance:        p.instance,
		Metrics:         resolved.Metrics,
		SourceTimestamp: int64(resolved.Timestamp),
		SourceType:      "go", // was BuildEnvelope's implicit default
	})

	body, err := json.Marshal(env)
	if err != nil {
		p.failed.Add(1)
		return fmt.Errorf("shadowpub: marshal envelope: %w", err)
	}

	msgID := newMessageID()
	return p.publishBytesOnce(ctx, routingKey, msgID, body)
}

// PublishBytes publishes an already-encoded envelope body to the given
// routing key + message ID. Used by the outbox drainer (ADR-0011 P2) —
// the outbox stores marshaled envelope bytes, so the drainer avoids
// re-marshaling and just publishes the raw payload.
//
// Same publisher-confirm semantics as Publish: returns typed errors
// (ErrPublishNacked, ErrConfirmTimeout) for the failure modes callers
// need to distinguish.
//
// On connection-level errors (RMQ restart, network drop), transparently
// re-dials via reconnect() and retries ONCE. This closes the ADR-0011
// P3 chaos-test gap where an RMQ outage would strand outbox rows.
func (p *Publisher) PublishBytes(ctx context.Context, routingKey, messageID string, body []byte) error {
	if err := p.publishBytesOnce(ctx, routingKey, messageID, body); err != nil {
		if isConnectionError(err) {
			if p.logger != nil {
				p.logger.Warn("shadowpub: connection-level publish failure — reconnecting",
					slog.String("err", err.Error()))
			}
			if recErr := p.reconnect(p.logger); recErr != nil {
				// Reconnect failed — surface the ORIGINAL error, not the
				// reconnect error. Caller (drain loop) will retry later.
				return err
			}
			// One retry after successful reconnect.
			return p.publishBytesOnce(ctx, routingKey, messageID, body)
		}
		return err
	}
	return nil
}

// publishBytesOnce is the single-attempt inner. Callers wrap it with
// retry semantics.
//
// Holds the WLock across BOTH publish AND wait-confirm. This closes a
// race where reconnect() runs between the publish (on the old channel)
// and the confirm-read (on the new, empty confirms). Symptom in chaos
// tests: `shadowpub: confirms channel closed` after a successful
// reconnect. Cost: reconnect blocks up to ConfirmTimeout (5s) waiting
// for the in-flight publish to complete. Acceptable — publishes are
// sequential from the drain goroutine.
func (p *Publisher) publishBytesOnce(ctx context.Context, routingKey, messageID string, body []byte) error {
	timeout := p.ConfirmTimeout
	if timeout <= 0 {
		timeout = DefaultConfirmTimeout
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ch == nil {
		return fmt.Errorf("shadowpub: no channel")
	}
	err := p.ch.PublishWithContext(ctx, p.exchange, routingKey, false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			MessageId:    messageID,
			Body:         body,
			// Carry the trace context onto the AMQP message so oeecloud-worker's
			// consume continues this trace across the broker (phase 2a extract
			// side). ctx carries the producer span from Publish/runOutboxDrain.
			Headers: amqptrace.Inject(ctx, amqp.Table{}),
		})
	if err != nil {
		p.failed.Add(1)
		return fmt.Errorf("shadowpub: publish %s: %w", routingKey, err)
	}
	p.published.Add(1)
	// Read confirms via the CURRENT channel — same generation as the
	// publish above, guaranteed by holding the lock.
	return p.waitConfirmLocked(ctx, timeout)
}

// waitConfirmLocked assumes the caller holds p.mu. Reads p.confirms
// directly (no lock re-acquisition). Same semantics as waitConfirm but
// intended for the in-lock publish path.
func (p *Publisher) waitConfirmLocked(ctx context.Context, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case c, ok := <-p.confirms:
		if !ok {
			p.failed.Add(1)
			return fmt.Errorf("shadowpub: confirms channel closed")
		}
		if !c.Ack {
			p.nacked.Add(1)
			return ErrPublishNacked
		}
		p.confirmed.Add(1)
		return nil
	case <-timer.C:
		p.confirmTimeouts.Add(1)
		return ErrConfirmTimeout
	case <-ctx.Done():
		return ctx.Err()
	}
}

// ReconnectCount is the number of times shadowpub has re-dialed the
// AMQP connection. Non-zero = ops signal that RMQ has flapped or been
// restarted; investigate if it grows unexpectedly.
func (p *Publisher) ReconnectCount() uint64 { return p.reconnects.Load() }

// waitConfirm blocks on the next confirmation. Returns nil on Ack, typed
// errors on Nack / timeout / ctx cancel. Reads the confirms channel under
// rlock so reconnect() can atomically swap it.
func (p *Publisher) waitConfirm(ctx context.Context, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	p.mu.RLock()
	confirms := p.confirms
	p.mu.RUnlock()

	select {
	case c, ok := <-confirms:
		if !ok {
			// Channel closed — most likely the channel/connection died.
			p.failed.Add(1)
			return fmt.Errorf("shadowpub: confirms channel closed")
		}
		if !c.Ack {
			p.nacked.Add(1)
			return ErrPublishNacked
		}
		p.confirmed.Add(1)
		return nil
	case <-timer.C:
		p.confirmTimeouts.Add(1)
		return ErrConfirmTimeout
	case <-ctx.Done():
		return ctx.Err()
	}
}

// EnvelopeInput is the pure-function seam used by BuildEnvelope. Isolated
// so unit tests don't need an AMQP connection.
//
// One EnvelopeInput describes ONE physical MQTT arrival (a
// sparkplug.ResolvedPayload). It carries the metrics slice so BuildEnvelope
// can emit a single-message-many-metrics envelope matching Node-RED's
// output shape.
type EnvelopeInput struct {
	Tenant          string
	PublisherKey    string
	Instance        string
	Metrics         []sparkplug.ResolvedMetric
	SourceTimestamp int64  // Unix millis — matches oeecloud Payload.Timestamp
	SourceType      string // empty → defaults to "go" (ADR-0010 back-compat)
}

// BuildEnvelope constructs an envelope matching oeecloud-worker's expected
// shape: single message carrying N metrics under the `metrics` array.
//
// SourceType default is "go" — oeecloud-worker dispatches writes into
// shadow_go_port.* (ADR-0010 Phase 3 shadow-mode DB comparison). Callers
// override via EnvelopeInput.SourceType, e.g. "refactored" routes writes
// into packiot_shadow public.* for the ADR-0012 refactor POC.
func BuildEnvelope(in EnvelopeInput) Envelope {
	// NO defaulting: source_type "" is a first-class value post-10.9 —
	// it IS the F1 production route. The old ""→"go" coercion here made
	// the triple-emit's production leg silently emit a SECOND go
	// envelope: F2 received everything twice (harmless — idempotent
	// upserts), F1 received nothing, and the emit-side metric couldn't
	// see it because it counts before this function. Callers that want
	// "go" say "go".
	sourceType := in.SourceType
	metrics := make([]Metric, 0, len(in.Metrics))
	for _, m := range in.Metrics {
		metrics = append(metrics, Metric{
			Name:      m.Name,
			Timestamp: int64(m.Timestamp),
			Value:     m.Value,
			// Counter / CurSpeed / ID are populated only when the Sparkplug
			// metric carried them; ResolvedMetric doesn't currently surface
			// these separately, so they stay nil for now (omitempty).
		})
	}
	return Envelope{
		Timestamp:  in.SourceTimestamp,
		Gateway:    fmt.Sprintf("edge-transformer:%s", in.Instance),
		SourceType: sourceType,
		Metrics:    metrics,
	}
}

// BuildEnvelopeFromMetrics constructs an envelope from PRE-BUILT Metric
// entries rather than from raw sparkplug ResolvedMetrics. It is the seam
// for the #276 Calc cutover (ADR-0010 Phase 4): the caller assembles the
// F3 ("refactored") flow's metrics from the Calc port's Decision.Metrics
// (Value=delta / Counter=cumulative — the prod shape) plus non-counter
// pass-through metrics, then hands the finished slice here.
//
// Deliberately dumb — no field derivation, no source-type defaulting. The
// mapping from calc.Metric → shadowpub.Metric lives in the caller (main.go)
// so this publishing package stays free of any transform-package import.
func BuildEnvelopeFromMetrics(instance, sourceType string, sourceTimestamp int64, metrics []Metric) Envelope {
	return Envelope{
		Timestamp:  sourceTimestamp,
		Gateway:    fmt.Sprintf("edge-transformer:%s", instance),
		SourceType: sourceType,
		Metrics:    metrics,
	}
}

// parameterFromMetricName extracts the last segment of the Sparkplug topic
// name, matching what Phase 2.5b's Node-RED adapter emits as `parameter`.
// e.g. "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit" → "Unit"
func parameterFromMetricName(name string) string {
	if name == "" {
		return "unknown"
	}
	if i := strings.LastIndex(name, "/"); i >= 0 && i < len(name)-1 {
		return name[i+1:]
	}
	return name
}

// datatypeToString maps the Sparkplug B datatype enum int back to the
// lowercase-with-underscore form that Phase 2.5b's Node-RED path emits.
// The comparator diffs on this string so both paths must agree.
func datatypeToString(dt uint32) string {
	switch sparkplug.DataType(dt) {
	case sparkplug.DataType_Int8, sparkplug.DataType_Int16, sparkplug.DataType_Int32:
		return "int32"
	case sparkplug.DataType_Int64:
		return "int64"
	case sparkplug.DataType_UInt8, sparkplug.DataType_UInt16, sparkplug.DataType_UInt32:
		return "uint32"
	case sparkplug.DataType_UInt64:
		return "uint64"
	case sparkplug.DataType_Float:
		return "float"
	case sparkplug.DataType_Double:
		return "double"
	case sparkplug.DataType_Boolean:
		return "bool"
	case sparkplug.DataType_String:
		return "string"
	default:
		return "auto"
	}
}

// newMessageID returns a compact URL-safe random ID. Matches the general
// shape the Node-RED publisher emits (timestamp-suffix + random) without
// requiring an exact byte-match.
func newMessageID() string {
	var b [9]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

// rfc3339Millis is ISO-8601 with millisecond precision — matches the
// Node-RED path's `.toISOString().replace('Z', '000Z')` convention.
const rfc3339Millis = "2006-01-02T15:04:05.000Z07:00"
