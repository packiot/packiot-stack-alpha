package adapter

import (
	"fmt"
	"strings"
)

// unmappedError signals that a required field could not be mapped to the
// edge-api contract. It becomes an HTTP 422 with a clear message. We fail
// closed here on purpose: a wrong downtime/PO write is worse than a rejected
// one, so anything ambiguous stops at the adapter rather than reaching the DB.
type unmappedError struct{ msg string }

func (e *unmappedError) Error() string { return e.msg }

func unmapped(format string, a ...any) *unmappedError {
	return &unmappedError{msg: fmt.Sprintf(format, a...)}
}

// downtime SparkPlug Parameter ids → routing.
const (
	paramJustify   = 30810 // new justification
	paramManual    = 30811 // new manual event
	paramManualChg = 30812 // edit existing
	paramTrimEvent = 30813 // edit: trim end
	paramTrimEvt2  = 30814 // edit: trim end (variant)
)

// mapDowntime translates a resolved `justify event PackML` action into an
// edge-api call. It routes on id_param: the "new" ids create a manual event,
// the "change/trim" ids edit an existing one.
func mapDowntime(req *DowntimeRequest, idEnterprise int) (*edgeCall, error) {
	// Fields common to both edge paths, required by edge-api's @IsNotEmpty.
	if req.IDEquipment == nil {
		return nil, unmapped("id_equipment is required but was not supplied — the tee node must resolve topic %q to an id_equipment", req.Topic)
	}
	if strings.TrimSpace(req.CDMachine) == "" {
		return nil, unmapped("cd_machine is required but was empty — edge-api marks cdMachine @IsNotEmpty")
	}
	if strings.TrimSpace(req.Category) == "" {
		return nil, unmapped("category is required but was empty (edge cdCategory @IsNotEmpty)")
	}
	if strings.TrimSpace(req.CategoryDesc) == "" {
		return nil, unmapped("category_desc is required but was empty (edge descCategory @IsNotEmpty)")
	}
	if strings.TrimSpace(req.TSEvent) == "" {
		return nil, unmapped("ts_event is required but was empty")
	}
	if strings.TrimSpace(req.TSEnd) == "" {
		return nil, unmapped("ts_end is required but was empty")
	}

	switch req.IDParam {
	case paramJustify, paramManual:
		body := edgeCreateDowntime{
			CDCategory:       req.Category,
			DescCategory:     req.CategoryDesc,
			CDMachine:        req.CDMachine,
			CDSubcategory:    req.Subcategory,
			DescSubcategory:  req.SubcategoryDesc,
			TxtDowntimeNotes: req.TxtDowntime,
			IDEnterprise:     idEnterprise,
			IDEquipment:      *req.IDEquipment,
			TSEvent:          req.TSEvent,
			TSEnd:            req.TSEnd,
		}
		return &edgeCall{
			path:         "/api/downtimes/create-manual-event",
			idEnterprise: idEnterprise,
			body:         body,
		}, nil

	case paramManualChg, paramTrimEvent, paramTrimEvt2:
		if req.IDEquipmentEvent == nil {
			return nil, unmapped("id_equipment_event is required to edit an existing downtime (id_param %d) but was not supplied", req.IDParam)
		}
		body := edgeEditDowntime{
			CDCategory:       req.Category,
			DescCategory:     req.CategoryDesc,
			CDMachine:        req.CDMachine,
			CDSubcategory:    req.Subcategory,
			DescSubcategory:  req.SubcategoryDesc,
			TxtDowntimeNotes: req.TxtDowntime,
			PlannedDowntime:  req.PlannedDowntime != nil && *req.PlannedDowntime,
			Idle:             req.Idle,
			ChangeOver:       req.ChangeOver != nil && *req.ChangeOver,
			IDEquipmentEvent: *req.IDEquipmentEvent,
			IDEquipment:      *req.IDEquipment,
			Start:            req.TSEvent,
			End:              req.TSEnd,
		}
		return &edgeCall{
			path:         "/api/downtimes/edit-manual-event",
			idEnterprise: idEnterprise,
			body:         body,
		}, nil

	default:
		return nil, unmapped("id_param %d is not a recognised downtime parameter (expected 30810-30814)", req.IDParam)
	}
}

// mapPO translates a resolved `start new po` action into an edge-api
// create-and-start call. All hierarchy ids and the quantity must be present:
// they live in Incoplast's flow context (the matched `_POs` object + entity
// tree), not in the raw operator click, so the tee node must resolve them.
func mapPO(req *PORequest, idEnterprise int) (*edgeCall, error) {
	switch {
	case req.IDOrder == nil:
		return nil, unmapped("id_order is required but was not supplied (operator-selected order number, msg.payload.new_po)")
	case req.IDSite == nil:
		return nil, unmapped("id_site is required but was not supplied — the tee node must resolve topic %q to an id_site", req.Topic)
	case req.IDArea == nil:
		return nil, unmapped("id_area is required but was not supplied — the tee node must resolve topic %q to an id_area", req.Topic)
	case req.IDEquipment == nil:
		return nil, unmapped("id_equipment is required but was not supplied — the tee node must resolve topic %q to an id_equipment", req.Topic)
	case req.ProductionOrderQuantity == nil:
		return nil, unmapped("production_order_quantity is required but was not supplied (po.production_programmed)")
	case strings.TrimSpace(req.Timestamp) == "":
		return nil, unmapped("timestamp is required but was empty (expected 'YYYY-MM-DD HH:mm:ss')")
	}

	body := edgeCreateAndStartPO{
		IDEnterprise:            idEnterprise,
		IDSite:                  *req.IDSite,
		IDArea:                  *req.IDArea,
		IDEquipment:             *req.IDEquipment,
		IDOrder:                 *req.IDOrder,
		ProductionOrderQuantity: *req.ProductionOrderQuantity,
		Timestamp:               req.Timestamp,
		IDLabel:                 req.IDLabel, // nil → omitted (optional/nullable in edge DTO)
		NmProductionOrder:       req.NmProductionOrder,
		TxtProductionOrderNotes: req.TxtProductionOrderNotes,
	}
	return &edgeCall{
		path:         "/api/production-orders/create-and-start",
		idEnterprise: idEnterprise,
		body:         body,
	}, nil
}
