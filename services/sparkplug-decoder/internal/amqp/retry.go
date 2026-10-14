package amqp

import amqp "github.com/rabbitmq/amqp091-go"

// RetryCount returns how many times a handler has already failed this message
// on queue, read from the RabbitMQ x-death header.
//
// x-death holds ONE entry per (queue, reason) pair, each with its own count.
// In this service's topology (ingest and command channels alike) one failed
// attempt dead-letters the message twice:
//
//	{queue: <queue>,           reason: rejected} — our nack(requeue=false) → retry exchange
//	{queue: <queue>-retry-30s, reason: expired}  — the retry TTL sending it back to the source
//
// so summing every entry counted each failure twice: MAX_RETRIES=5 parked a
// message after only 3 handler runs (2 retries). Only the `rejected` entry for
// the queue being consumed is a handler failure. Matching the queue also keeps
// a copy rejected on some other queue from spending this queue's budget.
// queue == "" (unknown) falls back to every `rejected` entry. Returns 0 when
// the message was never dead-lettered. Same rule as stream-engine (#1715).
func RetryCount(h amqp.Table, queue string) int {
	deaths, ok := h["x-death"].([]any)
	if !ok {
		return 0
	}
	total := 0
	for _, e := range deaths {
		entry, ok := e.(amqp.Table)
		if !ok {
			continue
		}
		if reason, _ := entry["reason"].(string); reason != "rejected" {
			continue
		}
		if q, _ := entry["queue"].(string); queue != "" && q != queue {
			continue
		}
		total += xDeathEntryCount(entry["count"])
	}
	return total
}

// RetriesExhausted: MAX_RETRIES=max allows the first run plus max retries, so
// a delivery is parked once more than max handler runs have failed.
func RetriesExhausted(retries, max int) bool { return retries > max }

// xDeathEntryCount reads an x-death count. RabbitMQ sends it as a long (int64
// in amqp091-go); the narrower ints are accepted for safety.
func xDeathEntryCount(v any) int {
	switch n := v.(type) {
	case int64:
		return int(n)
	case int32:
		return int(n)
	case int:
		return n
	}
	return 0
}
