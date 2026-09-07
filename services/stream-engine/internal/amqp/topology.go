// Package amqp owns the RabbitMQ connection, topology, and consumer
// lifecycle. Topology is declared idempotently on every startup so
// broker restarts + fresh deploys converge to the same state.
package amqp

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

// ErrSACMismatch is returned by DeclareTenant when WORKER_POOL_SAC_ENABLED is
// on but a tenant's MAIN queue ALREADY exists without the
// x-single-active-consumer argument. Queue arguments are immutable, so
// RabbitMQ answers the redeclare with a 406 PRECONDITION_FAILED and closes the
// channel. We surface this as a distinct, actionable error instead of an
// opaque channel death — the fix is the one-time queue migration
// (scripts/migrate-tenant-queues-sac.sh). The offending queue is left exactly
// as it was: we never delete it implicitly.
var ErrSACMismatch = errors.New("tenant queue exists without x-single-active-consumer; run the SAC queue migration (scripts/migrate-tenant-queues-sac.sh) — args are immutable")

// isPreconditionFailed reports whether err is an AMQP 406 PRECONDITION_FAILED
// channel exception (what a redeclare with mismatched immutable args yields).
func isPreconditionFailed(err error) bool {
	var ae *amqp.Error
	if errors.As(err, &ae) {
		return ae.Code == amqp.PreconditionFailed // 406
	}
	return false
}

// DeclareTopology asserts the full exchange/queue/binding graph the worker
// depends on. Three exchanges and three queues are involved:
//
//	┌────────────────────────────────────────────────────────────────────┐
//	│  oee  (topic exchange, EXISTING — owned by edge-nodered publishes) │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │  routing key '#' (catch-all)
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  stream-engine-q  (durable, NEW)                                 │
//	│    x-dead-letter-exchange: oee-retry                               │
//	│  ── consumed by THIS worker, prefetch=N, manual ack ──             │
//	│     ack on success, nack(requeue=false) → DLX → retry queue        │
//	└────────────────────────────────────────────────────────────────────┘
//	                  │  nack → DLX
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  oee-retry  (topic exchange, NEW)                                  │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  stream-engine-q-retry-30s  (NEW)                                │
//	│    x-message-ttl: 30000                                            │
//	│    x-dead-letter-exchange: oee  ← bounces BACK to source on expiry │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │ after TTL, re-published to `oee` → stream-engine-q
//	                  ▼ (cycle repeats; x-death header counts retries)
//
//	After MaxRetries (via x-death count check in handler), worker
//	explicitly publishes the message to oee-failed below + acks original:
//
//	┌────────────────────────────────────────────────────────────────────┐
//	│  oee-failed  (topic exchange, NEW, terminal)                       │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  stream-engine-q-failed  (NEW, NO TTL, NO DLX)                   │
//	│  ── human inspection only ──                                       │
//	└────────────────────────────────────────────────────────────────────┘
//
// IMPORTANT: stream-engine-q is a DIFFERENT queue from `oeecloud-q`
// (the Node-RED consumer's queue). Both are bound to the `oee` exchange
// with routing key `#`, so RabbitMQ delivers every published message to
// BOTH queues. This lets the worker run alongside Node-RED without
// competing for messages — once parity is reached, decommission Node-RED's
// queue and consumer.
//
// Strategy D: DeclareTopology takes the *Connection (not a single Channel) so
// that each tenant's triple is declared on its OWN short-lived channel. That
// isolation matters when WORKER_POOL_SAC_ENABLED is on: a 406 mismatch on one
// tenant's queue kills only that tenant's channel, not the shared one, so the
// other tenants + the legacy queue still declare. The exchanges + legacy triple
// are declared on one channel up front; DeclareTenant opens+closes a channel
// per tenant.
func DeclareTopology(ctx context.Context, conn *amqp.Connection, cfg *config.Config, tenants []string, logger *slog.Logger) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("topology channel: %w", err)
	}
	defer ch.Close()

	// 1. Exchanges
	for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
		if err := ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare exchange %s: %w", ex, err)
		}
	}

	// 2. Legacy queue — Phase 2b cutover preparation. Originally bound
	//    to `#` (catch-all). We replace that with an EXACT binding to
	//    `sparkplug.data` so:
	//      - Today: edge-nodered publishes `sparkplug.data` → matches exact
	//        binding → still lands in legacy (no traffic change yet)
	//      - After edge-nodered's Phase 2b deploy publishes
	//        `sparkplug.data.<gateway>` → 3-segment key does NOT match
	//        the 2-segment exact binding → legacy stops getting new
	//        traffic → per-tenant queues take over.
	//    Decoupled deploys: worker can ship first or last; either order
	//    keeps the legacy queue receiving messages until edge-nodered's
	//    side flips. No double-routing.
	//
	//    QueueUnbind is idempotent (no-op if `#` already unbound) so this
	//    runs safely on every reconnect.
	if _, err := ch.QueueDeclare(cfg.WorkerQueue, true, false, false, false, amqp.Table{
		"x-dead-letter-exchange": cfg.RetryExchange,
	}); err != nil {
		return fmt.Errorf("declare worker queue: %w", err)
	}
	if err := ch.QueueUnbind(cfg.WorkerQueue, "#", cfg.SourceExchange, nil); err != nil {
		return fmt.Errorf("unbind legacy # binding: %w", err)
	}
	if err := ch.QueueBind(cfg.WorkerQueue, "sparkplug.data", cfg.SourceExchange, false, nil); err != nil {
		return fmt.Errorf("bind legacy queue to sparkplug.data: %w", err)
	}

	// 3. Legacy retry queue with TTL + DLX back to source.
	if _, err := ch.QueueDeclare(cfg.RetryQueue, true, false, false, false, amqp.Table{
		"x-message-ttl":          int32(cfg.RetryTTLMs),
		"x-dead-letter-exchange": cfg.SourceExchange,
	}); err != nil {
		return fmt.Errorf("declare retry queue: %w", err)
	}
	if err := ch.QueueBind(cfg.RetryQueue, "#", cfg.RetryExchange, false, nil); err != nil {
		return fmt.Errorf("bind retry queue: %w", err)
	}

	// 4. Legacy terminal failed queue.
	if _, err := ch.QueueDeclare(cfg.FailedQueue, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare failed queue: %w", err)
	}
	if err := ch.QueueBind(cfg.FailedQueue, "#", cfg.FailedExchange, false, nil); err != nil {
		return fmt.Errorf("bind failed queue: %w", err)
	}

	// 5. Per-tenant queues (Strategy C Phase 1 / Strategy D shared pool).
	//    Each tenant's triple is declared on its own channel via DeclareTenant.
	for _, t := range tenants {
		if err := DeclareTenant(conn, cfg, t, logger); err != nil {
			return err
		}
	}

	logger.Info("amqp topology declared",
		slog.String("source_exchange", cfg.SourceExchange),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.String("retry_exchange", cfg.RetryExchange),
		slog.Int("retry_ttl_ms", cfg.RetryTTLMs),
		slog.Int("max_retries", cfg.MaxRetries),
		slog.Int("tenant_queues", len(tenants)),
		slog.Bool("single_active_consumer", cfg.WorkerPoolSACEnabled),
		slog.Any("tenants", tenants),
	)
	return nil
}

// DeclareTenant asserts ONE tenant's queue triple mirroring the legacy shape:
//
//   - <prefix>-<tenant>             (main, bound sparkplug.data.<tenant>)
//   - <prefix>-<tenant>-retry-30s   (DLX target with TTL)
//   - <prefix>-<tenant>-failed      (terminal)
//
// Idempotent — re-running is safe, so it is called both at boot (from
// DeclareTopology) and by the dynamic-discovery loop for a NEW tenant found
// mid-run. It opens its own channel so a per-tenant failure (notably the SAC
// 406) is isolated from other tenants and the shared topology channel.
//
// When cfg.WorkerPoolSACEnabled is true the MAIN queue is declared with
// x-single-active-consumer:true so a pool of replicas keeps exactly one active
// consumer per tenant (order-preserving) with the rest as hot standbys. The
// retry + failed queues never carry SAC: nothing actively consumes them (retry
// is TTL→DLX only; failed is human-inspection), so single-active-consumer is
// meaningless there.
func DeclareTenant(conn *amqp.Connection, cfg *config.Config, t string, logger *slog.Logger) error {
	ch, err := conn.Channel()
	if err != nil {
		return fmt.Errorf("tenant channel for %s: %w", t, err)
	}
	defer ch.Close()

	mainQ := fmt.Sprintf("%s-%s", cfg.WorkerQueue, t)
	retryQ := fmt.Sprintf("%s-%s-retry-30s", cfg.WorkerQueue, t)
	failedQ := fmt.Sprintf("%s-%s-failed", cfg.WorkerQueue, t)
	routingKey := fmt.Sprintf("sparkplug.data.%s", t)

	mainArgs := amqp.Table{"x-dead-letter-exchange": cfg.RetryExchange}
	if cfg.WorkerPoolSACEnabled {
		mainArgs["x-single-active-consumer"] = true
	}
	if _, err := ch.QueueDeclare(mainQ, true, false, false, false, mainArgs); err != nil {
		// A 406 while SAC is enabled means the queue pre-exists WITHOUT the
		// immutable arg. Do not mask it — surface the actionable migration
		// error. (The channel is already dead here; the caller reconnects.)
		if cfg.WorkerPoolSACEnabled && isPreconditionFailed(err) {
			logger.Error("SAC precondition failed — tenant queue predates x-single-active-consumer",
				slog.String("queue", mainQ),
				slog.String("remediation", "delete+recreate the tenant queue triple: scripts/migrate-tenant-queues-sac.sh"),
				slog.String("err", err.Error()))
			return fmt.Errorf("declare tenant queue %s: %w (%v)", mainQ, ErrSACMismatch, err)
		}
		return fmt.Errorf("declare tenant queue %s: %w", mainQ, err)
	}
	if err := ch.QueueBind(mainQ, routingKey, cfg.SourceExchange, false, nil); err != nil {
		return fmt.Errorf("bind tenant queue %s: %w", mainQ, err)
	}

	if _, err := ch.QueueDeclare(retryQ, true, false, false, false, amqp.Table{
		"x-message-ttl":          int32(cfg.RetryTTLMs),
		"x-dead-letter-exchange": cfg.SourceExchange,
	}); err != nil {
		return fmt.Errorf("declare tenant retry queue %s: %w", retryQ, err)
	}
	if err := ch.QueueBind(retryQ, routingKey, cfg.RetryExchange, false, nil); err != nil {
		return fmt.Errorf("bind tenant retry queue %s: %w", retryQ, err)
	}

	if _, err := ch.QueueDeclare(failedQ, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare tenant failed queue %s: %w", failedQ, err)
	}
	if err := ch.QueueBind(failedQ, routingKey, cfg.FailedExchange, false, nil); err != nil {
		return fmt.Errorf("bind tenant failed queue %s: %w", failedQ, err)
	}
	return nil
}
