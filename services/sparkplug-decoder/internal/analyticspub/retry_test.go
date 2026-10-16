package analyticspub

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

func TestNewWithRetry_SucceedsWhenBrokerComesUp(t *testing.T) {
	calls := 0
	want := &Publisher{}
	p, err := newWithRetry(context.Background(), func() (*Publisher, error) {
		calls++
		if calls < 3 {
			return nil, errors.New("dial tcp: lookup rabbitmq: no such host")
		}
		return want, nil
	}, quiet, time.Second, time.Millisecond, 5*time.Millisecond)
	if err != nil || p != want || calls != 3 {
		t.Fatalf("got p=%v err=%v calls=%d, want the publisher on the 3rd attempt", p, err, calls)
	}
}

func TestNewWithRetry_GivesUpAfterMaxWait(t *testing.T) {
	start := time.Now()
	_, err := newWithRetry(context.Background(), func() (*Publisher, error) {
		return nil, errors.New("connection refused")
	}, quiet, 50*time.Millisecond, 5*time.Millisecond, 10*time.Millisecond)
	if err == nil {
		t.Fatal("expected an error once maxWait elapsed")
	}
	if el := time.Since(start); el > time.Second {
		t.Fatalf("took %s, should stop near maxWait", el)
	}
}

func TestNewWithRetry_StopsOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := newWithRetry(ctx, func() (*Publisher, error) {
		return nil, errors.New("connection refused")
	}, quiet, time.Hour, 50*time.Millisecond, time.Second)
	if err == nil {
		t.Fatal("expected cancellation error")
	}
}
