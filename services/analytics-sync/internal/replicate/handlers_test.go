package replicate

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// Every PO lifecycle write must target the natural key (id_enterprise,
// id_order) — never the legacy surrogate id_production_order, which lives
// in a different id space than the staging rows (bug-248 discipline,
// doubly so across instances).
func TestPOWritesTargetNaturalKey(t *testing.T) {
	updates := map[string]string{
		"sqlUpdatePOStart":   sqlUpdatePOStart,
		"sqlUpdatePOStop":    sqlUpdatePOStop,
		"sqlUpdatePOTsStart": sqlUpdatePOTsStart,
		"sqlUpdatePORecalc":  sqlUpdatePORecalc,
		"sqlClosePOChanged":  sqlClosePOChanged,
	}
	for name, sql := range updates {
		if !strings.Contains(sql, "id_enterprise = $") || !strings.Contains(sql, "id_order = $") {
			t.Errorf("%s: must key on (id_enterprise, id_order):\n%s", name, sql)
		}
		if strings.Contains(sql, "id_production_order = ") {
			t.Errorf("%s: must not key on the legacy surrogate id_production_order:\n%s", name, sql)
		}
	}
	inserts := map[string]string{"sqlInsertPOAvailable": sqlInsertPOAvailable, "sqlInsertPORunning": sqlInsertPORunning}
	for name, sql := range inserts {
		if !strings.Contains(sql, "ON CONFLICT (id_enterprise, id_order) DO NOTHING") {
			t.Errorf("%s: must be idempotent on (id_enterprise, id_order):\n%s", name, sql)
		}
	}
}

// The staging equipment_events_man PK is a serial IDENTITY — the insert must
// NOT carry id_equipment_event (copying the legacy serial would collide with
// staging's sequence). Idempotency comes from the ts_event unique key.
func TestManualInsertOmitsSerialAndIsIdempotent(t *testing.T) {
	if strings.Contains(sqlInsertManualEvent, "id_equipment_event") {
		t.Errorf("sqlInsertManualEvent must not set id_equipment_event (staging serial):\n%s", sqlInsertManualEvent)
	}
	if !strings.Contains(sqlInsertManualEvent, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("sqlInsertManualEvent must be idempotent on ts_event:\n%s", sqlInsertManualEvent)
	}
}

func TestEquipmentEventIdempotentOnNaturalKey(t *testing.T) {
	if !strings.Contains(sqlInsertEquipmentEvent, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("sqlInsertEquipmentEvent must be idempotent on (id_equipment, ts_event):\n%s", sqlInsertEquipmentEvent)
	}
	if !strings.Contains(sqlUpdateEventClassification, "id_equipment = $") || !strings.Contains(sqlUpdateEventClassification, "ts_event = $") {
		t.Errorf("event classification must key on (id_equipment, ts_event):\n%s", sqlUpdateEventClassification)
	}
}

// Legacy payloads mix number and quoted-string numerics in the same field.
func TestFlexInt64ParsesLegacyForms(t *testing.T) {
	var p struct {
		A flexInt64 `json:"a"`
		B flexInt64 `json:"b"`
		C flexInt64 `json:"c"`
		D flexInt64 `json:"d"`
	}
	if err := json.Unmarshal([]byte(`{"a":"895241","b":895641,"c":"56602","d":null}`), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.A != 895241 || p.B != 895641 || p.C != 56602 || p.D != 0 {
		t.Errorf("flexInt64 mismatch: %+v", p)
	}
}

// Real order-changed payload sampled from legacy (numbers-as-strings).
func TestOrderChangedDecodesLegacyPayload(t *testing.T) {
	raw := `{"idArea":53,"idSite":1,"idOrder":895641,"stopType":"finish",
	  "timestamp":"2026-08-21T17:36:00-03:00","idEquipment":556,"idEnterprise":1,
	  "shouldCreatePo":false,"shouldOpenNewPo":true,"idProductionOrder":1681207,
	  "oldIdProductionOrder":1681206,"productionOrderQuantity":18000,
	  "oldProductionOrderProdFinal":"56602"}`
	var p orderChangedPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.OldIDProductionOrder != 1681206 || p.IDEquipment != 556 || p.OldProductionOrderProdFinal != 56602 {
		t.Errorf("decoded wrong: %+v", p)
	}
}

// Split segments are AUTO events: they must land in equipment_events (forced),
// never equipment_events_man — matching legacy edge-api downtimes-dao.ts::split.
// This is the residual-#3 divergence (92 forced twin manual rows vs ~20 genuine
// legacy manual events) that this handler now closes.
func TestSplitTargetsEquipmentEventsNotManual(t *testing.T) {
	if !strings.Contains(sqlInsertSplitSegment, "INSERT INTO silver.equipment_events (") {
		t.Errorf("split segments must insert into equipment_events (auto), not _man:\n%s", sqlInsertSplitSegment)
	}
	if strings.Contains(sqlInsertSplitSegment, "equipment_events_man") {
		t.Errorf("split segments must NOT touch equipment_events_man:\n%s", sqlInsertSplitSegment)
	}
	if !strings.Contains(sqlInsertSplitSegment, "ON CONFLICT (id_equipment, ts_event) DO NOTHING") {
		t.Errorf("split segment insert must be idempotent on the PK:\n%s", sqlInsertSplitSegment)
	}
	if !strings.Contains(sqlInsertSplitSegment, "forced_creation_system, last_update)") {
		t.Errorf("split segments must be forced auto events:\n%s", sqlInsertSplitSegment)
	}
	if !strings.Contains(sqlSplitShrinkOriginal, "UPDATE silver.equipment_events") ||
		!strings.Contains(sqlSplitShrinkOriginal, "id_equipment = $11 AND ts_event = $12") {
		t.Errorf("segment-0 shrink must update equipment_events by (id_equipment, ts_event):\n%s", sqlSplitShrinkOriginal)
	}
}

// The interval-overlap matcher must (a) require a status match, (b) bound the
// staging start by maxDriftSec, (c) rank by overlap desc — the mirror-worker-go
// shape that prevents a stale open event from "overlapping" everything.
func TestOverlapMatcherSQLShape(t *testing.T) {
	// Rebuild the literal used inside findTwinEventByOverlap to assert its shape.
	// (Kept in sync by this test; the query is inline in the function.)
	want := []string{"status = $5", "ORDER BY overlap_seconds DESC",
		"ts_event >= $3::timestamptz - ($6::int * interval '1 second')",
		"(ts_end IS NULL OR ts_end > $3::timestamptz)"}
	src := sqlOverlapMatch
	for _, w := range want {
		if !strings.Contains(src, w) {
			t.Errorf("overlap matcher SQL missing %q", w)
		}
	}
}

// The real legacy event-splitted payload carries idEquipmentEvent (the original
// base event) + per-segment idle — both previously dropped by the twin handler.
func TestEventSplittedDecodesOriginalAndIdle(t *testing.T) {
	raw := `{"events":[
	  {"idle":"no","note":"","type":"downtime","endTime":"2026-08-27T03:52:00.000Z","startTime":"2026-08-27T03:00:00.000Z","changeOver":false,"machineCode":"FLEXO","categoryCode":"SET-01","descCategory":"Setup","descSubcategory":"S02","plannedDowntime":false,"subcategoryCode":"S02"},
	  {"idle":"no","note":"","type":"downtime","endTime":"2026-08-27T04:13:00.000Z","startTime":"2026-08-27T03:52:00.000Z","changeOver":false,"machineCode":"FLEXO","categoryCode":"SET-01","descCategory":"Setup","descSubcategory":"S02","plannedDowntime":false,"subcategoryCode":"S02"}],
	  "eventType":"downtime","idEquipment":556,"idEquipmentEvent":2451583778}`
	var p eventSplittedPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if p.IDEquipmentEvent != 2451583778 || p.IDEquipment != 556 || len(p.Events) != 2 {
		t.Fatalf("decoded wrong: %+v", p)
	}
	if p.Events[0].Idle != "no" || p.Events[0].StartTime != "2026-08-27T03:00:00.000Z" {
		t.Errorf("segment 0 decoded wrong: %+v", p.Events[0])
	}
}

// ─── DLQ replay regression: overlap-safe runtime-window open (bug-XXXX) ───
//
// Sep-9 prod DLQ: 1,374 rows failed the exclusion constraint
// production_orders_runtime_id_equipment_runtime_timerange (1,369×) plus 5×
// the production_orders_ts_start_ts_end check. Root cause: the batch replayed
// order events NON-CHRONOLOGICALLY, so openRuntimeWindow tried to insert a
// [ts, ∞) window for an equipment that ALREADY had a CLOSED window [t0, t1)
// containing ts. The old sqlOpenWindow guard only skipped when the SAME po had
// an OPEN window (upper IS NULL); it ignored closed windows and other POs, so
// [ts, ∞) overlapped [t0, t1) and the constraint aborted the event → DLQ.
//
// gold's exclusion constraint forbids overlapping runtime_timerange per
// id_equipment. PostgreSQL tstzrange is HALF-OPEN: [lo, hi) includes lo,
// excludes hi. tsRange models exactly that so we can reproduce the constraint
// and prove the fix without a live Postgres (the package has no DB harness).

// tsRange is a half-open [lo, hi) tstzrange. hiOpen==true means upper is NULL
// (the window is still running → [lo, ∞)).
type tsRange struct {
	lo     time.Time
	hi     time.Time
	hiOpen bool // true ⇒ upper is unbounded (NULL)
}

// overlaps mirrors PostgreSQL's `&&` operator on tstzrange with half-open
// [lo, hi) bounds: two ranges overlap iff each starts strictly before the
// other ends. An unbounded upper (hiOpen) is treated as +∞.
func (r tsRange) overlaps(o tsRange) bool {
	startsBeforeOtherEnds := o.hiOpen || r.lo.Before(o.hi)
	otherStartsBeforeThisEnds := r.hiOpen || o.lo.Before(r.hi)
	return startsBeforeOtherEnds && otherStartsBeforeThisEnds
}

// openWindowGuard models the WHERE ... NOT EXISTS (... x.runtime_timerange &&
// tstzrange($ts, NULL)) clause of sqlOpenWindow: the [ts, ∞) window may be
// inserted only when it overlaps NO existing window for the equipment.
// Returns true when the insert proceeds, false when it is skipped (no-op).
func openWindowGuard(existing []tsRange, ts time.Time) bool {
	candidate := tsRange{lo: ts, hiOpen: true} // [ts, ∞)
	for _, w := range existing {
		if w.overlaps(candidate) {
			return false // would violate the exclusion constraint → skip
		}
	}
	return true
}

// TestOpenRuntimeWindowOverlapSafeReplay is the golden regression for the
// Sep-9 DLQ batch. An equipment already carries a CLOSED window [t0, t1);
// an order-started / order-changed event then arrives (out of order) with a
// ts INSIDE [t0, t1). It asserts:
//   - the constraint IS violated by a naive [ts, ∞) insert (reproduces the bug),
//   - the shipped guard SKIPS the insert (proves the fix — clean no-op, no DLQ),
//   - and the real sqlOpenWindow carries the equipment-scoped `&&` overlap guard
//     (so the model tracks the actual query).
func TestOpenRuntimeWindowOverlapSafeReplay(t *testing.T) {
	t0 := time.Date(2026, 9, 9, 6, 0, 0, 0, time.UTC)
	t1 := time.Date(2026, 9, 9, 14, 0, 0, 0, time.UTC)
	closed := tsRange{lo: t0, hi: t1} // an existing CLOSED window on the equipment
	ts := time.Date(2026, 9, 9, 10, 0, 0, 0, time.UTC) // out-of-order start INSIDE [t0, t1)

	// (a) Reproduce the bug: a naive [ts, ∞) insert overlaps the closed window.
	candidate := tsRange{lo: ts, hiOpen: true}
	if !closed.overlaps(candidate) {
		t.Fatal("precondition: [ts, ∞) must overlap the closed [t0, t1) — else the scenario is wrong")
	}

	// (b) Prove the fix: the guard skips the insert (idempotent no-op, no error).
	if openWindowGuard([]tsRange{closed}, ts) {
		t.Error("fix broken: guard allowed an overlapping [ts, ∞) insert → would DLQ on the exclusion constraint")
	}

	// (c) Forward (chronological) order must still open the window. After
	// sqlCloseWindowsForEquipment turns the prior open window into [t0, ts),
	// it is ADJACENT to — not overlapping — the new [ts, ∞).
	priorClosedAtTs := tsRange{lo: t0, hi: ts}
	if !openWindowGuard([]tsRange{priorClosedAtTs}, ts) {
		t.Error("regression: adjacent [t0, ts) must NOT block opening [ts, ∞) — half-open ranges do not overlap at the shared bound")
	}

	// (d) Idempotency: re-replaying a start for an equipment whose window is
	// already open [ts, ∞) is a no-op (two unbounded ranges always overlap).
	alreadyOpen := tsRange{lo: ts, hiOpen: true}
	if openWindowGuard([]tsRange{alreadyOpen}, ts) {
		t.Error("idempotency broken: re-opening an already-open window must be skipped, not duplicated")
	}

	// (e) The real query must carry the equipment-scoped overlap guard, so the
	// model above reflects the shipped fix rather than drifting from it.
	for _, want := range []string{
		"x.id_equipment = po.id_equipment",
		"x.runtime_timerange && tstzrange($3, NULL)",
	} {
		if !strings.Contains(sqlOpenWindow, want) {
			t.Errorf("sqlOpenWindow missing overlap guard %q:\n%s", want, sqlOpenWindow)
		}
	}
	// It must NOT have reverted to the old open-only, per-PO guard.
	if strings.Contains(sqlOpenWindow, "upper(x.runtime_timerange) IS NULL") {
		t.Errorf("sqlOpenWindow still uses the old open-only guard — closed windows would DLQ again:\n%s", sqlOpenWindow)
	}
}

// TestStopGuardsAgainstInvertedRange covers the 5× production_orders_ts_start_ts_end
// check failures: an out-of-order stop whose ts precedes ts_start must NOT
// write an inverted [ts_start, ts_end] range. Both PO-closing statements carry
// the `ts_start IS NULL OR ts_start <= $2` guard so the UPDATE matches zero
// rows (skip + observable no-op) instead of tripping the check and DLQ'ing.
func TestStopGuardsAgainstInvertedRange(t *testing.T) {
	for name, sql := range map[string]string{
		"sqlUpdatePOStop":   sqlUpdatePOStop,
		"sqlClosePOChanged": sqlClosePOChanged,
	} {
		if !strings.Contains(sql, "ts_start IS NULL OR ts_start <= $2") {
			t.Errorf("%s: missing inverted-range guard (ts_start IS NULL OR ts_start <= $2):\n%s", name, sql)
		}
	}

	// Model the check semantics: a stop only writes ts_end when ts_start<=ts_end.
	stopWrites := func(tsStart *time.Time, tsEnd time.Time) bool {
		return tsStart == nil || !tsStart.After(tsEnd)
	}
	start := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	// Out-of-order stop BEFORE the start → must be skipped (no inverted range).
	if stopWrites(&start, start.Add(-time.Hour)) {
		t.Error("inverted stop (ts_end < ts_start) must be skipped, not written")
	}
	// Normal stop after the start → written.
	if !stopWrites(&start, start.Add(time.Hour)) {
		t.Error("normal stop (ts_end > ts_start) must be written")
	}
	// PO never started (ts_start NULL) → check passes, stop is written.
	if !stopWrites(nil, start) {
		t.Error("stop on a never-started PO (ts_start NULL) must be written")
	}
}

// downtime-event-created carries epoch-ms timestamps and legacy idEquipment.
func TestDowntimeEventDecodesEpochMillis(t *testing.T) {
	raw := `{"events":[{"topic":"C-PACK/SC/LINHAS/L5/TEXA/Status/StateCurrent","status":6,"timestamp":1787345520000,"idEquipment":65}]}`
	var p downtimeEventCreatedPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(p.Events) != 1 || p.Events[0].IDEquipment != 65 || p.Events[0].Timestamp != 1787345520000 || *p.Events[0].Status != 6 {
		t.Errorf("decoded wrong: %+v", p)
	}
}
