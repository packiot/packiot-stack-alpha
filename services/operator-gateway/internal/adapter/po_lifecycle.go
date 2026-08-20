package adapter

import (
	"net/http"
	"strings"
)

// This file extends the adapter beyond the initial two routes (create-and-start
// PO + downtime justify) to the FULL operator production-order surface edge-api
// exposes. Every operator action ultimately becomes a semantic edge-api call;
// the routes here map 1:1 onto those endpoints:
//
//	/operator/po/stop          -> POST /api/production-orders/stop           (order-stopped)
//	/operator/po/setup         -> POST /api/production-orders/setup          (order-changed)
//	/operator/po/replace       -> POST /api/production-orders/replace        (order-replaced)
//	/operator/po/change-status -> POST /api/production-orders/change-status  (order-status-changed)
//	/operator/po/change-time   -> POST /api/production-orders/change-time    (order-time-changed)
//
// Design note — why ACTION-driven, not PARAM-driven. Incoplast's Node-RED flow
// encodes these as raw SparkPlug Parameter[30800..30803] with contextual fields,
// and a downstream node decodes that into the right edge-api call. We do NOT
// replicate that Incoplast-specific decode here: the adapter is an
// anti-corruption layer whose stable contract is edge-api's own semantics. Each
// client's tee node does the small translation from its private representation
// to these semantic routes. That keeps the adapter client-agnostic and testable
// (one route == one endpoint == one eventType) instead of coupling it to one
// factory's parameter conventions.
//
// Scrap deliberately has NO route here. In the operator flow scrap is emitted as
// Admin/ProdDefectiveCount / ProdConsumedCount / ProdProcessedCount COUNTER
// metrics (plus a Parameter[30850] marker) — raw time-series that flows through
// the DATA path (ingest-shim → worker → equipment_values), not an edge-api REST
// call. edge-api has no scrap endpoint; final good-count corrections ride inside
// the stop/setup bodies (productionOrderQuantity / oldProductionOrderProdFinal).
// So scrap is bridged by the data tee, not this adapter. See README.

// operatorScope is the tenant-scoping envelope every operator action carries.
// Embedding it gives each request type the fields scopeOK checks plus the
// scopeFields() method the generic pre-flight (pre) reads — so a new action type
// is scope-guarded for free just by embedding this.
type operatorScope struct {
	Enterprise  *int   `json:"enterprise"`   // must equal the configured Incoplast enterprise id
	Topic       string `json:"topic"`        // app_user_topic; carried for audit/debug
	PackmlTopic string `json:"packml_topic"` // SparkPlug topic; the adapter resolves it → staging ids
	User        string `json:"user"`         // operator id — audit only, NEVER forwarded or logged
}

// scopeFields exposes the (enterprise, packml_topic) pair the scope gate needs.
// Value receiver so both T and *T (T embedding operatorScope) satisfy `scoped`.
func (s operatorScope) scopeFields() (*int, string) { return s.Enterprise, s.PackmlTopic }

// ── inbound operator requests (what the tee node posts) ──────────────────────
//
// Required numeric fields are *int so "absent" is distinguishable from a real
// zero — the fail-closed mapper must tell `"id_production_order": 0` apart from
// a missing key and reject the former rather than write a wrong id.

// POStopRequest → /operator/po/stop. Pause or finish the running PO.
type POStopRequest struct {
	operatorScope
	Timestamp               string `json:"timestamp"`                 // event time; REQUIRED
	StopType                string `json:"stop_type"`                 // pause|finish (or 1|2); REQUIRED
	IDProductionOrder       *int   `json:"id_production_order"`       // internal PO id (flow context); REQUIRED
	ProductionOrderQuantity *int   `json:"production_order_quantity"` // final good count; REQUIRED
}

// POSetupRequest → /operator/po/setup. Atomic "close current PO and optionally
// open the next" — the workhorse behind Incoplast's `change po - open e close`.
type POSetupRequest struct {
	operatorScope
	Timestamp                   string `json:"timestamp"`                       // REQUIRED
	ShouldOpenNewPo             *bool  `json:"should_open_new_po"`              // REQUIRED (non-nil)
	StopType                    string `json:"stop_type"`                       // pause|finish; REQUIRED
	OldIDProductionOrder        *int   `json:"old_id_production_order"`         // PO being closed; REQUIRED
	OldProductionOrderProdFinal *int   `json:"old_production_order_prod_final"` // its final good count; REQUIRED
	ShouldCreatePo              *bool  `json:"should_create_po"`                // open-next needs a fresh PO row?
	IDOrder                     *int   `json:"id_order"`                        // new order number (when creating)
	IDProductionOrder           *int   `json:"id_production_order"`             // new internal PO id (when reusing)
	ProductionOrderQuantity     *int   `json:"production_order_quantity"`       // new PO programmed quantity
	IDLabel                     *int   `json:"id_label"`                        // optional
	NmProductionOrder           string `json:"nm_production_order"`             // optional
	Notes                       string `json:"notes"`                           // optional
}

// POReplaceRequest → /operator/po/replace. Stop the running PO and start an
// existing one. Incoplast's `change PO PackML` (set_po_number).
type POReplaceRequest struct {
	operatorScope
	IDProductionOrder *int `json:"id_production_order"` // the PO to switch to; REQUIRED
}

// POStatusRequest → /operator/po/change-status. Toggle paused↔finished.
type POStatusRequest struct {
	operatorScope
	IDProductionOrder *int `json:"id_production_order"` // REQUIRED
}

// POTimeRequest → /operator/po/change-time. Edit a runtime interval's timestamps.
type POTimeRequest struct {
	operatorScope
	IDProductionOrderRuntime *int   `json:"id_production_order_runtime"` // the runtime row to edit; REQUIRED
	IDProductionOrder        *int   `json:"id_production_order"`         // its PO; REQUIRED
	Start                    string `json:"start"`                       // new start; REQUIRED
	End                      string `json:"end"`                         // new end; optional
}

// ── edge-api outbound DTOs (JSON keys mirror edge-api's NestJS DTOs) ──────────

// edgeStopPO → POST /api/production-orders/stop (StopProductionOrderDto)
type edgeStopPO struct {
	Timestamp               string `json:"timestamp"`
	StopType                string `json:"stopType"`
	IDEnterprise            int    `json:"idEnterprise"`
	IDEquipment             int    `json:"idEquipment"`
	IDProductionOrder       int    `json:"idProductionOrder"`
	ProductionOrderQuantity int    `json:"productionOrderQuantity"`
}

// edgeSetupPO → POST /api/production-orders/setup (SetupProductionOrderDto)
type edgeSetupPO struct {
	Timestamp                   string `json:"timestamp"`
	ShouldOpenNewPo             bool   `json:"shouldOpenNewPo"`
	StopType                    string `json:"stopType"`
	IDEnterprise                int    `json:"idEnterprise"`
	IDSite                      int    `json:"idSite"`
	IDArea                      int    `json:"idArea"`
	IDEquipment                 int    `json:"idEquipment"`
	OldIDProductionOrder        int    `json:"oldIdProductionOrder"`
	OldProductionOrderProdFinal int    `json:"oldProductionOrderProdFinal"`
	ShouldCreatePo              bool   `json:"shouldCreatePo"`
	IDOrder                     int    `json:"idOrder"`
	IDProductionOrder           int    `json:"idProductionOrder"`
	ProductionOrderQuantity     int    `json:"productionOrderQuantity"`
	IDLabel                     *int   `json:"idLabel,omitempty"`
	NmProductionOrder           string `json:"nmProductionOrder,omitempty"`
	TxtProductionOrderNotes     string `json:"txtProductionOrderNotes,omitempty"`
}

// edgeReplacePO → POST /api/production-orders/replace (ReplaceProductionOrderDto)
type edgeReplacePO struct {
	IDEnterprise      int `json:"idEnterprise"`
	IDEquipment       int `json:"idEquipment"`
	IDProductionOrder int `json:"idProductionOrder"`
}

// edgeChangeStatusPO → POST /api/production-orders/change-status
// (ChangeStatusProductionOrderDto — no idEnterprise in the body; the adapter
// still sends ?idEnterprise= for audit attribution via edgeCall.idEnterprise).
type edgeChangeStatusPO struct {
	IDProductionOrder int `json:"idProductionOrder"`
	IDEquipment       int `json:"idEquipment"`
}

// edgeChangeTimePO → POST /api/production-orders/change-time
// (ChangeTimeProductionOrderDto)
type edgeChangeTimePO struct {
	IDProductionOrderRuntime int    `json:"idProductionOrderRuntime"`
	IDProductionOrder        int    `json:"idProductionOrder"`
	IDEquipment              int    `json:"idEquipment"`
	Start                    string `json:"start"`
	End                      string `json:"end"`
}

// ── mapping (inbound → edgeCall), fail-closed on any missing required field ──

// normalizeStopType accepts both edge-api's canonical strings and Incoplast's
// numeric convention (stop_type 1 = interrupt/pause, 2 = finish), so a tee can
// forward either without knowing edge-api's vocabulary.
func normalizeStopType(v string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "pause", "interrupt", "1":
		return "pause", nil
	case "finish", "2":
		return "finish", nil
	default:
		return "", unmapped("stop_type %q is not recognised (expected pause|finish or 1|2)", v)
	}
}

func derefInt(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func derefBool(p *bool) bool {
	return p != nil && *p
}

func mapPOStop(req *POStopRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	if strings.TrimSpace(req.Timestamp) == "" {
		return nil, unmapped("timestamp is required but was empty")
	}
	if req.IDProductionOrder == nil {
		return nil, unmapped("id_production_order is required but was not supplied (the running PO's internal id, from flow context)")
	}
	if req.ProductionOrderQuantity == nil {
		return nil, unmapped("production_order_quantity is required but was not supplied (final good count)")
	}
	stopType, err := normalizeStopType(req.StopType)
	if err != nil {
		return nil, err
	}
	body := edgeStopPO{
		Timestamp:               req.Timestamp,
		StopType:                stopType,
		IDEnterprise:            idEnterprise,
		IDEquipment:             res.IDEquipment,
		IDProductionOrder:       *req.IDProductionOrder,
		ProductionOrderQuantity: *req.ProductionOrderQuantity,
	}
	return &edgeCall{path: "/api/production-orders/stop", idEnterprise: idEnterprise, body: body}, nil
}

func mapPOSetup(req *POSetupRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	if strings.TrimSpace(req.Timestamp) == "" {
		return nil, unmapped("timestamp is required but was empty")
	}
	if req.ShouldOpenNewPo == nil {
		return nil, unmapped("should_open_new_po is required (true = close current + open next, false = close only) but was not supplied")
	}
	if req.OldIDProductionOrder == nil {
		return nil, unmapped("old_id_production_order is required but was not supplied (the PO being closed)")
	}
	if req.OldProductionOrderProdFinal == nil {
		return nil, unmapped("old_production_order_prod_final is required but was not supplied (final good count of the closing PO)")
	}
	stopType, err := normalizeStopType(req.StopType)
	if err != nil {
		return nil, err
	}
	// When opening a fresh PO, edge-api needs the order number to create it; when
	// reusing an existing PO row it needs the internal id. Require the relevant
	// one so a half-specified "open next" cannot silently open nothing.
	if *req.ShouldOpenNewPo {
		if derefBool(req.ShouldCreatePo) && req.IDOrder == nil {
			return nil, unmapped("id_order is required when should_open_new_po and should_create_po are true (the new order number)")
		}
		if !derefBool(req.ShouldCreatePo) && req.IDProductionOrder == nil {
			return nil, unmapped("id_production_order is required when opening an existing next PO (should_create_po false)")
		}
	}
	body := edgeSetupPO{
		Timestamp:                   req.Timestamp,
		ShouldOpenNewPo:             *req.ShouldOpenNewPo,
		StopType:                    stopType,
		IDEnterprise:                idEnterprise,
		IDSite:                      res.IDSite,
		IDArea:                      res.IDArea,
		IDEquipment:                 res.IDEquipment,
		OldIDProductionOrder:        *req.OldIDProductionOrder,
		OldProductionOrderProdFinal: *req.OldProductionOrderProdFinal,
		ShouldCreatePo:              derefBool(req.ShouldCreatePo),
		IDOrder:                     derefInt(req.IDOrder),
		IDProductionOrder:           derefInt(req.IDProductionOrder),
		ProductionOrderQuantity:     derefInt(req.ProductionOrderQuantity),
		IDLabel:                     req.IDLabel,
		NmProductionOrder:           req.NmProductionOrder,
		TxtProductionOrderNotes:     req.Notes,
	}
	return &edgeCall{path: "/api/production-orders/setup", idEnterprise: idEnterprise, body: body}, nil
}

func mapPOReplace(req *POReplaceRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	if req.IDProductionOrder == nil {
		return nil, unmapped("id_production_order is required but was not supplied (the PO to switch to)")
	}
	body := edgeReplacePO{
		IDEnterprise:      idEnterprise,
		IDEquipment:       res.IDEquipment,
		IDProductionOrder: *req.IDProductionOrder,
	}
	return &edgeCall{path: "/api/production-orders/replace", idEnterprise: idEnterprise, body: body}, nil
}

func mapPOStatus(req *POStatusRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	if req.IDProductionOrder == nil {
		return nil, unmapped("id_production_order is required but was not supplied")
	}
	body := edgeChangeStatusPO{
		IDProductionOrder: *req.IDProductionOrder,
		IDEquipment:       res.IDEquipment,
	}
	return &edgeCall{path: "/api/production-orders/change-status", idEnterprise: idEnterprise, body: body}, nil
}

func mapPOTime(req *POTimeRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	switch {
	case req.IDProductionOrderRuntime == nil:
		return nil, unmapped("id_production_order_runtime is required but was not supplied (the runtime interval to edit)")
	case req.IDProductionOrder == nil:
		return nil, unmapped("id_production_order is required but was not supplied")
	case strings.TrimSpace(req.Start) == "":
		return nil, unmapped("start is required but was empty")
	}
	body := edgeChangeTimePO{
		IDProductionOrderRuntime: *req.IDProductionOrderRuntime,
		IDProductionOrder:        *req.IDProductionOrder,
		IDEquipment:              res.IDEquipment,
		Start:                    req.Start,
		End:                      req.End,
	}
	return &edgeCall{path: "/api/production-orders/change-time", idEnterprise: idEnterprise, body: body}, nil
}

// ── handlers ─────────────────────────────────────────────────────────────────
//
// Each is a thin adapter over the shared pipeline: pre-flight (method/auth/
// decode/scope) → resolve topic → build the edge call → forward. The build
// closure runs only after decode+scope+resolve all succeed, and receives the
// resolved staging ids directly (the mapper never trusts caller-supplied ids).

func (s *Server) handlePOStop(w http.ResponseWriter, r *http.Request) {
	var req POStopRequest
	s.handlePOAction(w, r, "po_stop", &req, func(res Resolved) (*edgeCall, error) {
		return mapPOStop(&req, res, s.cfg.EnterpriseID)
	})
}

func (s *Server) handlePOSetup(w http.ResponseWriter, r *http.Request) {
	var req POSetupRequest
	s.handlePOAction(w, r, "po_setup", &req, func(res Resolved) (*edgeCall, error) {
		return mapPOSetup(&req, res, s.cfg.EnterpriseID)
	})
}

func (s *Server) handlePOReplace(w http.ResponseWriter, r *http.Request) {
	var req POReplaceRequest
	s.handlePOAction(w, r, "po_replace", &req, func(res Resolved) (*edgeCall, error) {
		return mapPOReplace(&req, res, s.cfg.EnterpriseID)
	})
}

func (s *Server) handlePOStatus(w http.ResponseWriter, r *http.Request) {
	var req POStatusRequest
	s.handlePOAction(w, r, "po_change_status", &req, func(res Resolved) (*edgeCall, error) {
		return mapPOStatus(&req, res, s.cfg.EnterpriseID)
	})
}

func (s *Server) handlePOTime(w http.ResponseWriter, r *http.Request) {
	var req POTimeRequest
	s.handlePOAction(w, r, "po_change_time", &req, func(res Resolved) (*edgeCall, error) {
		return mapPOTime(&req, res, s.cfg.EnterpriseID)
	})
}

// handlePOAction is the shared pipeline for every topic-resolving operator
// action. build is invoked with the resolved staging ids and returns the mapped
// edge call (or an *unmappedError → 422).
func (s *Server) handlePOAction(w http.ResponseWriter, r *http.Request, action string, req scoped, build func(Resolved) (*edgeCall, error)) {
	if !s.pre(w, r, action, req) {
		return
	}
	_, topic := req.scopeFields()
	resolved, ok := s.resolve(w, r.Context(), action, topic)
	if !ok {
		return
	}
	call, err := build(resolved)
	if err != nil {
		s.handleMapErr(w, action, err)
		return
	}
	s.forward(w, r.Context(), action, call)
}
