package adapter

import (
	"net/http"
	"strings"
	"testing"
)

// These cover the five PO-lifecycle routes added on top of the original
// downtime + create-and-start pair. Each route is checked for: the happy-path
// mapping (correct edge path + body with adapter-resolved ids injected), and the
// fail-closed behaviours it shares with the rest of the surface (auth, scope,
// unresolved topic, missing required field). The generic pipeline (pre +
// handlePOAction) is exercised transitively — a 401/403/422 on any route proves
// the shared guards run for it.

// ── stop ─────────────────────────────────────────────────────────────────────

func TestPOStop_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"packml_topic":"GRANADO/JAPERI-UP1/MF5-OPACO/LINHA_D",
		"timestamp":"2026-07-09 14:00:00",
		"stop_type":"finish",
		"id_production_order":90012,
		"production_order_quantity":4800,
		"user":"op1"
	}`
	rec := do(t, srv, "/operator/po/stop", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/stop" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	got, ok := fp.last.body.(edgeStopPO)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	want := edgeStopPO{
		Timestamp:               "2026-07-09 14:00:00",
		StopType:                "finish",
		IDEnterprise:            4,
		IDEquipment:             resEquipment, // resolved from topic
		IDProductionOrder:       90012,
		ProductionOrderQuantity: 4800,
	}
	if got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "po_stop", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

// stop_type accepts Incoplast's numeric convention (1=pause, 2=finish).
func TestPOStop_NumericStopType(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"2026-07-09 14:00:00","stop_type":"1","id_production_order":1,"production_order_quantity":10}`
	rec := do(t, srv, "/operator/po/stop", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if got := fp.last.body.(edgeStopPO).StopType; got != "pause" {
		t.Fatalf("stop_type 1 should normalise to pause, got %q", got)
	}
}

func TestPOStop_422_BadStopType(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"2026-07-09 14:00:00","stop_type":"halt","id_production_order":1,"production_order_quantity":10}`
	rec := do(t, srv, "/operator/po/stop", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "stop_type") {
		t.Fatalf("422 should name stop_type, got %s", rec.Body.String())
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called on unmapped input")
	}
}

func TestPOStop_422_MissingPO(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"2026-07-09 14:00:00","stop_type":"finish","production_order_quantity":10}`
	rec := do(t, srv, "/operator/po/stop", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "id_production_order") {
		t.Fatalf("422 should name id_production_order, got %s", rec.Body.String())
	}
}

func TestPOStop_401_MissingKey(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	if rec := do(t, srv, "/operator/po/stop", "", `{}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestPOStop_403_WrongEnterprise(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	body := `{"enterprise":99,"packml_topic":"GRANADO/L","timestamp":"t","stop_type":"finish","id_production_order":1,"production_order_quantity":1}`
	if rec := do(t, srv, "/operator/po/stop", testKey, body); rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
}

func TestPOStop_422_UnknownTopic(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServerR(t, fp, &fakeResolver{err: ErrUnresolved})
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"t","stop_type":"finish","id_production_order":1,"production_order_quantity":1}`
	if rec := do(t, srv, "/operator/po/stop", testKey, body); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called when the topic cannot be resolved")
	}
}

// ── setup ────────────────────────────────────────────────────────────────────

func TestPOSetup_Mapping_OpenNext_Create(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"packml_topic":"GRANADO/JAPERI-UP1/MF5-OPACO/LINHA_D",
		"timestamp":"2026-07-09 15:00:00",
		"should_open_new_po":true,
		"should_create_po":true,
		"stop_type":"finish",
		"old_id_production_order":90012,
		"old_production_order_prod_final":4800,
		"id_order":218300,
		"production_order_quantity":6000,
		"nm_production_order":"FILME OPACO",
		"notes":"shift change"
	}`
	rec := do(t, srv, "/operator/po/setup", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/setup" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	got, ok := fp.last.body.(edgeSetupPO)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	want := edgeSetupPO{
		Timestamp:                   "2026-07-09 15:00:00",
		ShouldOpenNewPo:             true,
		StopType:                    "finish",
		IDEnterprise:                4,
		IDSite:                      resSite,      // resolved
		IDArea:                      resArea,      // resolved
		IDEquipment:                 resEquipment, // resolved
		OldIDProductionOrder:        90012,
		OldProductionOrderProdFinal: 4800,
		ShouldCreatePo:              true,
		IDOrder:                     218300,
		ProductionOrderQuantity:     6000,
		NmProductionOrder:           "FILME OPACO",
		TxtProductionOrderNotes:     "shift change",
	}
	if got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "po_setup", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

// Closing without opening a next PO: the open-next validation must not fire.
func TestPOSetup_Mapping_CloseOnly(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"t","should_open_new_po":false,"stop_type":"pause","old_id_production_order":1,"old_production_order_prod_final":50}`
	rec := do(t, srv, "/operator/po/setup", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if got := fp.last.body.(edgeSetupPO).ShouldOpenNewPo; got != false {
		t.Fatalf("shouldOpenNewPo should be false")
	}
}

func TestPOSetup_422_MissingShouldOpen(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"t","stop_type":"finish","old_id_production_order":1,"old_production_order_prod_final":50}`
	rec := do(t, srv, "/operator/po/setup", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "should_open_new_po") {
		t.Fatalf("422 should name should_open_new_po, got %s", rec.Body.String())
	}
}

// Opening a fresh PO without an order number must fail closed (don't open nothing).
func TestPOSetup_422_OpenCreateWithoutOrder(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","timestamp":"t","should_open_new_po":true,"should_create_po":true,"stop_type":"finish","old_id_production_order":1,"old_production_order_prod_final":50}`
	rec := do(t, srv, "/operator/po/setup", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "id_order") {
		t.Fatalf("422 should name id_order, got %s", rec.Body.String())
	}
}

// ── replace ──────────────────────────────────────────────────────────────────

func TestPOReplace_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_production_order":90045,"user":"op1"}`
	rec := do(t, srv, "/operator/po/replace", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/replace" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	want := edgeReplacePO{IDEnterprise: 4, IDEquipment: resEquipment, IDProductionOrder: 90045}
	if got := fp.last.body.(edgeReplacePO); got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "po_replace", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

func TestPOReplace_422_MissingPO(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L"}`
	if rec := do(t, srv, "/operator/po/replace", testKey, body); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
}

// ── change-status ────────────────────────────────────────────────────────────

func TestPOChangeStatus_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_production_order":90055}`
	rec := do(t, srv, "/operator/po/change-status", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/change-status" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	want := edgeChangeStatusPO{IDProductionOrder: 90055, IDEquipment: resEquipment}
	if got := fp.last.body.(edgeChangeStatusPO); got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	// idEnterprise still travels as the audit query param even though it's not in
	// the change-status body.
	if fp.last.idEnterprise != testEntID {
		t.Fatalf("idEnterprise query should be %d, got %d", testEntID, fp.last.idEnterprise)
	}
	if v := counterValue(t, reg, "po_change_status", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

// ── change-time ──────────────────────────────────────────────────────────────

func TestPOChangeTime_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 200, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"packml_topic":"GRANADO/L",
		"id_production_order_runtime":7001,
		"id_production_order":90055,
		"start":"2026-07-09T08:00:00.000Z",
		"end":"2026-07-09T09:00:00.000Z"
	}`
	rec := do(t, srv, "/operator/po/change-time", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/change-time" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	want := edgeChangeTimePO{
		IDProductionOrderRuntime: 7001,
		IDProductionOrder:        90055,
		IDEquipment:              resEquipment,
		Start:                    "2026-07-09T08:00:00.000Z",
		End:                      "2026-07-09T09:00:00.000Z",
	}
	if got := fp.last.body.(edgeChangeTimePO); got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "po_change_time", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

func TestPOChangeTime_422_MissingRuntime(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"packml_topic":"GRANADO/L","id_production_order":90055,"start":"2026-07-09T08:00:00.000Z"}`
	rec := do(t, srv, "/operator/po/change-time", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "id_production_order_runtime") {
		t.Fatalf("422 should name id_production_order_runtime, got %s", rec.Body.String())
	}
}
