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
		"routing-keys": []any{"sparkplug.data.cpack"},
		"time":         time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC),
	}
}

// afterFailures is the header a message carries when it arrives back on the tenant queue after the
// handler failed it n times: each failure is one `rejected` death on the main queue (our nack) plus
// one `expired` death on the retry queue (the TTL sending it back to `oee`). RabbitMQ keeps one entry
// per (queue, reason) and bumps its count; the most recent death is first.
func afterFailures(n int64) amqp.Table {
	if n == 0 {
		return amqp.Table{}
	}
	return amqp.Table{
		"x-death": []any{
			xDeath("stream-engine-q-cpack-retry-30s", "expired", "oee-retry", n),
			xDeath("stream-engine-q-cpack", "rejected", "oee", n),
		},
		"x-first-death-exchange": "oee",
		"x-first-death-queue":    "stream-engine-q-cpack",
		"x-first-death-reason":   "rejected",
	}
}

func TestRetryCountFixtures(t *testing.T) {
	const q = "stream-engine-q-cpack"
	cases := []struct {
		name  string
		h     amqp.Table
		queue string
		want  int
	}{
		{"never dead-lettered", amqp.Table{}, q, 0},
		{"nil headers", nil, q, 0},
		{"one failure: rejected + expired entries count once", afterFailures(1), q, 1},
		{"three failures", afterFailures(3), q, 3},
		{"unknown queue falls back to all rejected entries", afterFailures(2), "", 2},
		{"rejected on another consumer's queue does not count", amqp.Table{"x-death": []any{
			xDeath("stream-engine-q-cpack-retry-30s", "expired", "oee-retry", 1),
			xDeath("oeecloud-fanout-cpack-to-sbxcpack", "rejected", "oee", 4),
			xDeath(q, "rejected", "oee", 1),
		}}, q, 1},
		{"legacy queue (pre per-tenant) entry", amqp.Table{"x-death": []any{
			xDeath("stream-engine-q-retry-30s", "expired", "oee-retry", 2),
			xDeath("stream-engine-q", "rejected", "oee", 2),
		}}, "stream-engine-q", 2},
		{"maxlen / delivery_limit deaths are not handler failures", amqp.Table{"x-death": []any{
			xDeath(q, "maxlen", "oee", 7),
			xDeath(q, "rejected", "oee", 1),
		}}, q, 1},
		{"malformed header ignored", amqp.Table{"x-death": "nope"}, q, 0},
		{"malformed entry ignored", amqp.Table{"x-death": []any{"nope", xDeath(q, "rejected", "oee", 1)}}, q, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := retryCount(c.h, c.queue); got != c.want {
				t.Fatalf("retryCount = %d, want %d", got, c.want)
			}
		})
	}
}

// TestMaxRetriesGivesExactlyNRetries replays the consumer's decision (handleDelivery: park when
// retryCount > MaxRetries, else run the handler; a failing handler nacks → rejected + expired
// deaths) for a handler that always fails. MAX_RETRIES=N must mean the initial run + N retries.
// Summing every x-death entry with >= (the old xDeathCount) gave 3 runs (2 retries) for N=5.
func TestMaxRetriesGivesExactlyNRetries(t *testing.T) {
	const q = "stream-engine-q-cpack"
	for _, maxRetries := range []int{0, 1, 3, 5} {
		runs := 0
		for failures := int64(0); ; failures++ {
			if retriesExhausted(retryCount(afterFailures(failures), q), maxRetries) {
				break // parked to oee-failed
			}
			runs++ // handler runs and fails → nack → one more rejected + expired death
			if runs > 100 {
				t.Fatal("never parked")
			}
		}
		if want := maxRetries + 1; runs != want {
			t.Errorf("MAX_RETRIES=%d: handler ran %d times, want %d (1 + %d retries)", maxRetries, runs, want, maxRetries)
		}
	}
}
