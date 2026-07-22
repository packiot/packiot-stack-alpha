package main

import (
	"context"
	"net/http"
	"testing"
)

// fakeTx is an in-memory scanTx: it lets applyScan's gapless logic be tested
// with no database. It is deliberately a faithful mini-model of the real SQL —
// a UNIQUE scan_uuid store, a per-PO last_label_seq + total, and a tenant
// ownership map — so the tests exercise the ACTUAL decision logic, not a stub.
type fakeTx struct {
	existing  map[string]ScanResult // scan_uuid → row (idempotency store)
	last      map[int64]int64       // id_po → last_label_seq
	total     map[int64]int64       // id_po → total_qty
	ownsPO    map[int64]int         // id_po → owning enterprise
	ownsEquip map[int]int           // id_equipment → owning enterprise
	inserts   int                   // how many rows were actually written
	nextBox   int64
}

func newFakeTx() *fakeTx {
	return &fakeTx{
		existing:  map[string]ScanResult{},
		last:      map[int64]int64{},
		total:     map[int64]int64{},
		ownsPO:    map[int64]int{},
		ownsEquip: map[int]int{},
		nextBox:   1000,
	}
}

func (f *fakeTx) existingByUUID(_ context.Context, uuid string) (ScanResult, bool, error) {
	r, ok := f.existing[uuid]
	return r, ok, nil
}

func (f *fakeTx) tenantOwns(_ context.Context, ent int, idPO int64, idEquip int) (bool, error) {
	return f.ownsPO[idPO] == ent && f.ownsEquip[idEquip] == ent, nil
}

func (f *fakeTx) lastLabelSeq(_ context.Context, idPO int64) (int64, error) {
	return f.last[idPO], nil
}

func (f *fakeTx) insertScan(_ context.Context, _ int, req ScanRequest, labelSeq *int64, counterSeq, delta int64) (int64, int64, error) {
	f.inserts++
	box := f.nextBox
	f.nextBox++
	f.last[req.IDProductionOrder] = counterSeq
	f.total[req.IDProductionOrder] += delta
	res := ScanResult{BoxScanID: box, Total: f.total[req.IDProductionOrder], ScanUUID: req.ScanUUID}
	if labelSeq != nil {
		res.LabelSeq = *labelSeq
	}
	f.existing[req.ScanUUID] = res // model the UNIQUE(scan_uuid) row now being present
	return box, f.total[req.IDProductionOrder], nil
}

// seed makes enterprise `ent` own PO `idPO` and equipment `idEquip`.
func (f *fakeTx) seed(ent int, idPO int64, idEquip int) {
	f.ownsPO[idPO] = ent
	f.ownsEquip[idEquip] = ent
}

const (
	testEnt   = 7
	testPO    = int64(4242)
	testEquip = 55
)

func prodReq(uuid string, mode string) ScanRequest {
	return ScanRequest{ScanUUID: uuid, IDProductionOrder: testPO, IDEquipment: testEquip,
		Qty: 1, ScanType: scanTypeProduction, Mode: mode}
}

// ASSIGN allocates last+1 and advances monotonically.
func TestAssign_ReturnsLastPlusOne(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip)

	res, derr, err := applyScan(ctx, tx, testEnt, prodReq("u1", modeAssign))
	if err != nil || derr != nil {
		t.Fatalf("first assign: derr=%v err=%v", derr, err)
	}
	if res.LabelSeq != 1 {
		t.Fatalf("first label_seq = %d, want 1", res.LabelSeq)
	}
	if res.Total != 1 {
		t.Fatalf("first total = %d, want 1", res.Total)
	}

	res2, derr, err := applyScan(ctx, tx, testEnt, prodReq("u2", modeAssign))
	if err != nil || derr != nil {
		t.Fatalf("second assign: derr=%v err=%v", derr, err)
	}
	if res2.LabelSeq != 2 {
		t.Fatalf("second label_seq = %d, want 2 (gapless)", res2.LabelSeq)
	}
	if tx.inserts != 2 {
		t.Fatalf("inserts = %d, want 2", tx.inserts)
	}
}

// VALIDATE accepts exactly last+1.
func TestValidate_AcceptsNext(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip)

	req := prodReq("v1", modeValidate)
	one := int64(1)
	req.LabelSeq = &one
	res, derr, err := applyScan(ctx, tx, testEnt, req)
	if err != nil || derr != nil {
		t.Fatalf("validate next: derr=%v err=%v", derr, err)
	}
	if res.LabelSeq != 1 {
		t.Fatalf("label_seq = %d, want 1", res.LabelSeq)
	}
}

// VALIDATE rejects a gap with a clean 409 {expected, got} and writes nothing.
func TestValidate_RejectsGap(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip)

	req := prodReq("v-gap", modeValidate)
	three := int64(3) // last is 0, so next is 1 — 3 is a gap
	req.LabelSeq = &three
	res, derr, err := applyScan(ctx, tx, testEnt, req)
	if err != nil {
		t.Fatalf("unexpected infra err: %v", err)
	}
	if derr == nil {
		t.Fatalf("expected a domain error for the gap, got accept: %+v", res)
	}
	if derr.Status != http.StatusConflict || derr.Code != "label_seq_gap" {
		t.Fatalf("domain error = %+v, want 409 label_seq_gap", derr)
	}
	if derr.Expected != 1 || derr.Got != 3 {
		t.Fatalf("gap error = {expected:%d got:%d}, want {1 3}", derr.Expected, derr.Got)
	}
	if tx.inserts != 0 {
		t.Fatalf("a rejected validate wrote %d rows, want 0", tx.inserts)
	}
}

// A replay of an accepted scan_uuid returns the ORIGINAL row and writes nothing.
func TestIdempotent_ReplayReturnsOriginal(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip)

	first, derr, err := applyScan(ctx, tx, testEnt, prodReq("dup", modeAssign))
	if err != nil || derr != nil {
		t.Fatalf("first: derr=%v err=%v", derr, err)
	}
	insertsAfterFirst := tx.inserts

	replay, derr, err := applyScan(ctx, tx, testEnt, prodReq("dup", modeAssign))
	if err != nil || derr != nil {
		t.Fatalf("replay: derr=%v err=%v", derr, err)
	}
	if !replay.Replayed {
		t.Fatalf("replay.Replayed = false, want true")
	}
	if replay.BoxScanID != first.BoxScanID || replay.LabelSeq != first.LabelSeq {
		t.Fatalf("replay row = %+v, want original %+v", replay, first)
	}
	if tx.inserts != insertsAfterFirst {
		t.Fatalf("replay caused a second insert (%d → %d)", insertsAfterFirst, tx.inserts)
	}
}

// A scan for another tenant's PO/equipment is rejected 403 and writes nothing.
func TestTenantMismatch_Rejected(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip) // owned by testEnt

	_, derr, err := applyScan(ctx, tx, testEnt+1 /* different tenant */, prodReq("x", modeAssign))
	if err != nil {
		t.Fatalf("unexpected infra err: %v", err)
	}
	if derr == nil || derr.Status != http.StatusForbidden || derr.Code != "tenant_mismatch" {
		t.Fatalf("domain error = %+v, want 403 tenant_mismatch", derr)
	}
	if tx.inserts != 0 {
		t.Fatalf("cross-tenant scan wrote %d rows, want 0", tx.inserts)
	}
}

// Non-production scans are recorded without consuming the label sequence.
func TestNonProduction_NoLabelSeq(t *testing.T) {
	ctx := context.Background()
	tx := newFakeTx()
	tx.seed(testEnt, testPO, testEquip)

	// advance the production sequence to 1 first
	if _, _, err := applyScan(ctx, tx, testEnt, prodReq("p1", modeAssign)); err != nil {
		t.Fatal(err)
	}
	sample := ScanRequest{ScanUUID: "s1", IDProductionOrder: testPO, IDEquipment: testEquip,
		Qty: 1, ScanType: "sample", Mode: modeAssign}
	res, derr, err := applyScan(ctx, tx, testEnt, sample)
	if err != nil || derr != nil {
		t.Fatalf("sample: derr=%v err=%v", derr, err)
	}
	if res.LabelSeq != 0 {
		t.Fatalf("sample label_seq = %d, want 0 (does not consume sequence)", res.LabelSeq)
	}
	if got := tx.last[testPO]; got != 1 {
		t.Fatalf("production high-water = %d, want 1 (sample must not bump it)", got)
	}
}

// validateScanRequest normalizes defaults and rejects malformed bodies.
func TestValidateScanRequest(t *testing.T) {
	// defaults applied
	r := ScanRequest{ScanUUID: "a", IDProductionOrder: 1, IDEquipment: 1}
	if derr := validateScanRequest(&r); derr != nil {
		t.Fatalf("valid minimal req rejected: %+v", derr)
	}
	if r.ScanType != scanTypeProduction || r.Mode != modeAssign || r.Qty != 1 {
		t.Fatalf("defaults not applied: %+v", r)
	}
	// missing uuid
	bad := ScanRequest{IDProductionOrder: 1, IDEquipment: 1}
	if derr := validateScanRequest(&bad); derr == nil || derr.Code != "scan_uuid_required" {
		t.Fatalf("missing uuid not rejected: %+v", derr)
	}
	// bad scan_type
	bt := ScanRequest{ScanUUID: "a", IDProductionOrder: 1, IDEquipment: 1, ScanType: "bogus"}
	if derr := validateScanRequest(&bt); derr == nil || derr.Code != "scan_type_invalid" {
		t.Fatalf("bad scan_type not rejected: %+v", derr)
	}
}
