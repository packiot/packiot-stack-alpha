// scans.go — the load-bearing piece: durable box-scan ingest with a gapless,
// server-authoritative per-production-order label sequence.
//
// THE INVARIANT
// ─────────────
// For a given production order, the `production` label sequence is a dense,
// monotonic 1,2,3,… with NO gaps and NO duplicates, and that authority lives
// on the SERVER, not the scanner. Two properties make it hold under concurrency
// and retries:
//
//  1. SERIALIZED DECISION — every write for one PO runs inside a single
//     Postgres transaction that first takes pg_advisory_xact_lock(id_po). So
//     "read last_label_seq → decide next → insert → bump counter" is atomic
//     against every other writer for that same PO. No read-modify-write race
//     can interleave; the lock is xact-scoped so COMMIT/ROLLBACK releases it.
//
//  2. IDEMPOTENCY — scan_uuid is client-generated and UNIQUE. A network retry
//     of an already-accepted scan returns the ORIGINAL row (replayed=true) and
//     performs no second insert, so a flaky link can never double-count. The
//     UNIQUE constraint is the backstop even if the replay check races.
//
// TWO MODES
//   - assign:   the server allocates next = last+1 and writes it. The scanner
//     is dumb; the DB owns the number.
//   - validate: the scanner asserts a label_seq it already believes is next; the
//     server confirms label_seq == last+1 or returns a clean 409
//     {expected, got} domain error. This is the pre-serialized/"the
//     label was printed upstream" path.
//
// TENANT FENCE — the PO and equipment must belong to the JWT-derived
// id_enterprise, checked INSIDE the tx. A scan for another tenant's PO is a 403,
// never a silent cross-tenant write.
//
// PHASE-2 markers below show where the pharma pack slots in (GS1 element-string
// parsing, EPCIS event capture, serialization/genealogy) — none of it is here.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ScanRequest is the POST /v1/scans body. NOTE: it carries NO tenant field —
// id_enterprise is derived from the JWT server-side and is the ONLY tenant the
// write trusts. A tenant in the body would be ignored by construction.
type ScanRequest struct {
	ScanUUID          string `json:"scan_uuid"`           // client-generated idempotency key (UNIQUE)
	RawBarcode        string `json:"raw_barcode"`         // PHASE-2: parsed into GS1 element strings
	IDProductionOrder int64  `json:"id_production_order"` // the PO the scan belongs to
	IDEquipment       int    `json:"id_equipment"`        // the scanning station
	Qty               int    `json:"qty"`                 // units on the box (default 1)
	ScanType          string `json:"scan_type"`           // production | sample | void | reprint | rework
	Mode              string `json:"mode"`                // assign | validate (default assign)
	LabelSeq          *int64 `json:"label_seq,omitempty"` // required in validate mode
}

// ScanResult is the accepted-write response and the SSE event payload.
type ScanResult struct {
	BoxScanID int64  `json:"box_scan_id"`
	LabelSeq  int64  `json:"label_seq"` // 0 for non-production scans (they don't consume the sequence)
	Total     int64  `json:"total"`     // running counts_toward_total qty for the PO
	ScanUUID  string `json:"scan_uuid"`
	Replayed  bool   `json:"replayed"` // true ⇒ idempotent replay, no new row written
}

// domainError is an expected, client-facing rejection with a specific HTTP
// status and stable machine code (distinct from a 500 infra failure). The gap
// case carries expected/got so the scanner can self-correct.
type domainError struct {
	Status   int    `json:"-"`
	Code     string `json:"error"`
	Expected int64  `json:"expected,omitempty"`
	Got      int64  `json:"got,omitempty"`
}

const (
	scanTypeProduction = "production"
	modeAssign         = "assign"
	modeValidate       = "validate"
)

// validScanTypes mirrors the migration's CHECK constraint — validated in Go for
// a clean 400 before the tx, and enforced in the DB as the real guard.
var validScanTypes = map[string]bool{
	"production": true, "sample": true, "void": true, "reprint": true, "rework": true,
}

// scanTx is the per-transaction DB seam the gapless algorithm calls. It is an
// interface so applyScan can be unit-tested against an in-memory fake with NO
// database — the pg implementation (pgScanTx) runs the real SQL, already inside
// the advisory-locked transaction opened by pgScanStore.RecordScan.
type scanTx interface {
	existingByUUID(ctx context.Context, scanUUID string) (ScanResult, bool, error)
	tenantOwns(ctx context.Context, enterpriseID int, idPO int64, idEquip int) (bool, error)
	lastLabelSeq(ctx context.Context, idPO int64) (int64, error)
	insertScan(ctx context.Context, enterpriseID int, req ScanRequest, labelSeq *int64, counterSeq, delta int64) (boxScanID, total int64, err error)
}

// applyScan is the PURE gapless algorithm — no DB, no HTTP, no locks. It assumes
// its scanTx is already inside a per-PO advisory-locked transaction, so its
// read-decide-write is race-free. Returns exactly one of: a ScanResult (accept
// or replay), a *domainError (expected 4xx), or an error (infra 5xx).
func applyScan(ctx context.Context, tx scanTx, enterpriseID int, req ScanRequest) (ScanResult, *domainError, error) {
	// 1) Idempotent replay — a repeat of an accepted scan_uuid returns the
	//    original row with no second insert.
	if res, ok, err := tx.existingByUUID(ctx, req.ScanUUID); err != nil {
		return ScanResult{}, nil, err
	} else if ok {
		res.Replayed = true
		return res, nil, nil
	}

	// 2) Tenant fence — the PO and equipment must be this enterprise's.
	owns, err := tx.tenantOwns(ctx, enterpriseID, req.IDProductionOrder, req.IDEquipment)
	if err != nil {
		return ScanResult{}, nil, err
	}
	if !owns {
		return ScanResult{}, &domainError{Status: http.StatusForbidden, Code: "tenant_mismatch"}, nil
	}

	// 3) Gapless authority. Only `production` scans consume the label sequence;
	//    sample/void/reprint/rework are recorded without a label_seq and never
	//    bump the counter's high-water mark.
	last, err := tx.lastLabelSeq(ctx, req.IDProductionOrder)
	if err != nil {
		return ScanResult{}, nil, err
	}

	var storedLabelSeq *int64
	counterSeq := last // unchanged for non-production
	if req.ScanType == scanTypeProduction {
		next := last + 1
		switch req.Mode {
		case modeValidate:
			if req.LabelSeq == nil {
				return ScanResult{}, &domainError{Status: http.StatusBadRequest, Code: "label_seq_required"}, nil
			}
			if *req.LabelSeq != next {
				// The scanner's belief disagrees with the server's authority —
				// a gap (or a duplicate/behind). Clean 409 with the correction.
				return ScanResult{}, &domainError{
					Status: http.StatusConflict, Code: "label_seq_gap",
					Expected: next, Got: *req.LabelSeq,
				}, nil
			}
			storedLabelSeq = &next
		default: // assign
			storedLabelSeq = &next
		}
		counterSeq = *storedLabelSeq
	}

	// counts_toward_total is a SERVER decision from scan_type, never client
	// input: production units count; void/sample/reprint/rework do not (Phase-0).
	delta := int64(0)
	if req.ScanType == scanTypeProduction {
		delta = int64(req.Qty)
	}

	boxScanID, total, err := tx.insertScan(ctx, enterpriseID, req, storedLabelSeq, counterSeq, delta)
	if err != nil {
		return ScanResult{}, nil, err
	}
	res := ScanResult{BoxScanID: boxScanID, Total: total, ScanUUID: req.ScanUUID}
	if storedLabelSeq != nil {
		res.LabelSeq = *storedLabelSeq
	}
	return res, nil, nil
}

// ── pg implementation ────────────────────────────────────────────────────────

// scanStore is what the HTTP handler depends on. RecordScan owns the
// transaction boundary + advisory lock; applyScan owns the logic.
type scanStore interface {
	RecordScan(ctx context.Context, enterpriseID int, req ScanRequest) (ScanResult, *domainError, error)
}

type pgScanStore struct{ pool *pgxpool.Pool }

func newPgScanStore(pool *pgxpool.Pool) *pgScanStore { return &pgScanStore{pool: pool} }

// RecordScan opens the transaction, takes the per-PO advisory lock, runs the
// gapless algorithm, and commits only on a real accept. A replay or domain
// error rolls back (the deferred Rollback is a no-op after Commit).
func (s *pgScanStore) RecordScan(ctx context.Context, enterpriseID int, req ScanRequest) (ScanResult, *domainError, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ScanResult{}, nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Serialize all writers for this PO. Xact-scoped: released on COMMIT/ROLLBACK.
	// Key = id_production_order. PHASE-2: if another feature starts taking
	// advisory locks on the same integer space, namespace with the two-arg
	// (classid, objid) form so the keyspaces can't collide.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, req.IDProductionOrder); err != nil {
		return ScanResult{}, nil, err
	}

	res, derr, err := applyScan(ctx, &pgScanTx{tx: tx}, enterpriseID, req)
	if err != nil || derr != nil {
		return res, derr, err
	}
	if res.Replayed {
		return res, nil, nil // nothing written; no need to commit the empty tx
	}
	if err := tx.Commit(ctx); err != nil {
		return ScanResult{}, nil, err
	}
	return res, nil, nil
}

// pgScanTx binds the scanTx seam to a live pgx.Tx (already advisory-locked).
type pgScanTx struct{ tx pgx.Tx }

func (p *pgScanTx) existingByUUID(ctx context.Context, scanUUID string) (ScanResult, bool, error) {
	const q = `
		SELECT bs.box_scan_id, COALESCE(bs.label_seq, 0), COALESCE(c.total_qty, 0)
		  FROM box_scans bs
		  LEFT JOIN po_box_counter c ON c.id_production_order = bs.id_production_order
		 WHERE bs.scan_uuid = $1`
	var r ScanResult
	err := p.tx.QueryRow(ctx, q, scanUUID).Scan(&r.BoxScanID, &r.LabelSeq, &r.Total)
	if errors.Is(err, pgx.ErrNoRows) {
		return ScanResult{}, false, nil
	}
	if err != nil {
		return ScanResult{}, false, err
	}
	r.ScanUUID = scanUUID
	return r, true, nil
}

func (p *pgScanTx) tenantOwns(ctx context.Context, enterpriseID int, idPO int64, idEquip int) (bool, error) {
	const q = `
		SELECT EXISTS(SELECT 1 FROM production_orders WHERE id_production_order = $2 AND id_enterprise = $1)
		   AND EXISTS(SELECT 1 FROM equipments        WHERE id_equipment        = $3 AND id_enterprise = $1)`
	var ok bool
	if err := p.tx.QueryRow(ctx, q, enterpriseID, idPO, idEquip).Scan(&ok); err != nil {
		return false, err
	}
	return ok, nil
}

func (p *pgScanTx) lastLabelSeq(ctx context.Context, idPO int64) (int64, error) {
	var last int64
	err := p.tx.QueryRow(ctx, `SELECT COALESCE(last_label_seq, 0) FROM po_box_counter WHERE id_production_order = $1`, idPO).Scan(&last)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil // no counter yet ⇒ sequence starts at 0, first label is 1
	}
	return last, err
}

func (p *pgScanTx) insertScan(ctx context.Context, enterpriseID int, req ScanRequest, labelSeq *int64, counterSeq, delta int64) (int64, int64, error) {
	// id_site/id_area/id_order are denormalized from the tenant's OWN rows via
	// scalar subqueries (never client-supplied). PHASE-2: hierarchy enrichment
	// + GS1 parse of raw_barcode into structured fields.
	const insertSQL = `
		INSERT INTO box_scans (
			id_enterprise, id_site, id_area, id_equipment, id_production_order, id_order,
			scan_type, label_seq, qty, counts_toward_total, raw_barcode, scan_uuid, ts_value
		) VALUES (
			$1,
			(SELECT id_site FROM equipments WHERE id_equipment = $2 AND id_enterprise = $1),
			(SELECT id_area FROM equipments WHERE id_equipment = $2 AND id_enterprise = $1),
			$2, $3,
			(SELECT id_order FROM production_orders WHERE id_production_order = $3 AND id_enterprise = $1),
			$4, $5, $6, $7, $8, $9, now()
		)
		RETURNING box_scan_id`
	countsTowardTotal := req.ScanType == scanTypeProduction
	var boxScanID int64
	if err := p.tx.QueryRow(ctx, insertSQL,
		enterpriseID, req.IDEquipment, req.IDProductionOrder,
		req.ScanType, labelSeq, req.Qty, countsTowardTotal, req.RawBarcode, req.ScanUUID,
	).Scan(&boxScanID); err != nil {
		return 0, 0, err
	}

	const counterSQL = `
		INSERT INTO po_box_counter (id_production_order, id_enterprise, last_label_seq, total_qty, updated_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (id_production_order) DO UPDATE
		   SET last_label_seq = GREATEST(po_box_counter.last_label_seq, EXCLUDED.last_label_seq),
		       total_qty      = po_box_counter.total_qty + $4,
		       updated_at     = now()
		RETURNING total_qty`
	var total int64
	if err := p.tx.QueryRow(ctx, counterSQL, req.IDProductionOrder, enterpriseID, counterSeq, delta).Scan(&total); err != nil {
		return 0, 0, err
	}
	return boxScanID, total, nil
}

// ── HTTP handler ─────────────────────────────────────────────────────────────

type scanServer struct {
	store  scanStore
	broker *sseBroker
	logger logger
}

// logger is the minimal slog surface the server uses (an interface so tests can
// pass a no-op).
type logger interface {
	Info(msg string, args ...any)
	Warn(msg string, args ...any)
}

func (s *scanServer) handlePostScan(w http.ResponseWriter, r *http.Request) {
	enterpriseID, ok := enterpriseIDFromContext(r.Context())
	if !ok { // unreachable behind auth middleware; fail-closed anyway
		failed.Add(1)
		writeJSON(w, http.StatusUnauthorized, `{"error":"missing tenant"}`)
		return
	}

	var req ScanRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		failed.Add(1)
		writeJSON(w, http.StatusBadRequest, `{"error":"invalid json body"}`)
		return
	}
	if derr := validateScanRequest(&req); derr != nil {
		failed.Add(1)
		writeDomain(w, derr)
		return
	}

	res, derr, err := s.store.RecordScan(r.Context(), enterpriseID, req)
	if err != nil {
		failed.Add(1)
		s.logger.Warn("record scan failed", "err", err.Error(), "id_po", req.IDProductionOrder)
		writeJSON(w, http.StatusInternalServerError, `{"error":"record failed"}`)
		return
	}
	if derr != nil {
		failed.Add(1)
		writeDomain(w, derr)
		return
	}

	served.Add(1)
	// Publish to SSE subscribers scoped to this PO — but NOT for a replay (no new
	// row, so no new event to fan out). Fire-and-forget; never blocks the write.
	if !res.Replayed {
		s.broker.publish(req.IDProductionOrder, enterpriseID, res)
	}
	status := http.StatusCreated
	if res.Replayed {
		status = http.StatusOK // idempotent replay
	}
	body, _ := json.Marshal(res)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// validateScanRequest normalizes defaults and rejects malformed input with a
// clean 400 BEFORE any DB work.
func validateScanRequest(req *ScanRequest) *domainError {
	req.ScanType = strings.ToLower(strings.TrimSpace(req.ScanType))
	req.Mode = strings.ToLower(strings.TrimSpace(req.Mode))
	if req.ScanType == "" {
		req.ScanType = scanTypeProduction
	}
	if req.Mode == "" {
		req.Mode = modeAssign
	}
	if req.Qty == 0 {
		req.Qty = 1
	}
	if req.ScanUUID == "" {
		return &domainError{Status: http.StatusBadRequest, Code: "scan_uuid_required"}
	}
	if req.IDProductionOrder <= 0 {
		return &domainError{Status: http.StatusBadRequest, Code: "id_production_order_required"}
	}
	if req.IDEquipment <= 0 {
		return &domainError{Status: http.StatusBadRequest, Code: "id_equipment_required"}
	}
	if req.Qty < 0 {
		return &domainError{Status: http.StatusBadRequest, Code: "qty_invalid"}
	}
	if !validScanTypes[req.ScanType] {
		return &domainError{Status: http.StatusBadRequest, Code: "scan_type_invalid"}
	}
	if req.Mode != modeAssign && req.Mode != modeValidate {
		return &domainError{Status: http.StatusBadRequest, Code: "mode_invalid"}
	}
	return nil
}

func writeDomain(w http.ResponseWriter, d *domainError) {
	body, _ := json.Marshal(d)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(d.Status)
	_, _ = w.Write(body)
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}
