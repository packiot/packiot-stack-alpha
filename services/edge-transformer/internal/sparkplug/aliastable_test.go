// Unit tests for the alias-table state machine.

package sparkplug

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// cpackKey is a convenience key used across most tests to save keystrokes.
var cpackKey = PublisherKey{
	GroupID:    "CPACK",
	EdgeNodeID: "edge-01",
}

// ── BIRTH → DATA happy path ──────────────────────────────────────────────────

func TestBirthEstablishesAliases(t *testing.T) {
	store := NewStateStore()

	birth := &Payload{
		Timestamp: ptr(uint64(1000)),
		Seq:       ptr(uint64(0)),
		Metrics: []*Metric{
			{Name: ptr("temp"), Alias: ptr(uint64(1)), Datatype: ptr(uint32(DataType_Int64.Number()))},
			{Name: ptr("pressure"), Alias: ptr(uint64(2)), Datatype: ptr(uint32(DataType_Float.Number()))},
		},
	}

	res, err := store.Ingest(cpackKey, MsgTypeNBirth, birth)
	if err != nil {
		t.Fatalf("birth: %v", err)
	}
	if res != nil {
		t.Errorf("BIRTH should return nil ResolvedPayload; got %+v", res)
	}
	if store.Len() != 1 {
		t.Errorf("Len: got %d, want 1", store.Len())
	}
}

func TestDataResolvesAliases(t *testing.T) {
	store := NewStateStore()

	// Establish table via BIRTH
	birth := &Payload{
		Timestamp: ptr(uint64(1000)),
		Seq:       ptr(uint64(0)),
		Metrics: []*Metric{
			{Name: ptr("temp"), Alias: ptr(uint64(1)), Datatype: ptr(uint32(DataType_Int64.Number()))},
			{Name: ptr("pressure"), Alias: ptr(uint64(2)), Datatype: ptr(uint32(DataType_Float.Number()))},
		},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// Send DATA with alias-only metrics
	data := &Payload{
		Timestamp: ptr(uint64(1005)),
		Seq:       ptr(uint64(1)),
		Metrics: []*Metric{
			{Alias: ptr(uint64(1)), Timestamp: ptr(uint64(1005)),
				Value: &Metric_LongValue{LongValue: 42}},
			{Alias: ptr(uint64(2)), Timestamp: ptr(uint64(1005)),
				Value: &Metric_FloatValue{FloatValue: 3.14}},
		},
	}
	res, err := store.Ingest(cpackKey, MsgTypeNData, data)
	if err != nil {
		t.Fatalf("data: %v", err)
	}
	if res == nil {
		t.Fatal("DATA should return ResolvedPayload; got nil")
	}
	if len(res.Metrics) != 2 {
		t.Fatalf("metric count: got %d, want 2", len(res.Metrics))
	}

	// Verify resolution
	if res.Metrics[0].Name != "temp" {
		t.Errorf("metric[0].Name: got %q, want %q", res.Metrics[0].Name, "temp")
	}
	if res.Metrics[0].Value != uint64(42) {
		t.Errorf("metric[0].Value: got %v, want 42", res.Metrics[0].Value)
	}
	if res.Metrics[1].Name != "pressure" {
		t.Errorf("metric[1].Name: got %q, want %q", res.Metrics[1].Name, "pressure")
	}
	if res.Metrics[1].Value != float32(3.14) {
		t.Errorf("metric[1].Value: got %v, want 3.14", res.Metrics[1].Value)
	}
}

// ── Error cases ──────────────────────────────────────────────────────────────

func TestDataBeforeBirthFails(t *testing.T) {
	store := NewStateStore()
	data := &Payload{
		Seq:     ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}},
	}
	_, err := store.Ingest(cpackKey, MsgTypeNData, data)
	if !errors.Is(err, ErrNoBirth) {
		t.Errorf("want ErrNoBirth, got %v", err)
	}
}

func TestDataUnknownAliasFails(t *testing.T) {
	store := NewStateStore()
	// Birth with alias 1 only
	birth := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// Data references alias 99 — not in table
	data := &Payload{
		Seq:     ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(99))}},
	}
	_, err := store.Ingest(cpackKey, MsgTypeNData, data)
	var unknownErr ErrUnknownAlias
	if !errors.As(err, &unknownErr) {
		t.Fatalf("want ErrUnknownAlias, got %v", err)
	}
	if unknownErr.Alias != 99 {
		t.Errorf("ErrUnknownAlias.Alias: got %d, want 99", unknownErr.Alias)
	}
	if unknownErr.PublisherKey != cpackKey {
		t.Errorf("ErrUnknownAlias.PublisherKey: got %v, want %v", unknownErr.PublisherKey, cpackKey)
	}
	if !strings.Contains(err.Error(), "99") {
		t.Errorf("error message should mention alias 99; got %q", err.Error())
	}
}

func TestUnknownMessageTypeFails(t *testing.T) {
	store := NewStateStore()
	_, err := store.Ingest(cpackKey, "WEIRD", &Payload{})
	if !errors.Is(err, ErrUnknownMessageType) {
		t.Errorf("want ErrUnknownMessageType, got %v", err)
	}
}

// ── DEATH invalidation ───────────────────────────────────────────────────────

func TestDeathInvalidates(t *testing.T) {
	store := NewStateStore()

	// Birth → Data works
	birth := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// Death
	_, err := store.Ingest(cpackKey, MsgTypeNDeath, &Payload{})
	if err != nil {
		t.Fatalf("death: %v", err)
	}
	if store.Len() != 0 {
		t.Errorf("Len after death: got %d, want 0", store.Len())
	}

	// Data now fails with ErrNoBirth
	data := &Payload{Seq: ptr(uint64(2)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}}}
	_, err = store.Ingest(cpackKey, MsgTypeNData, data)
	if !errors.Is(err, ErrNoBirth) {
		t.Errorf("data after death: want ErrNoBirth, got %v", err)
	}
}

// ── Rebirth replaces prior table ─────────────────────────────────────────────

func TestBirthRefreshesTable(t *testing.T) {
	store := NewStateStore()

	// First BIRTH: alias 1 → "temp"
	first := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, first); err != nil {
		t.Fatalf("first birth: %v", err)
	}

	// Second BIRTH: alias 1 → "humidity" (different metric)
	second := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("humidity"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, second); err != nil {
		t.Fatalf("second birth: %v", err)
	}

	// DATA resolves alias 1 to "humidity" — the new name
	data := &Payload{
		Seq:     ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(1)), Value: &Metric_LongValue{LongValue: 55}}},
	}
	res, err := store.Ingest(cpackKey, MsgTypeNData, data)
	if err != nil {
		t.Fatalf("data: %v", err)
	}
	if res.Metrics[0].Name != "humidity" {
		t.Errorf("rebirth didn't refresh: got %q, want %q", res.Metrics[0].Name, "humidity")
	}
}

// ── Sequence number gap detection ────────────────────────────────────────────

func TestSequenceGapFiresCallback(t *testing.T) {
	store := NewStateStore()

	var gaps []gapEvent
	store.OnSeqGap(func(key PublisherKey, expected, got uint64) {
		gaps = append(gaps, gapEvent{key: key, expected: expected, got: got})
	})

	birth := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// DATA seq=5 — expected 1
	data := &Payload{Seq: ptr(uint64(5)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}}}
	if _, err := store.Ingest(cpackKey, MsgTypeNData, data); err != nil {
		t.Fatalf("data: %v", err)
	}
	if len(gaps) != 1 {
		t.Fatalf("expected 1 gap, got %d", len(gaps))
	}
	if gaps[0].expected != 1 || gaps[0].got != 5 {
		t.Errorf("gap event: got expected=%d got=%d, want expected=1 got=5",
			gaps[0].expected, gaps[0].got)
	}
}

func TestSequenceWraparoundIsNotAGap(t *testing.T) {
	store := NewStateStore()

	var gaps []gapEvent
	store.OnSeqGap(func(key PublisherKey, expected, got uint64) {
		gaps = append(gaps, gapEvent{key: key, expected: expected, got: got})
	})

	birth := &Payload{
		Seq:     ptr(uint64(255)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// DATA seq=0 (255 wraps to 0) — should NOT fire the gap callback
	data := &Payload{Seq: ptr(uint64(0)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}}}
	if _, err := store.Ingest(cpackKey, MsgTypeNData, data); err != nil {
		t.Fatalf("data: %v", err)
	}
	if len(gaps) != 0 {
		t.Errorf("wraparound should not be a gap, got %d gaps", len(gaps))
	}
}

type gapEvent struct {
	key      PublisherKey
	expected uint64
	got      uint64
}

// ── Datatype fallback from BIRTH ─────────────────────────────────────────────

func TestDatatypeFallbackFromBirth(t *testing.T) {
	store := NewStateStore()

	// BIRTH establishes alias 1 as Int64
	birth := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1)),
			Datatype: ptr(uint32(DataType_Int64.Number()))}},
	}
	if _, err := store.Ingest(cpackKey, MsgTypeNBirth, birth); err != nil {
		t.Fatalf("birth: %v", err)
	}

	// DATA omits datatype — should fall back to the BIRTH-established value
	data := &Payload{Seq: ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(1)),
			Value: &Metric_LongValue{LongValue: 42}}}}
	res, err := store.Ingest(cpackKey, MsgTypeNData, data)
	if err != nil {
		t.Fatalf("data: %v", err)
	}
	if got := res.Metrics[0].Datatype; got != uint32(DataType_Int64.Number()) {
		t.Errorf("datatype fallback: got %d, want %d", got, DataType_Int64.Number())
	}
}

// ── Multi-publisher isolation ────────────────────────────────────────────────

func TestPublishersAreIsolated(t *testing.T) {
	store := NewStateStore()

	// Two different edge nodes, both use alias 1 for different metrics
	edgeA := PublisherKey{GroupID: "CPACK", EdgeNodeID: "edge-A"}
	edgeB := PublisherKey{GroupID: "CPACK", EdgeNodeID: "edge-B"}

	birthA := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp-A"), Alias: ptr(uint64(1))}},
	}
	birthB := &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp-B"), Alias: ptr(uint64(1))}},
	}
	store.Ingest(edgeA, MsgTypeNBirth, birthA)
	store.Ingest(edgeB, MsgTypeNBirth, birthB)

	dataA, _ := store.Ingest(edgeA, MsgTypeNData, &Payload{
		Seq:     ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}},
	})
	dataB, _ := store.Ingest(edgeB, MsgTypeNData, &Payload{
		Seq:     ptr(uint64(1)),
		Metrics: []*Metric{{Alias: ptr(uint64(1))}},
	})
	if dataA.Metrics[0].Name != "temp-A" {
		t.Errorf("edgeA leaked: got %q", dataA.Metrics[0].Name)
	}
	if dataB.Metrics[0].Name != "temp-B" {
		t.Errorf("edgeB leaked: got %q", dataB.Metrics[0].Name)
	}
}

// ── Concurrent access safety (race detector catches issues) ──────────────────

func TestConcurrentPublishers(t *testing.T) {
	store := NewStateStore()
	const nPublishers = 20
	const nDataMsgs = 100

	var wg sync.WaitGroup
	wg.Add(nPublishers)
	for i := 0; i < nPublishers; i++ {
		go func(id int) {
			defer wg.Done()
			key := PublisherKey{
				GroupID:    "concurrent",
				EdgeNodeID: fmt.Sprint("node-", id),
			}
			birth := &Payload{
				Seq:     ptr(uint64(0)),
				Metrics: []*Metric{{Name: ptr("m"), Alias: ptr(uint64(1))}},
			}
			store.Ingest(key, MsgTypeNBirth, birth)
			for j := 0; j < nDataMsgs; j++ {
				data := &Payload{
					Seq:     ptr(uint64((j + 1) & 0xff)),
					Metrics: []*Metric{{Alias: ptr(uint64(1))}},
				}
				store.Ingest(key, MsgTypeNData, data)
			}
		}(i)
	}
	wg.Wait()
	if store.Len() != nPublishers {
		t.Errorf("Len: got %d, want %d", store.Len(), nPublishers)
	}
}

// ── Diagnostic surface (/health integration) ─────────────────────────────────

func TestSnapshotShape(t *testing.T) {
	store := NewStateStore()
	store.Ingest(cpackKey, MsgTypeNBirth, &Payload{
		Seq: ptr(uint64(0)),
		Metrics: []*Metric{
			{Name: ptr("a"), Alias: ptr(uint64(1))},
			{Name: ptr("b"), Alias: ptr(uint64(2))},
		},
	})

	snaps := store.Snapshot()
	if len(snaps) != 1 {
		t.Fatalf("snapshots: got %d, want 1", len(snaps))
	}
	s := snaps[0]
	if s.Key != "CPACK/edge-01" {
		t.Errorf("Key: got %q, want %q", s.Key, "CPACK/edge-01")
	}
	if s.AliasCount != 2 {
		t.Errorf("AliasCount: got %d, want 2", s.AliasCount)
	}
	if s.LastBirthAt == "" {
		t.Errorf("LastBirthAt should be set after birth")
	}
}

func TestResetRemovesPublisher(t *testing.T) {
	store := NewStateStore()
	store.Ingest(cpackKey, MsgTypeNBirth, &Payload{
		Seq:     ptr(uint64(0)),
		Metrics: []*Metric{{Name: ptr("temp"), Alias: ptr(uint64(1))}},
	})
	if store.Len() != 1 {
		t.Fatalf("prep: Len should be 1")
	}
	store.Reset(cpackKey)
	if store.Len() != 0 {
		t.Errorf("after Reset: got Len %d, want 0", store.Len())
	}
}
