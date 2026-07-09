package adapter

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// fakePoster is the edge-api stand-in. It records the last call it received
// and returns a scripted result/error.
type fakePoster struct {
	last   *edgeCall
	result *edgeResult
	err    error
}

func (f *fakePoster) post(_ context.Context, call *edgeCall) (*edgeResult, error) {
	f.last = call
	if f.err != nil {
		return nil, f.err
	}
	return f.result, nil
}

const (
	testKey   = "operator-secret"
	testEntID = 4
)

func newTestServer(t *testing.T, poster edgePoster) (*Server, *Metrics, *prometheus.Registry) {
	t.Helper()
	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)
	cfg := Config{
		OperatorAPIKey: testKey,
		EnterpriseID:   testEntID,
		TopicPrefix:    "GRANADO",
	}
	srv := NewServer(cfg, poster, m, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return srv, m, reg
}

func do(t *testing.T, srv *Server, path, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Ingest-Key", key)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func counterValue(t *testing.T, reg *prometheus.Registry, action, outcome string) float64 {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	for _, mf := range mfs {
		if mf.GetName() != "operator_adapter_requests_total" {
			continue
		}
		for _, m := range mf.GetMetric() {
			var a, o string
			for _, l := range m.GetLabel() {
				switch l.GetName() {
				case "action":
					a = l.GetValue()
				case "outcome":
					o = l.GetValue()
				}
			}
			if a == action && o == outcome {
				return m.GetCounter().GetValue()
			}
		}
	}
	return 0
}

// ── auth ─────────────────────────────────────────────────────────────────────

func TestDowntime_401_MissingKey(t *testing.T) {
	srv, _, reg := newTestServer(t, &fakePoster{})
	rec := do(t, srv, "/operator/downtime", "", `{}`)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
	if got := counterValue(t, reg, "downtime", outcomeUnauthorized); got != 1 {
		t.Fatalf("want 1 unauthorized metric, got %v", got)
	}
}

func TestDowntime_401_WrongKey(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	rec := do(t, srv, "/operator/downtime", "wrong", `{}`)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

func TestPO_401_MissingKey(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	rec := do(t, srv, "/operator/po", "", `{}`)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

// ── scope (403) ──────────────────────────────────────────────────────────────

func TestDowntime_403_WrongEnterprise(t *testing.T) {
	srv, _, reg := newTestServer(t, &fakePoster{})
	body := `{"enterprise":7,"topic":"GRANADO/X","id_param":30810,"id_equipment":10,"cd_machine":"M","category":"C","category_desc":"D","ts_event":"2026-07-08T10:00:00Z","ts_end":"2026-07-08T11:00:00Z"}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
	if got := counterValue(t, reg, "downtime", outcomeForbidden); got != 1 {
		t.Fatalf("want 1 forbidden metric, got %v", got)
	}
}

func TestDowntime_403_WrongTopicPrefix(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	// No enterprise field; topic sits under a different tenant root.
	body := `{"topic":"OTHERCO/LINE","id_param":30810,"id_equipment":10,"cd_machine":"M","category":"C","category_desc":"D","ts_event":"2026-07-08T10:00:00Z","ts_end":"2026-07-08T11:00:00Z"}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
}

func TestPO_403_WrongEnterprise(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	body := `{"enterprise":99,"topic":"GRANADO/X","id_order":1,"id_site":2,"id_area":3,"id_equipment":4,"production_order_quantity":100,"timestamp":"2026-07-08 10:00:00"}`
	rec := do(t, srv, "/operator/po", testKey, body)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403, got %d", rec.Code)
	}
}

// ── downtime create mapping (202 + correct body) ─────────────────────────────

func TestDowntime_Create_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 201, body: []byte(`{}`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"topic":"GRANADO/JAPERI-UP1/MF5-OPACO/LINHA_D",
		"id_param":30810,
		"id_equipment":120,
		"cd_machine":"LINHA_D",
		"category":"TOOL",
		"category_desc":"Tooling",
		"subcategory":"ACC",
		"subcategory_desc":"Accumulator full",
		"txt_downtime":"added by operator",
		"ts_event":"2026-07-08T16:53:45.000Z",
		"ts_end":"2026-07-08T17:53:45.000Z",
		"user":"op1"
	}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last == nil {
		t.Fatal("edge-api was not called")
	}
	if fp.last.path != "/api/downtimes/create-manual-event" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	if fp.last.idEnterprise != testEntID {
		t.Fatalf("wrong idEnterprise: %d", fp.last.idEnterprise)
	}
	got, ok := fp.last.body.(edgeCreateDowntime)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	want := edgeCreateDowntime{
		CDCategory:       "TOOL",
		DescCategory:     "Tooling",
		CDMachine:        "LINHA_D",
		CDSubcategory:    "ACC",
		DescSubcategory:  "Accumulator full",
		TxtDowntimeNotes: "added by operator",
		IDEnterprise:     4,
		IDEquipment:      120,
		TSEvent:          "2026-07-08T16:53:45.000Z",
		TSEnd:            "2026-07-08T17:53:45.000Z",
	}
	if got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "downtime", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

// ── downtime edit mapping (manual_chg → edit-manual-event) ───────────────────

func TestDowntime_Edit_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 201, body: []byte(`{}`)}}
	srv, _, _ := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"topic":"GRANADO/LINE",
		"id_param":30812,
		"id_equipment":120,
		"id_equipment_event":10000,
		"cd_machine":"LINHA_D",
		"category":"TOOL",
		"category_desc":"Tooling",
		"subcategory":"ACC",
		"subcategory_desc":"Accumulator full",
		"txt_downtime":"corrected",
		"planned_dwt":true,
		"change_over":false,
		"idle":"no",
		"ts_event":"2026-07-08T16:00:00.000Z",
		"ts_end":"2026-07-08T17:00:00.000Z"
	}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/downtimes/edit-manual-event" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	got, ok := fp.last.body.(edgeEditDowntime)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	want := edgeEditDowntime{
		CDCategory:       "TOOL",
		DescCategory:     "Tooling",
		CDMachine:        "LINHA_D",
		CDSubcategory:    "ACC",
		DescSubcategory:  "Accumulator full",
		TxtDowntimeNotes: "corrected",
		PlannedDowntime:  true,
		Idle:             "no",
		ChangeOver:       false,
		IDEquipmentEvent: 10000,
		IDEquipment:      120,
		Start:            "2026-07-08T16:00:00.000Z",
		End:              "2026-07-08T17:00:00.000Z",
	}
	if got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
}

// ── downtime 422 unmapped ────────────────────────────────────────────────────

func TestDowntime_422_MissingEquipment(t *testing.T) {
	fp := &fakePoster{}
	srv, _, reg := newTestServer(t, fp)
	// No id_equipment.
	body := `{"enterprise":4,"topic":"GRANADO/L","id_param":30810,"cd_machine":"M","category":"C","category_desc":"D","ts_event":"2026-07-08T10:00:00Z","ts_end":"2026-07-08T11:00:00Z"}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called on unmapped input")
	}
	if !strings.Contains(rec.Body.String(), "id_equipment") {
		t.Fatalf("422 body should name the field, got %s", rec.Body.String())
	}
	if v := counterValue(t, reg, "downtime", outcomeUnmapped); v != 1 {
		t.Fatalf("want 1 unmapped metric, got %v", v)
	}
}

func TestDowntime_422_MissingEventIDOnEdit(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"topic":"GRANADO/L","id_param":30812,"id_equipment":1,"cd_machine":"M","category":"C","category_desc":"D","ts_event":"2026-07-08T10:00:00Z","ts_end":"2026-07-08T11:00:00Z"}`
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
}

// ── PO mapping ───────────────────────────────────────────────────────────────

func TestPO_Create_Mapping(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 201, body: []byte(`Success!`)}}
	srv, _, reg := newTestServer(t, fp)
	body := `{
		"enterprise":4,
		"topic":"GRANADO/JAPERI-UP1/MF5-OPACO/LINHA_D",
		"id_order":218237,
		"id_site":11,
		"id_area":22,
		"id_equipment":120,
		"production_order_quantity":5000,
		"timestamp":"2026-07-08 13:56:55",
		"nm_production_order":"FILME OPACO 50MIC",
		"user":"op1"
	}`
	rec := do(t, srv, "/operator/po", testKey, body)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("want 202, got %d (%s)", rec.Code, rec.Body.String())
	}
	if fp.last.path != "/api/production-orders/create-and-start" {
		t.Fatalf("wrong path: %s", fp.last.path)
	}
	got, ok := fp.last.body.(edgeCreateAndStartPO)
	if !ok {
		t.Fatalf("wrong body type: %T", fp.last.body)
	}
	want := edgeCreateAndStartPO{
		IDEnterprise:            4,
		IDSite:                  11,
		IDArea:                  22,
		IDEquipment:             120,
		IDOrder:                 218237,
		ProductionOrderQuantity: 5000,
		Timestamp:               "2026-07-08 13:56:55",
		NmProductionOrder:       "FILME OPACO 50MIC",
	}
	if got != want {
		t.Fatalf("body mismatch:\n got %+v\nwant %+v", got, want)
	}
	if v := counterValue(t, reg, "po", outcomeAccepted); v != 1 {
		t.Fatalf("want 1 accepted metric, got %v", v)
	}
}

func TestPO_422_MissingSite(t *testing.T) {
	fp := &fakePoster{}
	srv, _, _ := newTestServer(t, fp)
	body := `{"enterprise":4,"topic":"GRANADO/L","id_order":1,"id_area":3,"id_equipment":4,"production_order_quantity":100,"timestamp":"2026-07-08 10:00:00"}`
	rec := do(t, srv, "/operator/po", testKey, body)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("want 422, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "id_site") {
		t.Fatalf("422 should name id_site, got %s", rec.Body.String())
	}
	if fp.last != nil {
		t.Fatal("edge-api must NOT be called on unmapped input")
	}
}

// ── edge-api outcomes: 503 / 4xx passthrough / 5xx ───────────────────────────

func TestDowntime_503_EdgeUnreachable(t *testing.T) {
	fp := &fakePoster{err: errors.New("dial tcp: connection refused")}
	srv, _, reg := newTestServer(t, fp)
	body := validDowntime()
	rec := do(t, srv, "/operator/downtime", testKey, body)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d", rec.Code)
	}
	if v := counterValue(t, reg, "downtime", outcomeEdgeUnreachable); v != 1 {
		t.Fatalf("want 1 edge_unreachable metric, got %v", v)
	}
}

func TestDowntime_4xx_Passthrough(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 400, body: []byte(`{"message":"Start time must not be in the future!"}`)}}
	srv, _, reg := newTestServer(t, fp)
	rec := do(t, srv, "/operator/downtime", testKey, validDowntime())
	if rec.Code != 400 {
		t.Fatalf("want 400 passthrough, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "must not be in the future") {
		t.Fatalf("4xx body not passed through: %s", rec.Body.String())
	}
	if v := counterValue(t, reg, "downtime", outcomeEdge4xx); v != 1 {
		t.Fatalf("want 1 edge_4xx metric, got %v", v)
	}
}

func TestDowntime_5xx_BecomesBadGateway(t *testing.T) {
	fp := &fakePoster{result: &edgeResult{statusCode: 500, body: []byte(`boom`)}}
	srv, _, reg := newTestServer(t, fp)
	rec := do(t, srv, "/operator/downtime", testKey, validDowntime())
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want 502, got %d", rec.Code)
	}
	if v := counterValue(t, reg, "downtime", outcomeEdge5xx); v != 1 {
		t.Fatalf("want 1 edge_5xx metric, got %v", v)
	}
}

// ── misc ─────────────────────────────────────────────────────────────────────

func TestBadJSON_400(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	rec := do(t, srv, "/operator/downtime", testKey, `{not json`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
}

func TestHealthz(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("healthz not JSON: %v", err)
	}
}

func TestMethodNotAllowed(t *testing.T) {
	srv, _, _ := newTestServer(t, &fakePoster{})
	req := httptest.NewRequest(http.MethodGet, "/operator/downtime", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", rec.Code)
	}
}

func validDowntime() string {
	return `{"enterprise":4,"topic":"GRANADO/L","id_param":30810,"id_equipment":120,"cd_machine":"M","category":"C","category_desc":"D","ts_event":"2026-07-08T10:00:00Z","ts_end":"2026-07-08T11:00:00Z"}`
}
