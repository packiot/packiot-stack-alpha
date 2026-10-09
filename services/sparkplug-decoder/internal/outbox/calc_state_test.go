package outbox

import (
	"context"
	"path/filepath"
	"testing"
)

// The Calc baselines must survive a process restart (reopen of the same file)
// and be committed atomically with the envelopes in the same EnqueueBatch.
func TestEnqueueBatchPersistsStateAcrossReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "outbox.db")
	s, err := Open(Config{Path: path, Capacity: 100})
	if err != nil {
		t.Fatal(err)
	}
	ids, err := s.EnqueueBatch(ctx,
		[]Message{msg("t", "x", "a"), msg("t", "x", "b")},
		[]StateRow{{Kind: "int", Key: "L1/M1/Admin/ProdConsumedCount/1/Unit", Int: 1026}, {Kind: "float", Key: "L1/M1/Status/MachSpeed", Float: 65.5}})
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 2 || ids[0] == ids[1] {
		t.Fatalf("ids = %v, want 2 distinct", ids)
	}
	// Upsert: a later checkpoint overwrites the same key.
	if _, err := s.EnqueueBatch(ctx, nil, []StateRow{{Kind: "int", Key: "L1/M1/Admin/ProdConsumedCount/1/Unit", Int: 1042}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(Config{Path: path, Capacity: 100})
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	rows, err := s2.LoadState(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]StateRow{}
	for _, r := range rows {
		got[r.Kind+"|"+r.Key] = r
	}
	if len(got) != 2 || got["int|L1/M1/Admin/ProdConsumedCount/1/Unit"].Int != 1042 || got["float|L1/M1/Status/MachSpeed"].Float != 65.5 {
		t.Fatalf("restored state = %+v", rows)
	}
	if d, _ := s2.Depth(ctx); d != 2 {
		t.Fatalf("depth after reopen = %d, want 2", d)
	}
}

// A failed transaction must leave NEITHER the envelopes NOR the baselines —
// otherwise a restart could restore a baseline whose delta was never emitted.
func TestEnqueueBatchIsAtomic(t *testing.T) {
	ctx := context.Background()
	s := memStore(t)
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := s.EnqueueBatch(cctx, []Message{msg("t", "x", "a")}, []StateRow{{Kind: "int", Key: "k", Int: 7}}); err == nil {
		t.Fatal("want error on cancelled ctx")
	}
	if d, _ := s.Depth(ctx); d != 0 {
		t.Fatalf("depth = %d, want 0", d)
	}
	if rows, _ := s.LoadState(ctx); len(rows) != 0 {
		t.Fatalf("state = %+v, want none", rows)
	}
}

func TestEnqueueStillSingleMessage(t *testing.T) {
	s := memStore(t)
	id, err := s.Enqueue(context.Background(), msg("t", "x", "a"))
	if err != nil || id <= 0 {
		t.Fatalf("Enqueue = %d, %v", id, err)
	}
}
