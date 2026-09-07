package command

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
)

// DevicePublisher publishes an encoded SparkPlug DCMD to the PLC over MQTT.
// Abstracted so the executor is unit-testable with a mock (no live broker).
type DevicePublisher interface {
	PublishDCMD(ctx context.Context, topic string, body []byte) error
}

// AckPublisher publishes the delivered|rejected ack back onto the command
// exchange (routing key edge.commands.<tenant>.ack). Abstracted for the same
// reason — a test asserts on the captured acks.
type AckPublisher interface {
	PublishAck(ctx context.Context, routingKey string, body []byte) error
}

// Metrics is the nil-safe Prometheus hook set (the amqp/consumer decoupling
// pattern — this package does not import prometheus). Any field may be nil.
type Metrics struct {
	Received func(tenant, verb string)
	Executed func(tenant, verb string)
	Rejected func(tenant, verb, reason string)
	Acked    func(tenant, verb, status string)
}

func (m Metrics) received(t, v string) {
	if m.Received != nil {
		m.Received(t, v)
	}
}
func (m Metrics) executed(t, v string) {
	if m.Executed != nil {
		m.Executed(t, v)
	}
}
func (m Metrics) rejected(t, v, r string) {
	if m.Rejected != nil {
		m.Rejected(t, v, r)
	}
}
func (m Metrics) acked(t, v, s string) {
	if m.Acked != nil {
		m.Acked(t, v, s)
	}
}

// Config carves out the executor's slice of the global config so tests can
// build one without the whole config.Config.
type Config struct {
	Allowed  []string // verbs permitted to translate to a write
	Exchange string   // command exchange (for the ack routing key)
	EdgeNode string   // SparkPlug edge-node id the DCMD is published under
	DedupCap int      // idempotency-key set bound
}

// Executor is the pure command-execution engine: parse → allow-list → translate
// → publish DCMD → ack. Safe for sequential use by one per-tenant consume loop
// (dedup is internally locked; a single loop processes a tenant's commands in
// order).
type Executor struct {
	allowed  map[string]struct{}
	exchange string
	edgeNode string
	dedup    *dedupStore
	device   DevicePublisher
	acks     AckPublisher
	metrics  Metrics
	logger   *slog.Logger
}

// NewExecutor wires an executor. device is required; acks may be nil (acks are
// then skipped — a degraded but non-fatal mode used by focused tests).
func NewExecutor(cfg Config, device DevicePublisher, acks AckPublisher, metrics Metrics, logger *slog.Logger) *Executor {
	allowed := make(map[string]struct{}, len(cfg.Allowed))
	for _, v := range cfg.Allowed {
		allowed[v] = struct{}{}
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Executor{
		allowed:  allowed,
		exchange: cfg.Exchange,
		edgeNode: cfg.EdgeNode,
		dedup:    newDedupStore(cfg.DedupCap),
		device:   device,
		acks:     acks,
		metrics:  metrics,
		logger:   logger,
	}
}

// Allowed reports whether a verb is in the allow-list. Exposed for tests +
// the consumer's boot log.
func (e *Executor) Allowed(verb string) bool {
	_, ok := e.allowed[verb]
	return ok
}

// Execute runs one command body end to end.
//
// Return contract:
//   - (Result{Delivered}, nil)  — DCMD published (or a no-op duplicate); the
//     broker delivery should be ACKed. An ack was published.
//   - (Result{Rejected}, nil)   — command refused (bad verb / missing params /
//     ambiguous mapping / malformed body); NO DCMD emitted; an ack-rejected was
//     published (when the tenant is known). The consumer routes the original to
//     the failed queue for triage.
//   - (Result{}, err != nil)    — a TRANSIENT publish failure (broker/MQTT
//     down). No DCMD confirmed, no dedup mark, no ack. The consumer nacks to the
//     retry queue so the command is redelivered — never silently dropped.
//
// The ordering is safety-critical: we translate (validating params) BEFORE the
// dedup check, and we mark the key seen only AFTER a confirmed publish. A
// translation reject must not poison the key; a transient publish failure must
// leave the key un-marked so the redelivery actually re-issues the write.
func (e *Executor) Execute(ctx context.Context, body []byte) (Result, error) {
	var cmd Command
	if err := json.Unmarshal(body, &cmd); err != nil {
		// No tenant/verb to attribute — count under "unknown", no ack (nothing
		// to correlate to).
		e.metrics.received("unknown", "unknown")
		e.metrics.rejected("unknown", "unknown", "malformed_envelope")
		e.logger.Warn("command: malformed envelope — rejected",
			slog.String("err", err.Error()), slog.Int("body_len", len(body)))
		return Result{Outcome: OutcomeRejected, Reason: "malformed envelope: " + err.Error()}, nil
	}

	e.metrics.received(cmd.Tenant, cmd.Verb)
	res := Result{Command: cmd}

	reject := func(reason, code string) (Result, error) {
		res.Outcome = OutcomeRejected
		res.Reason = reason
		e.metrics.rejected(cmd.Tenant, cmd.Verb, code)
		e.logger.Warn("command: rejected",
			slog.String("tenant", cmd.Tenant),
			slog.String("verb", cmd.Verb),
			slog.String("idempotency_key", cmd.IdempotencyKey),
			slog.String("reason", reason))
		e.publishAck(ctx, res)
		return res, nil
	}

	// Envelope-level validation. tenant + idempotencyKey are load-bearing:
	// the ack routes by tenant, and dedup keys on idempotencyKey. A write
	// without a dedup key is dangerous (a retry could double-actuate), so
	// its absence is itself a reject.
	if cmd.Tenant == "" {
		return reject("missing tenant", "missing_tenant")
	}
	if cmd.IdempotencyKey == "" {
		return reject("missing idempotencyKey — a write must be idempotent", "missing_idempotency_key")
	}

	// Allow-list gate — a verb not explicitly permitted is refused, never
	// guessed at (design §Safety: allow-list only).
	if !e.Allowed(cmd.Verb) {
		return reject(fmt.Sprintf("verb %q not in allow-list", cmd.Verb), "verb_not_allowed")
	}

	// Translate. Fail-safe: any ambiguity/incompleteness → reject, never a
	// partial/guessed write.
	dcmd, err := BuildDCMD(cmd, e.edgeNode)
	if err != nil {
		code := "unmapped"
		switch {
		case errors.Is(err, ErrUnknownVerb):
			code = "unmapped_verb"
		case errors.Is(err, ErrMissingParam):
			code = "missing_param"
		case errors.Is(err, ErrBadTopic):
			code = "bad_topic"
		}
		return reject(err.Error(), code)
	}

	// Idempotency: a re-delivered key is a no-op — do NOT re-issue the DCMD.
	if e.dedup.has(cmd.IdempotencyKey) {
		res.Outcome = OutcomeDelivered
		res.Duplicate = true
		res.Reason = "duplicate idempotencyKey — DCMD not re-issued"
		res.DCMDTopic = dcmd.Topic
		e.logger.Info("command: duplicate — skipping re-issue",
			slog.String("tenant", cmd.Tenant),
			slog.String("verb", cmd.Verb),
			slog.String("idempotency_key", cmd.IdempotencyKey))
		e.publishAck(ctx, res)
		e.metrics.acked(cmd.Tenant, cmd.Verb, string(OutcomeDelivered))
		return res, nil
	}

	// Publish the DCMD to the PLC. A failure here is TRANSIENT (broker/MQTT
	// down) — surface an error so the consumer retries. Crucially we have NOT
	// marked the key seen yet, so the redelivery re-issues the write.
	if err := e.device.PublishDCMD(ctx, dcmd.Topic, dcmd.Body); err != nil {
		e.logger.Error("command: DCMD publish failed — will retry",
			slog.String("tenant", cmd.Tenant),
			slog.String("verb", cmd.Verb),
			slog.String("dcmd_topic", dcmd.Topic),
			slog.String("err", err.Error()))
		return Result{Command: cmd}, fmt.Errorf("publish DCMD: %w", err)
	}

	// Commit the dedup mark only after the write is out.
	e.dedup.markIfNew(cmd.IdempotencyKey)
	e.metrics.executed(cmd.Tenant, cmd.Verb)

	res.Outcome = OutcomeDelivered
	res.DCMDTopic = dcmd.Topic
	e.logger.Info("command: executed",
		slog.String("tenant", cmd.Tenant),
		slog.String("verb", cmd.Verb),
		slog.Int("id_equipment", cmd.IDEquipment),
		slog.String("dcmd_topic", dcmd.Topic),
		slog.String("metric", dcmd.Metric))
	e.publishAck(ctx, res)
	e.metrics.acked(cmd.Tenant, cmd.Verb, string(OutcomeDelivered))
	return res, nil
}

// publishAck emits the delivered|rejected ack. Skipped when the tenant is
// unknown (nothing to route/correlate) or no AckPublisher is wired. An ack
// publish failure is logged but never undoes a completed write — the write
// already happened; losing the ack is a correlation gap, not a double-actuate.
func (e *Executor) publishAck(ctx context.Context, res Result) {
	if e.acks == nil || res.Command.Tenant == "" {
		return
	}
	routingKey := fmt.Sprintf("%s.%s.ack", e.exchange, res.Command.Tenant)
	body, err := json.Marshal(res.toAck())
	if err != nil {
		e.logger.Error("command: marshal ack failed", slog.String("err", err.Error()))
		return
	}
	if err := e.acks.PublishAck(ctx, routingKey, body); err != nil {
		e.logger.Error("command: publish ack failed",
			slog.String("routing_key", routingKey),
			slog.String("status", string(res.Outcome)),
			slog.String("err", err.Error()))
		return
	}
	if res.Outcome == OutcomeRejected {
		e.metrics.acked(res.Command.Tenant, res.Command.Verb, string(OutcomeRejected))
	}
}
