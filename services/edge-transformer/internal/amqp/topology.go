// Package amqp owns the RabbitMQ connection, topology, and consumer
// lifecycle. Topology is declared idempotently on every startup so
// broker restarts + fresh deploys converge to the same state.
//
// Lifted from services/oeecloud-worker/internal/amqp/topology.go per
// ADR-0009 reuse rule (Errata Correction 2). Only the exchange/queue
// names change — the structural pattern (catch-all queue + per-tenant
// queue + retry queue with TTL + DLX back to source + terminal failed
// queue) is identical because the operational problem class is identical.
//
// TODO(ADR-0009 Phase 2): add the outbox.cloud_api.<tenant> exchange +
// queue topology (mirror-worker-go's DLQ + reanimator pattern, PRs #77 +
// #84). Today the skeleton declares only the inbound side — Phase 2 adds
// the outbound side once the shadow-mode handler is replaced by a real
// transform-then-publish handler.
package amqp

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

// DeclareTopology asserts the full exchange/queue/binding graph the
// transformer depends on. Three exchanges and per-tenant queues mirror
// the oeecloud-worker shape:
//
//	┌────────────────────────────────────────────────────────────────────┐
//	│  plc.normalized  (topic exchange, NEW for ADR-0009 Phase 2)        │
//	│  — published by edge-node-red after its Phase 3 cutover; today no  │
//	│    publisher exists so this scaffold's queues stay empty.          │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │  routing key 'plc.normalized.<tenant>'
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  edge-transformer-q-<tenant>  (durable, NEW)                       │
//	│    x-dead-letter-exchange: plc.normalized-retry                    │
//	│  ── consumed by THIS service, one Channel + goroutine per tenant ──│
//	└────────────────────────────────────────────────────────────────────┘
//	                  │  nack → DLX
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  plc.normalized-retry (topic exchange) →                           │
//	│   edge-transformer-q-<tenant>-retry-30s                            │
//	│    x-message-ttl: 30000, x-dead-letter-exchange: plc.normalized    │
//	└────────────────────────────────────────────────────────────────────┘
//	                  │
//	                  ▼ after MaxRetries, handleDelivery publishes to:
//	┌────────────────────────────────────────────────────────────────────┐
//	│  plc.normalized-failed → edge-transformer-q-<tenant>-failed        │
//	│  (terminal, NO TTL, NO DLX — human inspection only)                │
//	└────────────────────────────────────────────────────────────────────┘
//
// The "legacy catch-all" queue from oeecloud-worker is kept here for
// symmetry — it gives operators a panic-button queue to bind `#` to if
// per-tenant routing breaks during onboarding. In normal operation it
// stays empty (no `#` binding declared; only `sparkplug.data` / equivalent
// exact bindings if/when added).
func DeclareTopology(ctx context.Context, ch *amqp.Channel, cfg *config.Config, tenants []string, logger *slog.Logger) error {
	// 1. Exchanges.
	for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
		if err := ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare exchange %s: %w", ex, err)
		}
	}

	// 2. Legacy catch-all queue. Declared but NOT bound to anything (no
	//    `#` binding). Operator can bind it manually as a panic-button.
	if _, err := ch.QueueDeclare(cfg.WorkerQueue, true, false, false, false, amqp.Table{
		"x-dead-letter-exchange": cfg.RetryExchange,
	}); err != nil {
		return fmt.Errorf("declare worker queue: %w", err)
	}

	// 3. Legacy retry queue with TTL + DLX back to source. Mirrors
	//    oeecloud-worker so operator runbooks transfer.
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

	// 5. Per-tenant queues (one tenant per transformer instance in the
	//    factory mode; the loop still generalizes in case a future
	//    multi-tenant edge-transformer instance lands).
	for _, t := range tenants {
		mainQ := fmt.Sprintf("%s-%s", cfg.WorkerQueue, t)
		retryQ := fmt.Sprintf("%s-%s-retry-30s", cfg.WorkerQueue, t)
		failedQ := fmt.Sprintf("%s-%s-failed", cfg.WorkerQueue, t)
		routingKey := fmt.Sprintf("%s.%s", cfg.SourceExchange, t) // e.g. plc.normalized.cpack

		if _, err := ch.QueueDeclare(mainQ, true, false, false, false, amqp.Table{
			"x-dead-letter-exchange": cfg.RetryExchange,
		}); err != nil {
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
	}

	logger.Info("amqp topology declared",
		slog.String("source_exchange", cfg.SourceExchange),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.String("retry_exchange", cfg.RetryExchange),
		slog.Int("retry_ttl_ms", cfg.RetryTTLMs),
		slog.Int("max_retries", cfg.MaxRetries),
		slog.Int("tenant_queues", len(tenants)),
		slog.Any("tenants", tenants),
	)
	return nil
}

// CommandQueueNames returns the (main, retry, failed, ack) queue names for a
// tenant on the command channel. Single source of truth so the topology
// declaration and the consumer agree byte-for-byte (the PR #56 lesson: a
// consumer reading a queue nobody declares — or vice versa — is a silent
// dead-letter sink).
func CommandQueueNames(cfg *config.Config, tenant string) (main, retry, failed, ack string) {
	base := fmt.Sprintf("%s-%s", cfg.CommandsQueuePrefix, tenant)
	return base + "-q", base + "-q-retry-30s", base + "-q-failed", base + "-ack-q"
}

// DeclareCommandTopology asserts the edge command channel's exchange/queue/
// binding graph (ADR-0019 C1). This is the INBOUND return path — operator
// commands flow cloud → broker → transformer → PLC — so it reuses the exact
// retry/DLX triple the ingest topology uses, with two differences called out
// by the design:
//
//   - QUORUM queues (x-queue-type: quorum). A machine-write command must not
//     be lost to a single broker node crash the way a best-effort classic
//     mirror can be; quorum gives Raft-replicated durability. The ingest side
//     is classic because a dropped metric self-heals on the next tick — a
//     dropped WRITE does not.
//
//   - An ack routing key `edge.commands.<tenant>.ack` (+ a durable ack queue)
//     so the executor's delivered/rejected result is observable and the
//     edge-api producer can correlate it back to the operator action.
//
//     ┌──────────────────────────────────────────────────────────────────┐
//     │  edge.commands  (topic exchange)                                  │
//     │    routing key edge.commands.<tenant>  →  edge-commands-<t>-q     │
//     │    routing key edge.commands.<tenant>.ack → edge-commands-<t>-ack-q│
//     └─────────────────┬────────────────────────────────────────────────┘
//     │ nack(requeue=false) → DLX
//     ▼
//     edge.commands-retry → edge-commands-<t>-q-retry-30s (TTL → back to source)
//     │ after MaxRetries
//     ▼
//     edge.commands-failed → edge-commands-<t>-q-failed (terminal, human triage)
func DeclareCommandTopology(ctx context.Context, ch *amqp.Channel, cfg *config.Config, tenants []string, logger *slog.Logger) error {
	// 1. Exchanges — source + retry + failed, all topic + durable.
	for _, ex := range []string{cfg.CommandsExchange, cfg.CommandsRetryExchange, cfg.CommandsFailedExchange} {
		if err := ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare command exchange %s: %w", ex, err)
		}
	}

	quorum := amqp.Table{"x-queue-type": "quorum"}

	for _, t := range tenants {
		mainQ, retryQ, failedQ, ackQ := CommandQueueNames(cfg, t)
		routingKey := fmt.Sprintf("%s.%s", cfg.CommandsExchange, t) // edge.commands.<tenant>
		ackKey := fmt.Sprintf("%s.%s.ack", cfg.CommandsExchange, t) // edge.commands.<tenant>.ack

		// Main command queue — quorum, DLX to the retry exchange.
		mainArgs := amqp.Table{"x-queue-type": "quorum", "x-dead-letter-exchange": cfg.CommandsRetryExchange}
		if _, err := ch.QueueDeclare(mainQ, true, false, false, false, mainArgs); err != nil {
			return fmt.Errorf("declare command queue %s: %w", mainQ, err)
		}
		if err := ch.QueueBind(mainQ, routingKey, cfg.CommandsExchange, false, nil); err != nil {
			return fmt.Errorf("bind command queue %s: %w", mainQ, err)
		}

		// Retry queue — quorum, TTL, DLX back to the source exchange.
		retryArgs := amqp.Table{
			"x-queue-type":           "quorum",
			"x-message-ttl":          int32(cfg.RetryTTLMs),
			"x-dead-letter-exchange": cfg.CommandsExchange,
		}
		if _, err := ch.QueueDeclare(retryQ, true, false, false, false, retryArgs); err != nil {
			return fmt.Errorf("declare command retry queue %s: %w", retryQ, err)
		}
		if err := ch.QueueBind(retryQ, routingKey, cfg.CommandsRetryExchange, false, nil); err != nil {
			return fmt.Errorf("bind command retry queue %s: %w", retryQ, err)
		}

		// Terminal failed queue — quorum, NO TTL, NO DLX (human triage).
		if _, err := ch.QueueDeclare(failedQ, true, false, false, false, quorum); err != nil {
			return fmt.Errorf("declare command failed queue %s: %w", failedQ, err)
		}
		if err := ch.QueueBind(failedQ, routingKey, cfg.CommandsFailedExchange, false, nil); err != nil {
			return fmt.Errorf("bind command failed queue %s: %w", failedQ, err)
		}

		// Ack queue — quorum, durable. Bound to the ack routing key on the
		// source exchange so the delivered/rejected result survives a crash
		// and the producer can correlate it. The transformer WRITES here; the
		// edge-api producer (follow-up) READS here.
		if _, err := ch.QueueDeclare(ackQ, true, false, false, false, quorum); err != nil {
			return fmt.Errorf("declare command ack queue %s: %w", ackQ, err)
		}
		if err := ch.QueueBind(ackQ, ackKey, cfg.CommandsExchange, false, nil); err != nil {
			return fmt.Errorf("bind command ack queue %s: %w", ackQ, err)
		}
	}

	logger.Info("edge command topology declared",
		slog.String("commands_exchange", cfg.CommandsExchange),
		slog.String("retry_exchange", cfg.CommandsRetryExchange),
		slog.String("failed_exchange", cfg.CommandsFailedExchange),
		slog.Int("retry_ttl_ms", cfg.RetryTTLMs),
		slog.Int("tenant_queues", len(tenants)),
		slog.Any("tenants", tenants),
	)
	return nil
}
