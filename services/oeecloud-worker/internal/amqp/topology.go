// Package amqp owns the RabbitMQ connection, topology, and consumer
// lifecycle. Topology is declared idempotently on every startup so
// broker restarts + fresh deploys converge to the same state.
package amqp

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

// DeclareTopology asserts the full exchange/queue/binding graph the worker
// depends on. Three exchanges and three queues are involved:
//
//	┌────────────────────────────────────────────────────────────────────┐
//	│  oee  (topic exchange, EXISTING — owned by edge-nodered publishes) │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │  routing key '#' (catch-all)
//	                  ▼
//	┌────────────────────────────────────────────────────────────────────┐
//	│  oeecloud-worker-q  (durable, NEW)                                 │
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
//	│  oeecloud-worker-q-retry-30s  (NEW)                                │
//	│    x-message-ttl: 30000                                            │
//	│    x-dead-letter-exchange: oee  ← bounces BACK to source on expiry │
//	└─────────────────┬──────────────────────────────────────────────────┘
//	                  │ after TTL, re-published to `oee` → oeecloud-worker-q
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
//	│  oeecloud-worker-q-failed  (NEW, NO TTL, NO DLX)                   │
//	│  ── human inspection only ──                                       │
//	└────────────────────────────────────────────────────────────────────┘
//
// IMPORTANT: oeecloud-worker-q is a DIFFERENT queue from `oeecloud-q`
// (the Node-RED consumer's queue). Both are bound to the `oee` exchange
// with routing key `#`, so RabbitMQ delivers every published message to
// BOTH queues. This lets the worker run alongside Node-RED without
// competing for messages — once parity is reached, decommission Node-RED's
// queue and consumer.
func DeclareTopology(ctx context.Context, ch *amqp.Channel, cfg *config.Config, logger *slog.Logger) error {
	// 1. Exchanges
	for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
		if err := ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil); err != nil {
			return fmt.Errorf("declare exchange %s: %w", ex, err)
		}
	}

	// 2. Main worker queue with DLX → retry exchange
	if _, err := ch.QueueDeclare(cfg.WorkerQueue, true, false, false, false, amqp.Table{
		"x-dead-letter-exchange": cfg.RetryExchange,
	}); err != nil {
		return fmt.Errorf("declare worker queue: %w", err)
	}
	if err := ch.QueueBind(cfg.WorkerQueue, "#", cfg.SourceExchange, false, nil); err != nil {
		return fmt.Errorf("bind worker queue: %w", err)
	}

	// 3. Retry queue with TTL + DLX back to source. On TTL expiry,
	//    RabbitMQ re-publishes the message to `oee` (with the original
	//    routing key), where the worker queue's binding picks it up again.
	if _, err := ch.QueueDeclare(cfg.RetryQueue, true, false, false, false, amqp.Table{
		"x-message-ttl":          int32(cfg.RetryTTLMs),
		"x-dead-letter-exchange": cfg.SourceExchange,
	}); err != nil {
		return fmt.Errorf("declare retry queue: %w", err)
	}
	if err := ch.QueueBind(cfg.RetryQueue, "#", cfg.RetryExchange, false, nil); err != nil {
		return fmt.Errorf("bind retry queue: %w", err)
	}

	// 4. Terminal failed queue. No TTL, no DLX — messages sit here until
	//    a human dequeues + investigates. Bound to oee-failed.
	if _, err := ch.QueueDeclare(cfg.FailedQueue, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare failed queue: %w", err)
	}
	if err := ch.QueueBind(cfg.FailedQueue, "#", cfg.FailedExchange, false, nil); err != nil {
		return fmt.Errorf("bind failed queue: %w", err)
	}

	logger.Info("amqp topology declared",
		slog.String("source_exchange", cfg.SourceExchange),
		slog.String("worker_queue", cfg.WorkerQueue),
		slog.String("retry_exchange", cfg.RetryExchange),
		slog.Int("retry_ttl_ms", cfg.RetryTTLMs),
		slog.Int("max_retries", cfg.MaxRetries),
	)
	return nil
}
