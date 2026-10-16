package edgeapiclient

import (
	"context"
	"encoding/csv"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRowToProductionOrder(t *testing.T) {
	// Types are the ones database/sql hands back: int64/float64/[]byte/string.
	// int64 id_order and a whole-valued float64 quantity must render as plain
	// integers (no ".000000"); a fractional conversion_factor keeps precision.
	row := map[string]any{
		"id_order":           int64(12345),
		"nm_equipment":       []byte("LINE-A"),
		"nm_product":         "Widget",
		"production_ordered": float64(1000),
		"conversion_factor":  1.5,
	}
	po, err := RowToProductionOrder(row)
	if err != nil {
		t.Fatalf("RowToProductionOrder: %v", err)
	}
	if po.IDOrder != "12345" {
		t.Errorf("IDOrder = %q, want 12345", po.IDOrder)
	}
	if po.Line != "LINE-A" {
		t.Errorf("Line = %q, want LINE-A", po.Line)
	}
	if po.Product != "Widget" {
		t.Errorf("Product = %q, want Widget", po.Product)
	}
	if po.ProductionOrdered != "1000" {
		t.Errorf("ProductionOrdered = %q, want 1000", po.ProductionOrdered)
	}
	if po.ConversionFactor != "1.5" {
		t.Errorf("ConversionFactor = %q, want 1.5", po.ConversionFactor)
	}
}

func TestRowToProductionOrderAliasesAndTypes(t *testing.T) {
	// Alias keys (order_id / line) and int/float rendering.
	row := map[string]any{
		"order_id": 42,
		"line":     "PACKER",
	}
	po, err := RowToProductionOrder(row)
	if err != nil {
		t.Fatalf("RowToProductionOrder: %v", err)
	}
	if po.IDOrder != "42" || po.Line != "PACKER" {
		t.Fatalf("got IDOrder=%q Line=%q", po.IDOrder, po.Line)
	}
}

func TestRowToProductionOrderMissingRequired(t *testing.T) {
	// A row with no id_order, or no line, is a mapping error (skip-and-log at
	// the sink) — never a partial order.
	if _, err := RowToProductionOrder(map[string]any{"nm_equipment": "LINE-A"}); err == nil {
		t.Error("missing id_order: want error, got nil")
	}
	if _, err := RowToProductionOrder(map[string]any{"id_order": int64(1)}); err == nil {
		t.Error("missing line: want error, got nil")
	}
	// A present-but-blank required cell is also rejected.
	if _, err := RowToProductionOrder(map[string]any{"id_order": "  ", "nm_equipment": "LINE-A"}); err == nil {
		t.Error("blank id_order: want error, got nil")
	}
}

func TestUpsertProductionOrdersRequestShaping(t *testing.T) {
	var (
		gotMethod    string
		gotPath      string
		gotEnt       string
		gotAPIKey    string
		gotCSVRows   []map[string]string
		gotFileField bool
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotPath = r.URL.Path
		gotEnt = r.URL.Query().Get("idEnterprise")
		gotAPIKey = r.Header.Get("x-api-key")

		mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || !strings.HasPrefix(mediaType, "multipart/") {
			t.Errorf("unexpected content type %q (err=%v)", r.Header.Get("Content-Type"), err)
		}
		mr := multipart.NewReader(r.Body, params["boundary"])
		for {
			part, err := mr.NextPart()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatalf("read part: %v", err)
			}
			if part.FormName() != "file" {
				continue
			}
			gotFileField = true
			data, _ := io.ReadAll(part)
			gotCSVRows = parseServerCSV(t, string(data))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"rows":2}`))
	}))
	defer srv.Close()

	c := &Client{
		BaseURL:      srv.URL,
		APIKey:       "secret-key",
		EnterpriseID: 5,
		HTTP:         srv.Client(),
	}
	orders := []ProductionOrder{
		{IDOrder: "100", Line: "LINE-A", ProductionOrdered: "500"},
		{IDOrder: "101", Line: "LINE-B", Notes: "value, with comma"},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := c.UpsertProductionOrders(ctx, orders)
	if err != nil {
		t.Fatalf("UpsertProductionOrders: %v", err)
	}

	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotPath != "/api/admin/production-orders/csv/import" {
		t.Errorf("path = %q", gotPath)
	}
	if gotEnt != "5" {
		t.Errorf("idEnterprise = %q, want 5", gotEnt)
	}
	if gotAPIKey != "secret-key" {
		t.Errorf("x-api-key = %q, want secret-key", gotAPIKey)
	}
	if !gotFileField {
		t.Fatal(`no "file" form field received`)
	}
	if res.Rows != 2 {
		t.Errorf("Result.Rows = %d, want 2", res.Rows)
	}
	if len(gotCSVRows) != 2 {
		t.Fatalf("server parsed %d CSV rows, want 2: %+v", len(gotCSVRows), gotCSVRows)
	}
	if gotCSVRows[0]["ID ORDER"] != "100" || gotCSVRows[0]["LINE"] != "LINE-A" || gotCSVRows[0]["PRODUCTION ORDERED"] != "500" {
		t.Errorf("row0 = %+v", gotCSVRows[0])
	}
	// The comma inside a quoted field must survive the round-trip.
	if gotCSVRows[1]["NOTES"] != "value, with comma" {
		t.Errorf("row1 NOTES = %q, want %q", gotCSVRows[1]["NOTES"], "value, with comma")
	}
}

func TestUpsertProductionOrdersEmptyIsNoop(t *testing.T) {
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}
	res, err := c.UpsertProductionOrders(context.Background(), nil)
	if err != nil {
		t.Fatalf("empty upsert: %v", err)
	}
	if res.Rows != 0 || called {
		t.Errorf("empty upsert should not hit the server (called=%v, rows=%d)", called, res.Rows)
	}
}

func TestUpsertProductionOrdersNon2xxIsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"reason":"enum","element_error":"nm_equipment"}`))
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, HTTP: srv.Client()}
	_, err := c.UpsertProductionOrders(context.Background(), []ProductionOrder{{IDOrder: "1", Line: "NOPE"}})
	if err == nil {
		t.Fatal("400 response: want error, got nil")
	}
	if !strings.Contains(err.Error(), "status=400") || !strings.Contains(err.Error(), "nm_equipment") {
		t.Errorf("error should carry status + body snippet, got: %v", err)
	}
}

// parseServerCSV is a tiny stand-in for edge-api's parseCsv: it honours the
// `sep=,` first line and returns header-keyed rows, enough to assert the CSV we
// shaped is what the server would ingest.
func parseServerCSV(t *testing.T, body string) []map[string]string {
	t.Helper()
	r := csvReader(t, body)
	if len(r) < 2 {
		t.Fatalf("CSV has %d records, want header + data", len(r))
	}
	headers := r[0]
	var out []map[string]string
	for _, rec := range r[1:] {
		row := make(map[string]string)
		for i, h := range headers {
			if i < len(rec) {
				row[h] = rec[i]
			}
		}
		out = append(out, row)
	}
	return out
}

// csvReader parses body as RFC-4180 CSV, first stripping the leading `sep=,`
// hint line the client emits (mirroring edge-api's parseCsv, csv-parser.ts:165).
func csvReader(t *testing.T, body string) [][]string {
	t.Helper()
	if i := strings.IndexByte(body, '\n'); i >= 0 && strings.HasPrefix(strings.TrimSpace(body[:i]), "sep=") {
		body = body[i+1:]
	}
	records, err := csv.NewReader(strings.NewReader(body)).ReadAll()
	if err != nil {
		t.Fatalf("parse CSV: %v", err)
	}
	return records
}
