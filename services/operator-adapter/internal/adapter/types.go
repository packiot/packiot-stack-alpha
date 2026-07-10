package adapter

// This file defines the two boundary contracts the adapter bridges:
//
//  1. The Incoplast operator-action shapes (DowntimeRequest / PORequest) —
//     the RESOLVED form of the `justify event PackML` and `start new po`
//     Node-RED function nodes. The tee node (see README) posts these.
//
//  2. The edge-api DTOs (edgeCreateDowntime / edgeEditDowntime /
//     edgeCreateAndStartPO) — mirror the NestJS class-validator DTOs in
//     edge-api/src/usecases/*. Field names are the JSON keys edge-api expects.
//
// Everything is a pointer or a plain type chosen so that "field absent" is
// distinguishable from "field present but zero". For the required-field gate
// (422 on unmapped) we must tell `"id_equipment": 0` apart from a missing key,
// so the required numeric fields are *pointers.

// ── Incoplast inbound: downtime justification ────────────────────────────────

// DowntimeRequest is the resolved `justify event PackML` action.
//
// The raw Node-RED node parses two delimited strings before this point; the
// tee node is responsible for that split and posts the already-split fields:
//
//	set_event_categoria.split(".|:")    -> [category, planned_dwt, change_over, category_desc, idle]
//	set_event_subcategoria.split(".|:") -> [subcategory, subcategory_desc]
//
// IDParam mirrors the SparkPlug Parameter id the node assigns and is how we
// route create vs edit:
//
//	30810 justify (new)      -> create-manual-event
//	30811 manual   (new)     -> create-manual-event
//	30812 manual_chg (edit)  -> edit-manual-event
//	30813 trim_event (edit)  -> edit-manual-event
//	30814 trim_event2 (edit) -> edit-manual-event
type DowntimeRequest struct {
	Enterprise  *int   `json:"enterprise"`   // scope: must equal configured Incoplast enterprise id
	Topic       string `json:"topic"`        // app_user_topic; scope-checked against topic prefix
	PackmlTopic string `json:"packml_topic"` // SparkPlug packml_topic; the adapter resolves it → staging ids

	IDParam          int  `json:"id_param"`           // 30810..30814, selects create vs edit
	IDEquipment      *int `json:"id_equipment"`       // resolved by the adapter from packml_topic; NOT sent by the tee
	IDEquipmentEvent *int `json:"id_equipment_event"` // set_event_id; REQUIRED for edit path

	CDMachine string `json:"cd_machine"` // resolved by the adapter (equipments.cd_equipment); NOT sent by the tee

	TSEvent string `json:"ts_event"` // ISO 8601 start; REQUIRED
	TSEnd   string `json:"ts_end"`   // ISO 8601 end;   REQUIRED

	Category        string `json:"category"`         // cd_category;   REQUIRED
	CategoryDesc    string `json:"category_desc"`    // desc_category; REQUIRED
	Subcategory     string `json:"subcategory"`      // cd_subcategory
	SubcategoryDesc string `json:"subcategory_desc"` // desc_subcategory
	TxtDowntime     string `json:"txt_downtime"`     // txt_downtime_notes

	// Edit-only fields (ignored on the create path — edge-api's CreateDto has
	// no columns for them).
	PlannedDowntime *bool  `json:"planned_dwt"`
	ChangeOver      *bool  `json:"change_over"`
	Idle            string `json:"idle"`

	User string `json:"user"` // operator id — audit only, NEVER logged, NOT sent to edge-api
}

// scopeFields lets DowntimeRequest satisfy `scoped` so it flows through the same
// pre-flight (pre) as the newer PO-lifecycle requests.
func (r *DowntimeRequest) scopeFields() (*int, string) { return r.Enterprise, r.PackmlTopic }

// ── Incoplast inbound: PO start ──────────────────────────────────────────────

// PORequest is the resolved `start new po` action.
//
// In Node-RED the operator selects an *order number* (msg.payload.new_po ==
// po.id_order); the flow resolves it to the internal id_production_order and to
// the equipment via the topic. The tee node posts the order number plus the
// hierarchy ids it already holds in the matched `_POs` object + entity context.
type PORequest struct {
	Enterprise  *int   `json:"enterprise"`   // scope: must equal configured Incoplast enterprise id
	Topic       string `json:"topic"`        // app_user_topic; scope-checked
	PackmlTopic string `json:"packml_topic"` // SparkPlug packml_topic; the adapter resolves it → staging ids

	IDOrder                 *int   `json:"id_order"`                  // operator-selected order number; REQUIRED
	IDSite                  *int   `json:"id_site"`                   // resolved by the adapter from packml_topic; NOT sent by the tee
	IDArea                  *int   `json:"id_area"`                   // resolved by the adapter from packml_topic; NOT sent by the tee
	IDEquipment             *int   `json:"id_equipment"`              // resolved by the adapter from packml_topic; NOT sent by the tee
	ProductionOrderQuantity *int   `json:"production_order_quantity"` // po.production_programmed; REQUIRED
	Timestamp               string `json:"timestamp"`                 // 'YYYY-MM-DD HH:mm:ss'; REQUIRED

	NmProductionOrder       string `json:"nm_production_order"` // po.nm_product; optional
	TxtProductionOrderNotes string `json:"notes"`               // optional
	IDLabel                 *int   `json:"id_label"`            // optional; Incoplast has no label concept

	User string `json:"user"` // audit only, never forwarded
}

// scopeFields lets PORequest satisfy `scoped` (shared pre-flight).
func (r *PORequest) scopeFields() (*int, string) { return r.Enterprise, r.PackmlTopic }

// ── edge-api outbound DTOs ───────────────────────────────────────────────────
// JSON keys match edge-api's NestJS DTOs verbatim.

// edgeCreateDowntime → POST /api/downtimes/create-manual-event
type edgeCreateDowntime struct {
	CDCategory       string `json:"cdCategory"`
	DescCategory     string `json:"descCategory"`
	CDMachine        string `json:"cdMachine"`
	CDSubcategory    string `json:"cdSubcategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
	IDEnterprise     int    `json:"idEnterprise"`
	IDEquipment      int    `json:"idEquipment"`
	TSEvent          string `json:"tsEvent"`
	TSEnd            string `json:"tsEnd"`
}

// edgeEditDowntime → POST /api/downtimes/edit-manual-event
type edgeEditDowntime struct {
	CDCategory       string `json:"cdCategory"`
	DescCategory     string `json:"descCategory"`
	CDMachine        string `json:"cdMachine"`
	CDSubcategory    string `json:"cdSubcategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	Idle             string `json:"idle"`
	ChangeOver       bool   `json:"changeOver"`
	IDEquipmentEvent int    `json:"idEquipmentEvent"`
	IDEquipment      int    `json:"idEquipment"`
	Start            string `json:"start"`
	End              string `json:"end"`
}

// edgeCreateAndStartPO → POST /api/production-orders/create-and-start
type edgeCreateAndStartPO struct {
	IDEnterprise            int    `json:"idEnterprise"`
	IDSite                  int    `json:"idSite"`
	IDArea                  int    `json:"idArea"`
	IDEquipment             int    `json:"idEquipment"`
	IDOrder                 int    `json:"idOrder"`
	ProductionOrderQuantity int    `json:"productionOrderQuantity"`
	Timestamp               string `json:"timestamp"`
	IDLabel                 *int   `json:"idLabel,omitempty"`
	NmProductionOrder       string `json:"nmProductionOrder,omitempty"`
	TxtProductionOrderNotes string `json:"txtProductionOrderNotes,omitempty"`
}

// edgeCall is the parcel produced by the mapping layer and consumed by the
// edge-api client: a path, an idEnterprise query value, and a JSON body.
type edgeCall struct {
	path         string // e.g. /api/downtimes/create-manual-event
	idEnterprise int    // becomes ?idEnterprise= so the audit log records the right tenant
	body         any    // one of the edge* DTOs above
}

// outcome label constants — keep in sync with metrics.go's documented set.
const (
	outcomeAccepted        = "accepted"
	outcomeUnauthorized    = "unauthorized"
	outcomeForbidden       = "forbidden"
	outcomeUnmapped        = "unmapped"
	outcomeUnresolved      = "unresolved"     // packml_topic → staging id resolution failed (422)
	outcomeResolverError   = "resolver_error" // resolver DB/transport error (503)
	outcomeBadRequest      = "bad_request"
	outcomeEdge4xx         = "edge_4xx"
	outcomeEdge5xx         = "edge_5xx"
	outcomeEdgeUnreachable = "edge_unreachable"
)
