// Package edgeapiclient is the server-to-server client the edge-transformer
// uses to push production orders read out of a customer's ERP (via
// internal/erpconnector) into the platform through edge-api.
//
// # Why the CSV bulk-import endpoint (ADR-0019 P1b)
//
// edge-api exposes several PO-control routes, but only ONE is a genuinely
// IDEMPOTENT upsert keyed by the ERP's own order id:
//
//	POST /api/admin/production-orders/csv/import?idEnterprise=<id>
//	  (edge-api/src/usecases/production-orders/import-po-csv/
//	   import-po-csv.controller.ts:29,33 — multipart field "file")
//
// Its service documents "idempotent: re-importing the same file upserts on
// (id_enterprise, id_order)" (import-po-csv.service.ts:26-27) and writes
// through PoImportDAO.bulkUpsert. The obvious single-row alternative,
// POST /api/production-orders/create, is create-ONLY: it throws
// "Production order already exists" on a duplicate id_order
// (create-production-order.service.ts:30-31), so a cadence-driven re-read
// would fail on every order it already synced. The CSV endpoint is therefore
// the correct target, and it fits the connector's grain naturally — one ERP
// read cycle yields a batch of rows → one CSV → one atomic idempotent import.
//
// # The documented compromises
//
//   - It is a multipart CSV batch endpoint, not a single-row JSON PUT. We
//     synthesize the CSV in-process (canonical English headers from the
//     server's PO_CSV_DICTIONARY, po-csv-mapper.ts).
//   - The import is fail-closed and ATOMIC: edge-api rejects the WHOLE batch
//     (HTTP 400) if any row is invalid — most commonly an unknown LINE, since
//     validateRows requires nm_equipment to match an existing tp=3 line
//     (po-csv-mapper.ts:245-261). We surface that 400 body to the caller so a
//     misconfigured line name is diagnosable, rather than swallowing it.
//
// # Auth
//
// edge-api's AuthMiddleware guards /api/* (app.module.ts:402,407) and prefers
// the `x-api-key` header (auth.middleware.ts:154). The key is the enterprise's
// own api_key; authorize() requires that the `?idEnterprise=` and the key
// resolve to the SAME active enterprise (auth-apikey-dao.ts:41-52). So a caller
// sends both the api-key header and the matching enterprise id.
package edgeapiclient

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// DefaultTimeout bounds a single import request. An ERP sync is low-QPS and a
// batch import is transactional server-side, so a generous-but-finite budget
// keeps a stalled edge-api from wedging the read cadence.
const DefaultTimeout = 30 * time.Second

// Client posts production-order upserts to a single enterprise's edge-api.
type Client struct {
	// BaseURL is the edge-api origin, e.g. https://edge.api.staging.packiot.app.
	BaseURL string
	// APIKey is the enterprise's api_key, sent as the x-api-key header.
	APIKey string
	// EnterpriseID is the caller's enterprise; it MUST own APIKey (edge-api
	// rejects a mismatch) and is sent as the ?idEnterprise= query.
	EnterpriseID int
	// HTTP is the client used for the request. nil → a DefaultTimeout client.
	HTTP *http.Client
}

// ProductionOrder is the platform-shaped PO the connector upserts. Every field
// is optional except IDOrder + Line, which the CSV importer requires. Strings
// are used throughout because the endpoint is CSV (text) and locale-tolerant
// numeric coercion happens server-side (po-csv-mapper.ts) — keeping the values
// as text avoids re-implementing that coercion here.
type ProductionOrder struct {
	IDOrder              string // required; server validates it is an integer
	Line                 string // required; must match an existing tp=3 line
	Product              string
	Client               string
	ProductionOrdered    string
	ProductionProgrammed string
	IdealProduction      string
	PlannedDowntime      string
	ConversionFactor     string
	Notes                string
	Description          string
}

// Result is what an import returned.
type Result struct {
	// Rows is the server-reported number of upserted rows ({ "rows": N }).
	Rows int
}

// csvColumn binds a canonical edge-api CSV header to the ProductionOrder field
// it is sourced from. The headers are the English keys of the server's
// PO_CSV_DICTIONARY (po-csv-mapper.ts) so renameRows maps them 1:1.
var csvColumns = []struct {
	header string
	value  func(ProductionOrder) string
}{
	{"ID ORDER", func(p ProductionOrder) string { return p.IDOrder }},
	{"LINE", func(p ProductionOrder) string { return p.Line }},
	{"PRODUCT", func(p ProductionOrder) string { return p.Product }},
	{"CLIENT", func(p ProductionOrder) string { return p.Client }},
	{"PRODUCTION ORDERED", func(p ProductionOrder) string { return p.ProductionOrdered }},
	{"PRODUCTION PROGRAMMED", func(p ProductionOrder) string { return p.ProductionProgrammed }},
	{"IDEAL PRODUCTION", func(p ProductionOrder) string { return p.IdealProduction }},
	{"PLANNED DOWNTIME", func(p ProductionOrder) string { return p.PlannedDowntime }},
	{"CONVERSION FACTOR", func(p ProductionOrder) string { return p.ConversionFactor }},
	{"NOTES", func(p ProductionOrder) string { return p.Notes }},
	{"DESCRIPTION", func(p ProductionOrder) string { return p.Description }},
}

// UpsertProductionOrders imports a batch of orders through the idempotent CSV
// endpoint. Empty input is a no-op (posting an empty CSV would 400). A non-2xx
// response is returned as an error carrying the status and a body snippet — an
// atomic import rejects the whole batch, and the body says which row/field.
func (c *Client) UpsertProductionOrders(ctx context.Context, orders []ProductionOrder) (Result, error) {
	if len(orders) == 0 {
		return Result{}, nil
	}
	if c.BaseURL == "" {
		return Result{}, fmt.Errorf("edgeapiclient: BaseURL not configured")
	}

	body, contentType, err := buildMultipartCSV(orders)
	if err != nil {
		return Result{}, err
	}

	url := fmt.Sprintf("%s/api/admin/production-orders/csv/import?idEnterprise=%d",
		strings.TrimRight(c.BaseURL, "/"), c.EnterpriseID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("Content-Type", contentType)
	if c.APIKey != "" {
		req.Header.Set("x-api-key", c.APIKey)
	}

	httpc := c.HTTP
	if httpc == nil {
		httpc = &http.Client{Timeout: DefaultTimeout}
	}
	resp, err := httpc.Do(req)
	if err != nil {
		return Result{}, fmt.Errorf("edgeapiclient: import request: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Result{}, fmt.Errorf("edgeapiclient: import rejected: status=%d body=%s",
			resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	// Success body is { "rows": N } (ImportPoCsvOutputDto). Missing/garbled
	// count is not fatal — the upsert already committed server-side.
	var out struct {
		Rows int `json:"rows"`
	}
	_ = json.Unmarshal(respBody, &out)
	return Result{Rows: out.Rows}, nil
}

// buildMultipartCSV renders the orders as a CSV and wraps it in a
// multipart/form-data body under the "file" field the FileInterceptor expects.
// A leading `sep=,` line pins the delimiter so the server's sniffer can never
// mis-detect it (csv-parser.ts:165), even for a batch whose only populated
// column is ID ORDER.
func buildMultipartCSV(orders []ProductionOrder) (body []byte, contentType string, err error) {
	var csvBuf bytes.Buffer
	csvBuf.WriteString("sep=,\n")
	w := csv.NewWriter(&csvBuf)

	header := make([]string, len(csvColumns))
	for i, col := range csvColumns {
		header[i] = col.header
	}
	if err := w.Write(header); err != nil {
		return nil, "", err
	}
	for _, po := range orders {
		record := make([]string, len(csvColumns))
		for i, col := range csvColumns {
			record[i] = col.value(po)
		}
		if err := w.Write(record); err != nil {
			return nil, "", err
		}
	}
	w.Flush()
	if err := w.Error(); err != nil {
		return nil, "", err
	}

	var mpBuf bytes.Buffer
	mw := multipart.NewWriter(&mpBuf)
	part, err := mw.CreateFormFile("file", "production_orders.csv")
	if err != nil {
		return nil, "", err
	}
	if _, err := part.Write(csvBuf.Bytes()); err != nil {
		return nil, "", err
	}
	if err := mw.Close(); err != nil {
		return nil, "", err
	}
	return mpBuf.Bytes(), mw.FormDataContentType(), nil
}

// rowKeys maps each ProductionOrder field to the ERP-row column names it may
// arrive under. The FIRST present, non-empty key wins. The canonical names are
// the platform's internal column names (po-csv-mapper.ts targets); the extra
// aliases cover the common camelCase/plain variants a read SQL might select.
var rowKeys = map[string][]string{
	"id_order":              {"id_order", "order_id", "idOrder"},
	"nm_equipment":          {"nm_equipment", "nm_line", "line", "equipment"},
	"nm_product":            {"nm_product", "product"},
	"nm_client":             {"nm_client", "client"},
	"production_ordered":    {"production_ordered", "ordered"},
	"production_programmed": {"production_programmed", "programmed"},
	"ideal_production":      {"ideal_production"},
	"planned_downtime":      {"planned_downtime"},
	"conversion_factor":     {"conversion_factor"},
	"notes":                 {"txt_production_order_notes", "notes"},
	"description":           {"txt_production_order_description", "description"},
}

// RowToProductionOrder maps one erpconnector read row (column → scanned value)
// onto a ProductionOrder. It is defensive about the Go types database/sql hands
// back (int64/float64/[]byte/string/bool/time.Time/nil) and returns an error —
// rather than a partial order — when a REQUIRED field (id_order, nm_equipment)
// is absent or blank, so the caller can skip-and-log the bad row and still
// import the good ones up to the batch. The map[string]any signature (rather
// than erpconnector.Row) keeps this package decoupled from the connector;
// erpconnector.Row IS a map[string]any, so it passes through directly.
func RowToProductionOrder(row map[string]any) (ProductionOrder, error) {
	idOrder := pick(row, rowKeys["id_order"])
	if idOrder == "" {
		return ProductionOrder{}, fmt.Errorf("edgeapiclient: row missing required id_order (looked for %v)", rowKeys["id_order"])
	}
	line := pick(row, rowKeys["nm_equipment"])
	if line == "" {
		return ProductionOrder{}, fmt.Errorf("edgeapiclient: row for id_order=%s missing required line/equipment name (looked for %v)", idOrder, rowKeys["nm_equipment"])
	}
	return ProductionOrder{
		IDOrder:              idOrder,
		Line:                 line,
		Product:              pick(row, rowKeys["nm_product"]),
		Client:               pick(row, rowKeys["nm_client"]),
		ProductionOrdered:    pick(row, rowKeys["production_ordered"]),
		ProductionProgrammed: pick(row, rowKeys["production_programmed"]),
		IdealProduction:      pick(row, rowKeys["ideal_production"]),
		PlannedDowntime:      pick(row, rowKeys["planned_downtime"]),
		ConversionFactor:     pick(row, rowKeys["conversion_factor"]),
		Notes:                pick(row, rowKeys["notes"]),
		Description:          pick(row, rowKeys["description"]),
	}, nil
}

// pick returns the string form of the first present, non-empty candidate key.
func pick(row map[string]any, keys []string) string {
	for _, k := range keys {
		if v, ok := row[k]; ok {
			if s := cellToString(v); s != "" {
				return s
			}
		}
	}
	return ""
}

// cellToString renders a database/sql-scanned value as the text the CSV needs.
// Integer-valued floats render WITHOUT a decimal point ("12345", not
// "12345.000000") so an id_order/quantity that came back as float64 still
// passes the server's integer regex; genuine fractionals ("1.5") keep minimal
// precision for conversion_factor.
func cellToString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(t)
	case []byte:
		return strings.TrimSpace(string(t))
	case bool:
		return strconv.FormatBool(t)
	case int:
		return strconv.Itoa(t)
	case int32:
		return strconv.FormatInt(int64(t), 10)
	case int64:
		return strconv.FormatInt(t, 10)
	case float32:
		return floatToString(float64(t))
	case float64:
		return floatToString(t)
	case time.Time:
		return t.UTC().Format(time.RFC3339)
	default:
		return strings.TrimSpace(fmt.Sprintf("%v", t))
	}
}

func floatToString(f float64) string {
	if f == math.Trunc(f) && !math.IsInf(f, 0) {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'f', -1, 64)
}
