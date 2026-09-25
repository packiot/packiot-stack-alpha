package analyticspub

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// NewWithRetry is New with a bounded startup retry. After a host reboot every
// container starts at once, so the decoder can come up before RabbitMQ is
// resolvable/listening. A single failed New used to leave the publisher nil for the
// life of the process: MQTT kept decoding but nothing reached the cloud and the
// outbox was disabled too — ingest silently stopped until a manual restart
// (2026-09-25). Retry with exponential backoff (1 s → 15 s) until maxWait elapses or
// ctx ends; the caller treats a final error as fatal so the container's restart
// policy recycles it rather than running half-alive.
func NewWithRetry(ctx context.Context, amqpURL, exchange string, logger *slog.Logger, maxWait time.Duration) (*Publisher, error) {
	return newWithRetry(ctx, func() (*Publisher, error) { return New(amqpURL, exchange, logger) }, logger, maxWait, time.Second, 15*time.Second)
}

func newWithRetry(ctx context.Context, open func() (*Publisher, error), logger *slog.Logger,
	maxWait, first, maxBackoff time.Duration) (*Publisher, error) {
	deadline := time.Now().Add(maxWait)
	backoff := first
	for attempt := 1; ; attempt++ {
		p, err := open()
		if err == nil {
			if attempt > 1 {
				logger.Info("analyticspub: connected after retry", slog.Int("attempt", attempt))
			}
			return p, nil
		}
		if time.Now().Add(backoff).After(deadline) {
			return nil, fmt.Errorf("analyticspub: giving up after %d attempts over %s: %w", attempt, maxWait, err)
		}
		logger.Warn("analyticspub: broker not reachable yet, retrying",
			slog.Int("attempt", attempt), slog.Duration("in", backoff), slog.String("err", err.Error()))
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("analyticspub: startup cancelled after %d attempts: %w", attempt, err)
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}
