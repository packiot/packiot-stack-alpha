// Unit tests for the outbox package. Uses SQLite :memory: for speed, though
// individual tests also cover the on-disk path for durability semantics.

package outbox

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// memStore is the common test fixture. :memory: is per-connection in
// SQLite so tests get a clean database each time without cleanup.
func memStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(Config{Path: ":memory:", Capacity: 100})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func msg(topic, tenant, body string) Message {
	return Message{
		Topic:   topic,
		Tenant:  tenant,
		Payload: []byte(body),
	}
}

// ── Basic lifecycle ─────────────────────────────────────────────────────────

func TestEnqueueAssignsID(t *testing.T) {
	s := memStore(t)
	id1, err := s.Enqueue(context.Background(), msg("spBv1.0/CPACK/NDATA/e", "cpack", "a"))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if id1 == 0 {
		t.Errorf("id should be assigned; got %d", id1)
	}
	id2, err := s.Enqueue(context.Background(), msg("spBv1.0/CPACK/NDATA/e", "cpack", "b"))
	if err != nil {
		t.Fatalf("enqueue 2: %v", err)
	}
	if id2 <= id1 {
		t.Errorf("id should increase; got %d then %d", id1, id2)
	}
}

func TestEnqueueSetsEnqueuedAtIfZero(t *testing.T) {
	s := memStore(t)
	before := time.Now().UTC().Add(-time.Second)
	_, err := s.Enqueue(context.Background(), msg("t", "c", "x"))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	after := time.Now().UTC().Add(time.Second)

	batch, err := s.Peek(context.Background(), 1)
	if err != nil {
		t.Fatalf("peek: %v", err)
	}
	got := batch[0].EnqueuedAt
	if got.Before(before) || got.After(after) {
		t.Errorf("EnqueuedAt not within [%v, %v]: got %v", before, after, got)
	}
}

func TestPeekReturnsErrEmptyWhenEmpty(t *testing.T) {
	s := memStore(t)
	_, err := s.Peek(context.Background(), 10)
	if !errors.Is(err, ErrOutboxEmpty) {
		t.Errorf("want ErrOutboxEmpty, got %v", err)
	}
}

func TestPeekReturnsFIFOOrder(t *testing.T) {
	s := memStore(t)
	for _, body := range []string{"first", "second", "third"} {
		if _, err := s.Enqueue(context.Background(), msg("t", "c", body)); err != nil {
			t.Fatalf("enqueue: %v", err)
		}
	}
	batch, err := s.Peek(context.Background(), 10)
	if err != nil {
		t.Fatalf("peek: %v", err)
	}
	if len(batch) != 3 {
		t.Fatalf("batch size: got %d, want 3", len(batch))
	}
	for i, want := range []string{"first", "second", "third"} {
		if string(batch[i].Payload) != want {
			t.Errorf("batch[%d]: got %q, want %q", i, batch[i].Payload, want)
		}
	}
}

func TestPeekBatchSizeLimits(t *testing.T) {
	s := memStore(t)
	for i := 0; i < 5; i++ {
		s.Enqueue(context.Background(), msg("t", "c", "x"))
	}
	batch, err := s.Peek(context.Background(), 3)
	if err != nil {
		t.Fatalf("peek: %v", err)
	}
	if len(batch) != 3 {
		t.Errorf("batchSize=3 should return 3, got %d", len(batch))
	}
}

func TestDeleteRemovesFromOutbox(t *testing.T) {
	s := memStore(t)
	id, _ := s.Enqueue(context.Background(), msg("t", "c", "x"))
	if err := s.Delete(context.Background(), id); err != nil {
		t.Fatalf("delete: %v", err)
	}
	depth, _ := s.Depth(context.Background())
	if depth != 0 {
		t.Errorf("depth after delete: got %d, want 0", depth)
	}
}

func TestDeleteMissingReturnsError(t *testing.T) {
	s := memStore(t)
	err := s.Delete(context.Background(), 999)
	if err == nil {
		t.Error("delete of missing row should error")
	}
}

// ── Capacity + FIFO drop-oldest overflow policy ─────────────────────────────

func TestCapacityDropsOldest(t *testing.T) {
	s, err := Open(Config{Path: ":memory:", Capacity: 3})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close()

	for _, body := range []string{"a", "b", "c", "d", "e"} {
		if _, err := s.Enqueue(context.Background(), msg("t", "c", body)); err != nil {
			t.Fatalf("enqueue %s: %v", body, err)
		}
	}
	depth, _ := s.Depth(context.Background())
	if depth != 3 {
		t.Errorf("depth: got %d, want 3 (capacity cap)", depth)
	}
	batch, _ := s.Peek(context.Background(), 10)
	// FIFO drop-oldest means "c", "d", "e" survive (first 2 dropped)
	got := []string{string(batch[0].Payload), string(batch[1].Payload), string(batch[2].Payload)}
	want := []string{"c", "d", "e"}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("post-overflow batch: got %v, want %v", got, want)
			break
		}
	}
}

// ── Retry / backoff scheduling ──────────────────────────────────────────────

func TestMarkAttemptHidesFromPeekUntilBackoffElapses(t *testing.T) {
	s := memStore(t)
	id, _ := s.Enqueue(context.Background(), msg("t", "c", "x"))

	// Mark 1s backoff — Peek should now return empty
	if err := s.MarkAttempt(context.Background(), id, 1*time.Second); err != nil {
		t.Fatalf("mark attempt: %v", err)
	}
	if _, err := s.Peek(context.Background(), 10); !errors.Is(err, ErrOutboxEmpty) {
		t.Errorf("Peek right after MarkAttempt should be empty (backoff not elapsed), got err=%v", err)
	}

	// Depth still reports the row — Depth counts all rows, not just ready ones
	depth, _ := s.Depth(context.Background())
	if depth != 1 {
		t.Errorf("depth after mark: got %d, want 1", depth)
	}
}

func TestMarkAttemptIncrementsAttemptsCounter(t *testing.T) {
	s := memStore(t)
	id, _ := s.Enqueue(context.Background(), msg("t", "c", "x"))

	// Use zero backoff so Peek returns immediately
	for i := 1; i <= 3; i++ {
		if err := s.MarkAttempt(context.Background(), id, 0); err != nil {
			t.Fatalf("mark attempt %d: %v", i, err)
		}
	}
	batch, err := s.Peek(context.Background(), 10)
	if err != nil {
		t.Fatalf("peek: %v", err)
	}
	if batch[0].Attempts != 3 {
		t.Errorf("Attempts: got %d, want 3", batch[0].Attempts)
	}
}

// ── Diagnostic surfaces (Depth / OldestAge) ─────────────────────────────────

func TestOldestAgeEmptyIsZero(t *testing.T) {
	s := memStore(t)
	age, err := s.OldestAge(context.Background())
	if err != nil {
		t.Fatalf("oldest age: %v", err)
	}
	if age != 0 {
		t.Errorf("empty oldest age: got %v, want 0", age)
	}
}

func TestOldestAgeTracksEnqueueOrder(t *testing.T) {
	s := memStore(t)
	// Enqueue with EnqueuedAt in the past
	past := time.Now().Add(-5 * time.Second).UTC()
	_, err := s.Enqueue(context.Background(), Message{
		Topic:      "t",
		Tenant:     "c",
		Payload:    []byte("x"),
		EnqueuedAt: past,
	})
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	age, err := s.OldestAge(context.Background())
	if err != nil {
		t.Fatalf("oldest age: %v", err)
	}
	if age < 4*time.Second {
		t.Errorf("oldest age should be ~5s, got %v", age)
	}
}

// ── Concurrency correctness (race detector catches most issues) ─────────────

func TestConcurrentEnqueuesDoNotCorrupt(t *testing.T) {
	s := memStore(t)

	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			s.Enqueue(context.Background(), msg("t", "c", "x"))
		}(i)
	}
	wg.Wait()

	depth, _ := s.Depth(context.Background())
	if depth != 20 {
		t.Errorf("20 concurrent enqueues: got depth %d, want 20", depth)
	}
}

// ── Durability (real file) ──────────────────────────────────────────────────

func TestReopenPreservesData(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "outbox.sqlite")

	s, err := Open(Config{Path: path, Capacity: 10})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	id, err := s.Enqueue(context.Background(), msg("survive/restart", "c", "payload-x"))
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Simulate a crash + restart
	s2, err := Open(Config{Path: path, Capacity: 10})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer s2.Close()

	batch, err := s2.Peek(context.Background(), 10)
	if err != nil {
		t.Fatalf("post-restart peek: %v", err)
	}
	if len(batch) != 1 {
		t.Fatalf("post-restart batch size: got %d, want 1", len(batch))
	}
	if batch[0].ID != id {
		t.Errorf("ID drift across restart: got %d, want %d", batch[0].ID, id)
	}
	if batch[0].Topic != "survive/restart" {
		t.Errorf("Topic didn't survive restart: got %q", batch[0].Topic)
	}
	if string(batch[0].Payload) != "payload-x" {
		t.Errorf("Payload didn't survive restart: got %q", batch[0].Payload)
	}
}

// ── Config validation ──────────────────────────────────────────────────────

func TestOpenRejectsBadConfig(t *testing.T) {
	if _, err := Open(Config{Path: ""}); err == nil {
		t.Error("empty Path should reject")
	}
	if _, err := Open(Config{Path: "/dev/null/foo", Capacity: -1}); err == nil {
		t.Error("negative Capacity should reject")
	}
}

func TestOpenAppliesDefaultCapacity(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "defaults.sqlite")
	s, err := Open(Config{Path: path}) // Capacity=0 → default
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close()
	if s.cap != DefaultCapacity {
		t.Errorf("default Capacity: got %d, want %d", s.cap, DefaultCapacity)
	}
	// Also verify file was created
	if _, err := os.Stat(path); err != nil {
		t.Errorf("file should exist: %v", err)
	}
}
