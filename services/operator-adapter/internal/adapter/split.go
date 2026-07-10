package adapter

import (
	"net/http"
	"strings"
)

// This file adds the operator "split event" action — the last uncovered piece
// of the operator surface the CPACK refactor-validity audit flagged (P2). An
// operator splits one automated/manual/low-speed downtime event into several
// sub-intervals, each re-categorised. It maps 1:1 onto edge-api's
// POST /api/downtimes/split (eventType "event-splitted").
//
// It is distinct from the downtime EDIT path (/operator/downtime, id_param
// 30812-30814), which TRIMS a single event's end. Incoplast's flow uses trim
// (→ edit-manual-event); CPACK's UI does a true multi-interval split, which has
// no representation on the edit path — hence a dedicated route.
//
// Like every operator action, the tee sends the packml_topic + the split fields
// it owns; the adapter resolves the topic → id_equipment + cd_machine (each
// sub-event's machineCode). id_equipment_event (the event being split) and the
// sub-interval list come from the operator's flow context.

// SplitRequest is the resolved operator "split event" action.
type SplitRequest struct {
	operatorScope
	IDEquipmentEvent *int         `json:"id_equipment_event"` // the event being split; REQUIRED
	EventType        string       `json:"event_type"`         // downtime|manual|low_speed; REQUIRED
	Events           []SplitEvent `json:"events"`             // the sub-intervals; REQUIRED, non-empty
}

// SplitEvent is one sub-interval the original event is split into. machine_code
// is NOT sent by the tee — the adapter fills it from the resolved cd_machine,
// exactly like the downtime route (edge-api's EventDto.machineCode).
type SplitEvent struct {
	StartTime       string `json:"start_time"`       // ISO 8601; REQUIRED
	EndTime         string `json:"end_time"`         // ISO 8601
	Note            string `json:"note"`             // optional
	CategoryCode    string `json:"category_code"`    // REQUIRED (edge categoryCode @IsNotEmpty)
	SubcategoryCode string `json:"subcategory_code"` // optional
	DescCategory    string `json:"desc_category"`    // REQUIRED (edge descCategory @IsNotEmpty)
	DescSubcategory string `json:"desc_subcategory"` // optional
	Idle            string `json:"idle"`             // REQUIRED — Yes|yes|No|no (edge @IsIn)
	ChangeOver      *bool  `json:"change_over"`      // REQUIRED (edge @IsBoolean, pointer to tell absent from false)
	PlannedDowntime *bool  `json:"planned_dwt"`      // REQUIRED (edge @IsBoolean)
}

// edgeSplit → POST /api/downtimes/split (SplitDto). JSON keys mirror the NestJS DTO.
type edgeSplit struct {
	IDEquipmentEvent int              `json:"idEquipmentEvent"`
	IDEquipment      int              `json:"idEquipment"`
	EventType        string           `json:"eventType"`
	Events           []edgeSplitEvent `json:"events"`
}

// edgeSplitEvent mirrors edge-api's EventDto.
type edgeSplitEvent struct {
	StartTime       string `json:"startTime"`
	EndTime         string `json:"endTime"`
	Note            string `json:"note"`
	MachineCode     string `json:"machineCode"`
	CategoryCode    string `json:"categoryCode"`
	SubcategoryCode string `json:"subcategoryCode"`
	DescCategory    string `json:"descCategory"`
	DescSubcategory string `json:"descSubcategory"`
	Idle            string `json:"idle"`
	ChangeOver      bool   `json:"changeOver"`
	PlannedDowntime bool   `json:"plannedDowntime"`
}

// validEventType is edge-api's SplitDto.eventType @IsIn set.
func validEventType(t string) bool {
	switch t {
	case "downtime", "manual", "low_speed":
		return true
	default:
		return false
	}
}

// validIdle is edge-api's EventDto.idle @IsIn set. edge-api requires a specific
// casing set, so we validate rather than silently forward a value it will 400 on.
func validIdle(v string) bool {
	switch v {
	case "Yes", "yes", "No", "no":
		return true
	default:
		return false
	}
}

// mapSplit translates a resolved split action into the edge-api call. Fail-closed
// on any required field: a wrong split write (re-slicing a real downtime into
// bogus intervals) is worse than a rejected one.
func mapSplit(req *SplitRequest, res Resolved, idEnterprise int) (*edgeCall, error) {
	if req.IDEquipmentEvent == nil {
		return nil, unmapped("id_equipment_event is required but was not supplied (the event being split)")
	}
	if !validEventType(req.EventType) {
		return nil, unmapped("event_type %q is not recognised (expected downtime|manual|low_speed)", req.EventType)
	}
	if len(req.Events) == 0 {
		return nil, unmapped("events is required but was empty (a split must produce at least one sub-interval)")
	}
	if strings.TrimSpace(res.CDMachine) == "" {
		return nil, unmapped("cd_machine is required but was not resolved from packml_topic %q (equipments.cd_equipment)", req.PackmlTopic)
	}

	events := make([]edgeSplitEvent, 0, len(req.Events))
	for i, e := range req.Events {
		switch {
		case strings.TrimSpace(e.StartTime) == "":
			return nil, unmapped("events[%d].start_time is required but was empty", i)
		case strings.TrimSpace(e.CategoryCode) == "":
			return nil, unmapped("events[%d].category_code is required but was empty (edge categoryCode @IsNotEmpty)", i)
		case strings.TrimSpace(e.DescCategory) == "":
			return nil, unmapped("events[%d].desc_category is required but was empty (edge descCategory @IsNotEmpty)", i)
		case !validIdle(e.Idle):
			return nil, unmapped("events[%d].idle %q is not recognised (expected Yes|yes|No|no)", i, e.Idle)
		case e.ChangeOver == nil:
			return nil, unmapped("events[%d].change_over is required (edge changeOver @IsBoolean) but was not supplied", i)
		case e.PlannedDowntime == nil:
			return nil, unmapped("events[%d].planned_dwt is required (edge plannedDowntime @IsBoolean) but was not supplied", i)
		}
		events = append(events, edgeSplitEvent{
			StartTime:       e.StartTime,
			EndTime:         e.EndTime,
			Note:            e.Note,
			MachineCode:     res.CDMachine, // resolved from topic, not caller-supplied
			CategoryCode:    e.CategoryCode,
			SubcategoryCode: e.SubcategoryCode,
			DescCategory:    e.DescCategory,
			DescSubcategory: e.DescSubcategory,
			Idle:            e.Idle,
			ChangeOver:      *e.ChangeOver,
			PlannedDowntime: *e.PlannedDowntime,
		})
	}

	body := edgeSplit{
		IDEquipmentEvent: *req.IDEquipmentEvent,
		IDEquipment:      res.IDEquipment,
		EventType:        req.EventType,
		Events:           events,
	}
	return &edgeCall{path: "/api/downtimes/split", idEnterprise: idEnterprise, body: body}, nil
}

func (s *Server) handleSplit(w http.ResponseWriter, r *http.Request) {
	var req SplitRequest
	s.handlePOAction(w, r, "split", &req, func(res Resolved) (*edgeCall, error) {
		return mapSplit(&req, res, s.cfg.EnterpriseID)
	})
}
