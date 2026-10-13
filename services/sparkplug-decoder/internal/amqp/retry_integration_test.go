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

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/config"
	amqp "github.com/rabbitmq/amqp091-go"
)

// The tests below drive a real broker (skipped unless AMQP_TEST_URL is set, e.g.
// amqp://guest:guest@127.0.0.1:5672/) through this service's own topology with a short retry TTL
// and a handler that always fails, using the consumers' own decision (RetryCount +
// RetriesExhausted on the broker-written x-death header). MAX_RETRIES=N must give exactly N+1
// handler runs, then one message in the tenant's failed queue.

func brokerChannel(t *testing.T) *amqp.Channel {
	t.Helper()
	url := os.Getenv("AMQP_TEST_URL")
	if url == "" {
		t.Skip("AMQP_TEST_URL not set")
	}
	conn, err := amqp.Dial(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	ch, err := conn.Channel()
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

// TestIngestMaxRetriesAgainstBroker: classic queues, DeclareTopology (plc.normalized ingest path).
func TestIngestMaxRetriesAgainstBroker(t *testing.T) {
	ch := brokerChannel(t)
	p := fmt.Sprintf("t%06d", rand.Intn(1_000_000))
	cfg := &config.Config{
		SourceExchange: p + "-src", RetryExchange: p + "-src-retry", FailedExchange: p + "-src-failed",
		WorkerQueue: p + "-q", RetryQueue: p + "-q-retry-30s", FailedQueue: p + "-q-failed",
		RetryTTLMs: 100, MaxRetries: 3,
	}
	tenant := "cpack"
	mainQ, retryQ, failedQ := cfg.WorkerQueue+"-"+tenant, cfg.WorkerQueue+"-"+tenant+"-retry-30s", cfg.WorkerQueue+"-"+tenant+"-failed"
	t.Cleanup(func() {
		for _, q := range []string{cfg.WorkerQueue, cfg.RetryQueue, cfg.FailedQueue, mainQ, retryQ, failedQ} {
			_, _ = ch.QueueDelete(q, false, false, false)
		}
		for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
			_ = ch.ExchangeDelete(ex, false, false)
		}
		ch.Close()
	})
	// Broker state older releases left: legacy retry/failed queues bound with `#`, which doubled
	// every tenant retry (1+2+4+8 handler runs for MAX_RETRIES=3). DeclareTopology must unbind them.
	for _, ex := range []string{cfg.SourceExchange, cfg.RetryExchange, cfg.FailedExchange} {
		if err := ch.ExchangeDeclare(ex, "topic", true, false, false, false, nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ch.QueueDeclare(cfg.RetryQueue, true, false, false, false, amqp.Table{
		"x-message-ttl": int32(cfg.RetryTTLMs), "x-dead-letter-exchange": cfg.SourceExchange}); err != nil {
		t.Fatal(err)
	}
	if err := ch.QueueBind(cfg.RetryQueue, "#", cfg.RetryExchange, false, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := ch.QueueDeclare(cfg.FailedQueue, true, false, false, false, nil); err != nil {
		t.Fatal(err)
	}
	if err := ch.QueueBind(cfg.FailedQueue, "#", cfg.FailedExchange, false, nil); err != nil {
		t.Fatal(err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := DeclareTopology(context.Background(), ch, cfg, []string{tenant}, logger); err != nil {
		t.Fatal(err)
	}
	// Twice: the unbind must be idempotent on an already-clean broker.
	if err := DeclareTopology(context.Background(), ch, cfg, []string{tenant}, logger); err != nil {
		t.Fatal(err)
	}
	runFailingHandler(t, ch, cfg.SourceExchange, cfg.SourceExchange+"."+tenant, cfg.FailedExchange, mainQ, retryQ, failedQ, cfg.MaxRetries)
	waitCount(t, ch, cfg.RetryQueue, 0)
	waitCount(t, ch, cfg.FailedQueue, 0)
}

// TestCommandMaxRetriesAgainstBroker: quorum queues, DeclareCommandTopology (edge.commands path).
func TestCommandMaxRetriesAgainstBroker(t *testing.T) {
	ch := brokerChannel(t)
	p := fmt.Sprintf("t%06d", rand.Intn(1_000_000))
	cfg := &config.Config{
		CommandsExchange: p + "-cmd", CommandsRetryExchange: p + "-cmd-retry", CommandsFailedExchange: p + "-cmd-failed",
		CommandsQueuePrefix: p + "-cmd", RetryTTLMs: 100, MaxRetries: 2,
	}
	tenant := "cpack"
	mainQ, retryQ, failedQ, ackQ := CommandQueueNames(cfg, tenant)
	t.Cleanup(func() {
		for _, q := range []string{mainQ, retryQ, failedQ, ackQ} {
			_, _ = ch.QueueDelete(q, false, false, false)
		}
		for _, ex := range []string{cfg.CommandsExchange, cfg.CommandsRetryExchange, cfg.CommandsFailedExchange} {
			_ = ch.ExchangeDelete(ex, false, false)
		}
		ch.Close()
	})
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := DeclareCommandTopology(context.Background(), ch, cfg, []string{tenant}, logger); err != nil {
		t.Fatal(err)
	}
	runFailingHandler(t, ch, cfg.CommandsExchange, cfg.CommandsExchange+"."+tenant, cfg.CommandsFailedExchange, mainQ, retryQ, failedQ, cfg.MaxRetries)
}

func runFailingHandler(t *testing.T, ch *amqp.Channel, srcEx, routingKey, failedEx, mainQ, retryQ, failedQ string, maxRetries int) {
	t.Helper()
	ctx := context.Background()
	if err := ch.PublishWithContext(ctx, srcEx, routingKey, false, false, amqp.Publishing{Body: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	runs, parked := 0, false
	deadline := time.Now().Add(20 * time.Second)
	for !parked && time.Now().Before(deadline) {
		d, ok, err := ch.Get(mainQ, false)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		retries := RetryCount(d.Headers, mainQ)
		if RetriesExhausted(retries, maxRetries) {
			t.Logf("parked after %d failed runs; x-death: %v", retries, d.Headers["x-death"])
			if err := ch.PublishWithContext(ctx, failedEx, d.RoutingKey, false, false, amqp.Publishing{Body: d.Body}); err != nil {
				t.Fatal(err)
			}
			if err := d.Ack(false); err != nil {
				t.Fatal(err)
			}
			parked = true
			break
		}
		runs++ // the handler runs and fails
		if err := d.Nack(false, false); err != nil {
			t.Fatal(err)
		}
	}
	if !parked {
		t.Fatalf("never parked (ran %d times)", runs)
	}
	if want := maxRetries + 1; runs != want {
		t.Fatalf("handler ran %d times, want %d (1 + MAX_RETRIES=%d)", runs, want, maxRetries)
	}
	waitCount(t, ch, failedQ, 1)
	waitCount(t, ch, mainQ, 0)
	waitCount(t, ch, retryQ, 0)
}

func waitCount(t *testing.T, ch *amqp.Channel, q string, want int) {
	t.Helper()
	var got int
	for i := 0; i < 100; i++ {
		qi, err := ch.QueueDeclarePassive(q, true, false, false, false, nil)
		if err != nil {
			t.Fatalf("inspect %s: %v", q, err)
		}
		if got = qi.Messages; got == want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s: want %d messages, have %d", q, want, got)
}
