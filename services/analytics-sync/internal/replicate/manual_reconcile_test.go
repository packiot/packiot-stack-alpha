package replicate

import (
	"database/sql"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 9, 8, 20, 23, 0, 0, time.UTC)

func ns(s string) sql.NullString  { return sql.NullString{String: s, Valid: true} }
func ni(n int64) sql.NullInt64    { return sql.NullInt64{Int64: n, Valid: true} }
func nt(t time.Time) sql.NullTime { return sql.NullTime{Time: t, Valid: true} }

func fields(cat string, dur int64, lu time.Time) manualFields {
	return manualFields{CdCategory: ns(cat), Duration: ni(dur), TsEnd: nt(lu.Add(-time.Minute)), LastUpdate: nt(lu)}
}

func leg(id int64, dstEq int, ts time.Time, f manualFields) legacyManual {
	return legacyManual{LegacyID: id, LegacyEquip: dstEq + 1000, DstEquip: dstEq, TsEvent: ts, F: f}
}

func linked(id int64, eq int, ts time.Time, f manualFields, legacyID int64) destManual {
	return destManual{ID: id, IDEquipment: eq, TsEvent: ts, F: f, Linked: true, LinkLegacyID: ni(legacyID)}
}

func seenOf(ws ...legacyManual) map[int64]bool {
	m := map[int64]bool{}
	for _, w := range ws {
		m[w.LegacyID] = true
	}
	return m
}

// Mapping: legacy equipment goes through the resolver; unresolved rows are
// dropped and counted, never written under a guessed id.
func TestResolveLegacyManualMapsAndCountsUnresolved(t *testing.T) {
	r := &Resolver{equip: map[int]StagingEquip{83: {IDEquipment: 1083, IDEnterprise: 3}}}
	in := []legacyManual{{LegacyID: 1, LegacyEquip: 83, TsEvent: t0}, {LegacyID: 2, LegacyEquip: 999, TsEvent: t0}}
	out, unresolved := resolveLegacyManual(in, r.ResolveEquipment)
	if unresolved != 1 || len(out) != 1 || out[0].DstEquip != 1083 || out[0].LegacyEquip != 83 {
		t.Fatalf("got out=%+v unresolved=%d", out, unresolved)
	}
}

// Duplicates on the analytics key: latest last_update wins; tie → highest id;
// NULL last_update is oldest. Losers are still "seen" (not deleted-in-legacy).
func TestDedupeLegacyManualDeterministic(t *testing.T) {
	lu := t0.Add(time.Hour)
	rows := []legacyManual{
		leg(10, 1, t0, fields("A", 600, lu)),
		leg(11, 1, t0, fields("B", 660, lu.Add(time.Second))), // later last_update
		leg(20, 2, t0, fields("C", 1, lu)),
		leg(21, 2, t0, fields("D", 1, lu)), // same last_update → higher id
		leg(30, 3, t0, manualFields{CdCategory: ns("E")}),
		leg(31, 3, t0, fields("F", 1, lu)), // NULL last_update loses
	}
	for pass := 0; pass < 2; pass++ { // input order must not matter
		w, seen := dedupeLegacyManual(rows)
		if len(w) != 3 || w[0].LegacyID != 11 || w[1].LegacyID != 21 || w[2].LegacyID != 31 {
			t.Fatalf("winners = %+v", w)
		}
		if len(seen) != 6 {
			t.Fatalf("seen = %v", seen)
		}
		for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
			rows[i], rows[j] = rows[j], rows[i]
		}
	}
}

// Missing in analytics → INSERT (which links in the same statement).
func TestPlanInsertsMissing(t *testing.T) {
	w := leg(7, 5, t0, fields("SET-01", 540, t0))
	p := planManual([]legacyManual{w}, seenOf(w), nil, nil, 50)
	if len(p.Inserts) != 1 || len(p.Updates)+len(p.Deletes)+len(p.Links) != 0 {
		t.Fatalf("plan = %+v", p)
	}
}

// Idempotency: analytics already equal + linked → empty plan.
func TestPlanIdempotent(t *testing.T) {
	f := fields("SET-01", 540, t0)
	w := leg(7, 5, t0, f)
	dest := []destManual{linked(100, 5, t0, f, 7)}
	if p := planManual([]legacyManual{w}, seenOf(w), dest, nil, 50); !p.empty() {
		t.Fatalf("expected empty plan, got %+v", p)
	}
}

// Edit propagation, same key: any column differing → UPDATE of all columns.
// An unlinked row on the key is ADOPTED (linked) — it is that legacy event.
func TestPlanUpdatesEditedAndAdoptsUnlinked(t *testing.T) {
	w := leg(7, 5, t0, fields("SET-02", 600, t0.Add(time.Hour)))
	dest := []destManual{{ID: 100, IDEquipment: 5, TsEvent: t0, F: fields("SET-01", 540, t0)}}
	p := planManual([]legacyManual{w}, seenOf(w), dest, nil, 50)
	if len(p.Updates) != 1 || p.Updates[0].ID != 100 || p.Updates[0].Move {
		t.Fatalf("updates = %+v", p.Updates)
	}
	if len(p.Links) != 1 || p.Links[0] != (manualLink{ID: 100, LegacyID: 7}) {
		t.Fatalf("links = %+v", p.Links)
	}
	if len(p.Inserts)+len(p.Deletes) != 0 {
		t.Fatalf("plan = %+v", p)
	}
}

// Edit propagation, START TIME moved (FLEXO 09-08 20:23 → 20:28): the owned
// row is moved in place (same analytics id), not duplicated.
func TestPlanMovesEditedStartTime(t *testing.T) {
	moved := t0.Add(5 * time.Minute)
	w := leg(170710, 5, moved, fields("SET-01", 540, t0.Add(time.Hour)))
	dest := []destManual{linked(1283, 5, t0, fields("SET-01", 840, t0), 170710)}
	p := planManual([]legacyManual{w}, seenOf(w), dest, nil, 50)
	if len(p.Updates) != 1 || !p.Updates[0].Move || p.Updates[0].ID != 1283 || !p.Updates[0].OldTs.Equal(t0) {
		t.Fatalf("updates = %+v", p.Updates)
	}
	if len(p.Inserts)+len(p.Deletes) != 0 {
		t.Fatalf("plan = %+v", p)
	}
	days := p.touchedDays()
	if len(days) != 1 || !days[0].Equal(time.Date(2026, 9, 8, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("touched days = %v", days)
	}
}

// Same move, but the NEW key already holds a row (e.g. the old replay handler
// inserted it): update/adopt that one, delete the stale owned row.
func TestPlanMoveOntoExistingKeyDeletesStale(t *testing.T) {
	moved := t0.Add(5 * time.Minute)
	f := fields("SET-01", 540, t0.Add(time.Hour))
	w := leg(170710, 5, moved, f)
	dest := []destManual{
		linked(1283, 5, t0, fields("SET-01", 840, t0), 170710),
		{ID: 1300, IDEquipment: 5, TsEvent: moved, F: f},
	}
	p := planManual([]legacyManual{w}, seenOf(w), dest, nil, 50)
	if len(p.Deletes) != 1 || p.Deletes[0].ID != 1283 {
		t.Fatalf("deletes = %+v", p.Deletes)
	}
	if len(p.Links) != 1 || p.Links[0].ID != 1300 || len(p.Updates) != 0 || len(p.Inserts) != 0 {
		t.Fatalf("plan = %+v", p)
	}
}

// Legacy duplicates: the analytics row mirrors the loser → overwritten with
// the winner and re-linked; nothing inserted, nothing deleted.
func TestPlanDuplicateWinnerReplacesLoserMirror(t *testing.T) {
	lu := t0.Add(time.Hour)
	loser := leg(169912, 5, t0, fields("MAN-05", 600, lu))
	winner := leg(169913, 5, t0, fields("MAN-05", 660, lu.Add(time.Second)))
	ws, seen := dedupeLegacyManual([]legacyManual{loser, winner})
	dest := []destManual{linked(900, 5, t0, loser.F, 169912)}
	p := planManual(ws, seen, dest, nil, 50)
	if len(p.Updates) != 1 || p.Updates[0].W.LegacyID != 169913 {
		t.Fatalf("updates = %+v", p.Updates)
	}
	if len(p.Links) != 1 || p.Links[0].LegacyID != 169913 || len(p.Deletes)+len(p.Inserts) != 0 {
		t.Fatalf("plan = %+v", p)
	}
}

// Delete safety: only LINKED rows are deleted; unlinked (new-stack authored)
// rows are never touched even when legacy has nothing at their key.
func TestPlanDeletesOnlyOwnedRows(t *testing.T) {
	keep := leg(1, 5, t0, fields("A", 1, t0))
	dest := []destManual{
		linked(10, 5, t0, keep.F, 1),
		linked(11, 5, t0.Add(time.Hour), fields("B", 1, t0), 2),                         // gone from legacy
		{ID: 12, IDEquipment: 5, TsEvent: t0.Add(2 * time.Hour), F: fields("C", 1, t0)}, // operator/edge-api row
		{ID: 13, IDEquipment: 5, TsEvent: t0.Add(3 * time.Hour), Linked: true},          // seeded orphan (legacy id NULL)
	}
	p := planManual([]legacyManual{keep}, seenOf(keep), dest, nil, 50)
	got := map[int64]bool{}
	for _, d := range p.Deletes {
		got[d.ID] = true
	}
	if len(got) != 2 || !got[11] || !got[13] || got[12] {
		t.Fatalf("deletes = %+v", p.Deletes)
	}
	if p.Foreign != 1 {
		t.Fatalf("foreign = %d, want 1", p.Foreign)
	}
}

// A linked row whose legacy row still exists OUTSIDE the window (start moved
// before the lookback) is kept — absence from the window is not deletion.
func TestPlanKeepsLegacyAliveOutsideWindow(t *testing.T) {
	anchor := leg(1, 5, t0, fields("A", 1, t0))
	dest := []destManual{linked(10, 5, t0, anchor.F, 1), linked(11, 5, t0.Add(time.Hour), fields("B", 1, t0), 2)}
	p := planManual([]legacyManual{anchor}, seenOf(anchor), dest, map[int64]bool{2: true}, 50)
	if len(p.Deletes) != 0 || p.Kept != 1 {
		t.Fatalf("plan = %+v", p)
	}
}

// Guards: an empty legacy window, or more deletes than the cap, skips ALL
// deletes (inserts/updates still apply).
func TestPlanDeleteGuards(t *testing.T) {
	dest := []destManual{linked(10, 5, t0, fields("A", 1, t0), 1), linked(11, 5, t0.Add(time.Hour), fields("B", 1, t0), 2)}
	if p := planManual(nil, map[int64]bool{}, dest, nil, 50); len(p.Deletes) != 0 || p.DeleteGuard == "" || p.PlannedDelete != 2 {
		t.Fatalf("empty-window guard: %+v", p)
	}
	w := leg(3, 6, t0, fields("C", 1, t0))
	p := planManual([]legacyManual{w}, seenOf(w), dest, nil, 1)
	if len(p.Deletes) != 0 || p.DeleteGuard == "" || len(p.Inserts) != 1 {
		t.Fatalf("cap guard: %+v", p)
	}
}

func TestDayRangesMergeContiguous(t *testing.T) {
	d := func(day int) time.Time { return time.Date(2026, 9, day, 0, 0, 0, 0, time.UTC) }
	got := dayRanges([]time.Time{d(1), d(2), d(3), d(8), d(10), d(11)})
	want := [][2]time.Time{{d(1), d(4)}, {d(8), d(9)}, {d(10), d(12)}}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if !got[i][0].Equal(want[i][0]) || !got[i][1].Equal(want[i][1]) {
			t.Fatalf("range %d = %v, want %v", i, got[i], want[i])
		}
	}
}

// SQL contract: schema-qualified silver (the #261 regression), IDENTITY never
// copied, upsert keyed on (id_equipment, ts_event), deletes re-check ownership.
func TestManualReconcileSQLContract(t *testing.T) {
	for name, q := range map[string]string{
		"insert": sqlManualInsert, "update": sqlManualUpdate, "delete": sqlManualDelete,
		"destFetch": sqlManualDestFetch, "prune": sqlManualPruneLinks,
		"handlerInsert": sqlInsertManualEvent, "handlerUpdate": sqlUpdateManualEvent,
	} {
		if strings.Contains(q, "public.") || !strings.Contains(q, "silver.equipment_events_man") {
			t.Errorf("%s must target silver.equipment_events_man:\n%s", name, q)
		}
	}
	if !strings.Contains(sqlManualInsert, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("insert must be keyed on (id_equipment, ts_event)")
	}
	cols := sqlManualInsert[:strings.Index(sqlManualInsert, "VALUES")]
	if strings.Contains(cols, "id_equipment_event") {
		t.Errorf("insert must not carry id_equipment_event (IDENTITY):\n%s", cols)
	}
	if !strings.Contains(sqlManualDelete, "ops.legacy_manual_event_link") {
		t.Errorf("delete must require a provenance link")
	}
	// 20 mirrored fields + eq + ts + id.
	p := manualPlan{Updates: []manualUpdate{{ID: 1, W: leg(1, 1, t0, manualFields{})}}, Inserts: []legacyManual{leg(2, 1, t0, manualFields{})}}
	for _, s := range p.statements(3) {
		switch s.Kind {
		case "update", "move":
			if len(s.Args) != 23 {
				t.Errorf("update args = %d, want 23", len(s.Args))
			}
		case "insert":
			if len(s.Args) != 24 {
				t.Errorf("insert args = %d, want 24", len(s.Args))
			}
		}
	}
}
