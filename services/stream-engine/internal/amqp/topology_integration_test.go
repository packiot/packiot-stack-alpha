package amqp

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"os"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

// TestRetryAndFailedAreNotDuplicated runs against a real broker (skipped unless AMQP_TEST_URL is
// set, e.g. amqp://guest:guest@127.0.0.1:5672/). It starts from the broker state older releases
// left behind (legacy retry/failed queues bound with `#`), declares the topology, then nacks a
// tenant message the way the consumer does and checks it is dead-lettered exactly once.
func TestRetryAndFailedAreNotDuplicated(t *testing.T) {
	url := os.Getenv("AMQP_TEST_URL")
	if url == "" {
		t.Skip("AMQP_TEST_URL not set")
	}
	conn, err := amqp.Dial(url)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ch, err := conn.Channel()
	if err != nil {
		t.Fatal(err)
	}
	defer ch.Close()

	p := fmt.Sprintf("t%06d", rand.Intn(1_000_000))
	cfg := &config.Config{
		SourceExchange: p + "-oee", RetryExchange: p + "-oee-retry", FailedExchange: p + "-oee-failed",
		WorkerQueue: p + "-sq", RetryQueue: p + "-sq-retry-30s", FailedQueue: p + "-sq-failed",
		RetryTTLMs: 600000, MaxRetries: 3,
	}
	tenant := "cpack"
	tenantQ, tenantRetryQ, tenantFailedQ := cfg.WorkerQueue+"-"+tenant, cfg.WorkerQueue+"-"+tenant+"-retry-30s", cfg.WorkerQueue+"-"+tenant+"-failed"
	t.Cleanup(func() {
		for _, q := range []string{cfg.WorkerQueue, cfg.RetryQueue, cfg.FailedQueue, tenantQ, tenantRetryQ, tenantFailedQ} {
			_, _ = ch.QueueDelete(q, false, false, false)
		}
		for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
			_ = ch.ExchangeDelete(ex, false, false)
		}
	})

	// Broker state left by older releases: legacy retry/failed queues with a `#` catch-all.
	for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
		must(t, ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil))
	}
	_, err = ch.QueueDeclare(cfg.RetryQueue, true, false, false, false, amqp.Table{
		"x-message-ttl": int32(cfg.RetryTTLMs), "x-dead-letter-exchange": cfg.SourceExchange})
	must(t, err)
	must(t, ch.QueueBind(cfg.RetryQueue, "#", cfg.RetryExchange, false, nil))
	_, err = ch.QueueDeclare(cfg.FailedQueue, true, false, false, false, nil)
	must(t, err)
	must(t, ch.QueueBind(cfg.FailedQueue, "#", cfg.FailedExchange, false, nil))

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	must(t, DeclareTopology(context.Background(), conn, cfg, []string{tenant}, logger))

	// Retry path: publish a tenant message, consume it, nack without requeue → DLX to the retry exchange.
	publish(t, ch, cfg.SourceExchange, "sparkplug.data."+tenant)
	waitCount(t, ch, tenantQ, 1)
	d, ok, err := ch.Get(tenantQ, false)
	if err != nil || !ok {
		t.Fatalf("get from %s: ok=%v err=%v", tenantQ, ok, err)
	}
	must(t, d.Nack(false, false))
	waitCount(t, ch, tenantRetryQ, 1)
	time.Sleep(300 * time.Millisecond) // give a duplicate time to arrive
	assertCount(t, ch, tenantRetryQ, 1)
	assertCount(t, ch, cfg.RetryQueue, 0) // the bug: was 1 (second copy via `#`)

	// Failed path: the consumer republishes a terminal failure with the original routing key.
	publish(t, ch, cfg.FailedExchange, "sparkplug.data."+tenant)
	waitCount(t, ch, tenantFailedQ, 1)
	time.Sleep(300 * time.Millisecond)
	assertCount(t, ch, cfg.FailedQueue, 0)

	// Legacy traffic still reaches the legacy retry/failed queues.
	publish(t, ch, cfg.RetryExchange, "sparkplug.data")
	publish(t, ch, cfg.FailedExchange, "sparkplug.data")
	waitCount(t, ch, cfg.RetryQueue, 1)
	waitCount(t, ch, cfg.FailedQueue, 1)
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func publish(t *testing.T, ch *amqp.Channel, exchange, key string) {
	t.Helper()
	must(t, ch.PublishWithContext(context.Background(), exchange, key, false, false, amqp.Publishing{Body: []byte("x")}))
}

func count(t *testing.T, ch *amqp.Channel, q string) int {
	t.Helper()
	st, err := ch.QueueDeclarePassive(q, true, false, false, false, nil)
	must(t, err)
	return st.Messages
}

func waitCount(t *testing.T, ch *amqp.Channel, q string, want int) {
	t.Helper()
	for i := 0; i < 50; i++ {
		if count(t, ch, q) == want {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s: want %d messages, have %d", q, want, count(t, ch, q))
}

func assertCount(t *testing.T, ch *amqp.Channel, q string, want int) {
	t.Helper()
	if got := count(t, ch, q); got != want {
		t.Fatalf("%s: want %d messages, have %d", q, want, got)
	}
}
