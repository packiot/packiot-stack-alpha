package amqp

import (
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

// xDeath builds one x-death entry shaped like RabbitMQ 3.13 sends it (as decoded by amqp091-go:
// count is an int64 "long", routing-keys a []any of strings, time a time.Time).
func xDeath(queue, reason, exchange string, count int64) amqp.Table {
	return amqp.Table{
		"count":        count,
		"exchange":     exchange,
		"queue":        queue,
		"reason":       reason,
		"routing-keys": []any{"plc.normalized.cpack"},
		"time":         time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC),
	}
}

// afterFailures is the header a message carries when it arrives back on queue after the handler
// failed it n times: each failure is one `rejected` death on the main queue (our nack → DLX
// retryExchange) plus one `expired` death on the retry queue (the TTL sending it back to
// sourceExchange). RabbitMQ keeps one entry per (queue, reason) and bumps its count; the most
// recent death is first.
func afterFailures(queue, sourceExchange, retryExchange string, n int64) amqp.Table {
	if n == 0 {
		return amqp.Table{}
	}
	return amqp.Table{
		"x-death": []any{
			xDeath(queue+"-retry-30s", "expired", retryExchange, n),
			xDeath(queue, "rejected", sourceExchange, n),
		},
		"x-first-death-exchange": sourceExchange,
		"x-first-death-queue":    queue,
		"x-first-death-reason":   "rejected",
	}
}

const (
	ingestQ  = "edge-transformer-q-cpack"
	commandQ = "edge-commands-cpack-q"
)

func ingestAfter(n int64) amqp.Table {
	return afterFailures(ingestQ, "plc.normalized", "plc.normalized-retry", n)
}

func TestRetryCountFixtures(t *testing.T) {
	cases := []struct {
		name  string
		h     amqp.Table
		queue string
		want  int
	}{
		{"never dead-lettered", amqp.Table{}, ingestQ, 0},
		{"nil headers", nil, ingestQ, 0},
		{"one failure: rejected + expired entries count once", ingestAfter(1), ingestQ, 1},
		{"four failures", ingestAfter(4), ingestQ, 4},
		{"command queue", afterFailures(commandQ, "edge.commands", "edge.commands-retry", 2), commandQ, 2},
		{"unknown queue falls back to all rejected entries", ingestAfter(2), "", 2},
		{"rejected on another queue does not count", amqp.Table{"x-death": []any{
			xDeath(ingestQ+"-retry-30s", "expired", "plc.normalized-retry", 1),
			xDeath("edge-transformer-q", "rejected", "plc.normalized", 4),
			xDeath(ingestQ, "rejected", "plc.normalized", 1),
		}}, ingestQ, 1},
		{"maxlen / delivery_limit deaths are not handler failures", amqp.Table{"x-death": []any{
			xDeath(ingestQ, "maxlen", "plc.normalized", 7),
			xDeath(ingestQ, "delivery_limit", "plc.normalized", 3),
			xDeath(ingestQ, "rejected", "plc.normalized", 1),
		}}, ingestQ, 1},
		{"int32 count accepted", amqp.Table{"x-death": []any{amqp.Table{
			"queue": ingestQ, "reason": "rejected", "count": int32(2),
		}}}, ingestQ, 2},
		{"malformed header ignored", amqp.Table{"x-death": "nope"}, ingestQ, 0},
		{"malformed entry ignored", amqp.Table{"x-death": []any{"nope", xDeath(ingestQ, "rejected", "plc.normalized", 1)}}, ingestQ, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := RetryCount(c.h, c.queue); got != c.want {
				t.Fatalf("RetryCount = %d, want %d", got, c.want)
			}
		})
	}
}

// TestMaxRetriesGivesExactlyNRetries replays the consumers' decision (handleDelivery: park when
// RetriesExhausted(RetryCount), else run the handler; a failing handler nacks → rejected + expired
// deaths) for a handler that always fails. MAX_RETRIES=N must mean the first run + N retries.
// The old rule (sum of every x-death count >= N) gave 3 runs (2 retries) for N=5.
func TestMaxRetriesGivesExactlyNRetries(t *testing.T) {
	for _, q := range []struct{ queue, src, retry string }{
		{ingestQ, "plc.normalized", "plc.normalized-retry"},
		{commandQ, "edge.commands", "edge.commands-retry"},
	} {
		for _, maxRetries := range []int{0, 1, 2, 3, 5, 8} {
			runs := 0
			for failures := int64(0); ; failures++ {
				if RetriesExhausted(RetryCount(afterFailures(q.queue, q.src, q.retry, failures), q.queue), maxRetries) {
					break // parked to the failed exchange
				}
				runs++ // handler runs and fails → nack → one more rejected + expired death
				if runs > 100 {
					t.Fatal("never parked")
				}
			}
			if want := maxRetries + 1; runs != want {
				t.Errorf("%s MAX_RETRIES=%d: handler ran %d times, want %d (1 + %d retries)", q.queue, maxRetries, runs, want, maxRetries)
			}
		}
	}
}
