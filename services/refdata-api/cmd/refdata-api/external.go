// external.go — ADR-0031 Workstream B: the anti-corruption shim (ACL) plane.
//
// WHY THIS IS SEPARATE FROM datasets.go
// ─────────────────────────────────────
// The front4 read plane (datasets.go / query.go) emits refdata's NATIVE wire
// shape: a bare JSON array of row objects, key order irrelevant, consumed by a
// key-based parser. The EXTERNAL contracts are the opposite: each is a foreign,
// idiosyncratic envelope frozen to a specific third-party parser — NEOPAC's SAP
// integration expects `{data}` (sap-report) and `{page,limit,results,data}`
// (sap-report-sync); Montebello, Incoplast and PowerBI each carry their own.
//
// Eric Evans' Anti-Corruption Layer names this exactly: a translation membrane
// at the boundary that (a) keeps a foreign contract's idioms out of our clean
// internal model, and — the load-bearing half here — (b) keeps OUR model's
// evolution from breaking THEIR parser. The external quirks (the `{data}` key,
// string pagination, `[Z]` timestamps, German columns) ARE the contract:
// freezing them byte-for-byte is the job, not cleaning them up.
//
// THE TENANT FENCE, RESTATED FOR FROZEN VIEWS (ADR-0027 authority, no literal)
// ───────────────────────────────────────────────────────────────────────────
// back4's controllers hardcode `id_enterprise == 13` (a literal) and read a
// customer-frozen view (v_13_site_deb_sap_report, v_sap_report_data_sync_customer_13).
// refdata is the single tenant-injection authority: the `== 13` literal becomes
// a per-consumer OWNER BINDING resolved from config (ownerEnv → customer_id),
// and the incoming x-api-key resolves through the SAME QUERY_API_KEYS map the
// rest of the service uses (key → customer_id). Two forms of fence, one
// authority:
//
//   - sap-report resolves lineCode→id_equipment via a REAL `WHERE id_enterprise
//     = $1` on `equipments` (the injected customer_id) — a genuine $1 fence.
//   - sap-report-sync reads a customer-frozen view that has NO id_enterprise
//     column, so there is nothing to fence in SQL; the ENTIRE tenant fence is
//     the owner-binding assertion at the membrane (resolved cid must equal the
//     shim's bound owner, else 401). This is the honest reality of a frozen
//     customer-specific view — the authorization layer IS the fence.
//
// Either way the invariant holds: only the bound customer's key reaches the
// bound customer's data, and no id_enterprise literal lives in this file.
//
// ADDING A CONSUMER (Montebello / Incoplast / PowerBI-read) IS A REGISTRY ENTRY
// ────────────────────────────────────────────────────────────────────────────
// Append an externalShim to externalShims: declare its path, its ownerEnv, a
// run() that reads under the fence and reshapes rows via an envelope helper
// (envData / envPageLimitResults / a new one), and its backing views for the
// drift gate. The shared membrane (auth-shape reproduction, owner binding,
// byte-identical encoding, timeout, metrics) is written ONCE here. No handler
// rewrite — that is the whole point of an ACL registry.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ── The frozen-contract row model (column-ordered, unlike native maps) ───────
//
// externalRows preserves the backing view's COLUMN ORDER. node-postgres builds
// each row object by iterating result.fields in order, and JS objects preserve
// string-key insertion order — so a byte-identical `data` array requires column
// order. refdata's native map[string]any output loses it (encoding/json sorts
// map keys), which is exactly why the external plane cannot reuse it.
type externalRows struct {
	cols []string
	rows [][]any
}

// MarshalJSON emits `[{col:val,...},...]` in column order, values normalized to
// their node-postgres/JSON.stringify wire form. It is the reshaping primitive
// every envelope wraps.
func (er externalRows) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('[')
	for i, row := range er.rows {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('{')
		for j, col := range er.cols {
			if j > 0 {
				b.WriteByte(',')
			}
			key, err := marshalNoEscape(col)
			if err != nil {
				return nil, err
			}
			b.Write(key)
			b.WriteByte(':')
			var v any
			if j < len(row) {
				v = normalizeExternalValue(row[j])
			}
			val, err := marshalNoEscape(v)
			if err != nil {
				return nil, err
			}
			b.Write(val)
		}
		b.WriteByte('}')
	}
	b.WriteByte(']')
	return b.Bytes(), nil
}

// normalizeExternalValue maps a Go/pgx value to the exact JSON wire form
// node-postgres + Express res.json would emit, for the types we can pin from
// source. Strings/ints/bools already match encoding/json. The one non-trivial
// pin is time.Time: node-pg returns a JS Date, and JSON.stringify(date) is
// Date.prototype.toISOString() — UTC, millisecond precision, trailing `Z`.
//
// NOT pinned here (deliberately — see the report + the golden test's scope):
// Postgres numeric/decimal. node-postgres returns numeric columns as STRINGS by
// default; pgx returns them as a numeric Go type. Which columns are numeric is a
// property of the live view DDL that cannot be read from the back4 controller
// source (it does `SELECT *`). That parity is the ADR §3c step-3 SHADOW-DIFF
// item, gated before cutover — never silently assumed here.
func normalizeExternalValue(v any) any {
	switch t := v.(type) {
	case time.Time:
		return t.UTC().Format("2006-01-02T15:04:05.000Z07:00")
	default:
		return v
	}
}

// marshalNoEscape encodes v the way Express res.json does: JSON.stringify does
// NOT HTML-escape `<`, `>`, `&` (Go's default encoder DOES → < etc., which
// would break byte-identity on any German column carrying `&`/`<`), and it emits
// no trailing newline. SetEscapeHTML(false) also means a nested json.Marshaler
// (externalRows) is compacted WITHOUT re-escaping — so the whole envelope stays
// un-escaped in one consistent pass.
func marshalNoEscape(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// ── Envelope adapters — the reusable reshaping membrane ──────────────────────
//
// Each is a STRUCT (never a map) so encoding/json emits fields in DECLARATION
// order — the frozen envelope key order. A map would alphabetize the keys and
// break byte-identity (`{data,limit,page,results}` ≠ `{page,limit,results,data}`).

// envData is NEOPAC sap-report's frozen `{data}` envelope. (Montebello's
// data-sync `{page,results,data}` and Incoplast's `{newData}` will get their own
// structs alongside this one when those families land.)
type envData struct {
	Data externalRows `json:"data"`
}

// envPageLimitResults is NEOPAC sap-report-sync's frozen `{page,limit,results,data}`
// envelope. page/limit are ints (back4 `parseInt`s them); results is the count
// of returned rows (back4 `data?.length`).
type envPageLimitResults struct {
	Page    int          `json:"page"`
	Limit   int          `json:"limit"`
	Results int          `json:"results"`
	Data    externalRows `json:"data"`
}

// ── The reader — an injectable row source (golden harness needs no DB) ───────

type externalReader interface {
	query(ctx context.Context, sql string, args ...any) (externalRows, error)
}

// pgxExternalReader is the production reader: it runs the SQL and captures the
// column order from pgx field descriptions (the byte-identity requirement).
type pgxExternalReader struct{ pool *pgxpool.Pool }

func (p pgxExternalReader) query(ctx context.Context, sql string, args ...any) (externalRows, error) {
	rows, err := p.pool.Query(ctx, sql, args...)
	if err != nil {
		return externalRows{}, err
	}
	defer rows.Close()
	fds := rows.FieldDescriptions()
	cols := make([]string, len(fds))
	for i, fd := range fds {
		cols[i] = string(fd.Name)
	}
	var data [][]any
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return externalRows{}, err
		}
		data = append(data, vals)
	}
	if rows.Err() != nil {
		return externalRows{}, rows.Err()
	}
	return externalRows{cols: cols, rows: data}, nil
}

// shimDeps is what a run() closure sees. deps.query mirrors back4's db.query
// semantics EXACTLY: on any error it logs and returns an empty result — because
// back4's `db.query` catches every error and returns `[]` (see back4-api
// src/db/database.js). A DB blip on the data read there yields `{data:[]}` / a
// 404, never a 500; reproducing that swallow keeps the frozen contract intact.
// (Genuine divergence is caught by the §3c shadow diff, which compares live
// bytes against the still-running back4.)
type shimDeps struct {
	reader externalReader
	logger *slog.Logger
	path   string
}

func (d shimDeps) query(ctx context.Context, sql string, args ...any) externalRows {
	rows, err := d.reader.query(ctx, sql, args...)
	if err != nil {
		if d.logger != nil {
			d.logger.Warn("external shim query error (mirroring back4 db.query→[])",
				slog.String("path", d.path), slog.String("err", err.Error()))
		}
		return externalRows{}
	}
	return rows
}

// ── The frozen error responses (byte-identical to back4's res.status().send()) ─
//
// Express `res.send(string)` sets `Content-Type: text/html; charset=utf-8` and
// writes the raw string with no trailing newline. These reproduce back4's exact
// status + body for the error matrix the golden harness asserts.
type shimError struct {
	status      int
	body        string
	contentType string // "" ⇒ text/html; charset=utf-8 (Express .send default)
}

var (
	errMissingAPIKey = shimError{status: http.StatusBadRequest, body: "x-api-key is required!"}
	errUnauthorized  = shimError{status: http.StatusUnauthorized, body: "Unauthorized access"}
)

func writeShimError(w http.ResponseWriter, e shimError) {
	ct := e.contentType
	if ct == "" {
		ct = "text/html; charset=utf-8"
	}
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(e.status)
	_, _ = w.Write([]byte(e.body))
}

// ── The registry ─────────────────────────────────────────────────────────────

type shimRunner func(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError)

// externalShim is one frozen external-contract endpoint. Adding a consumer =
// appending one of these — the membrane below is shared.
type externalShim struct {
	consumer string // registry/documentation key ("neopac")
	path     string // internal mux path (devops maps the external URL here, OQ3)
	ownerEnv string // env naming the bound customer_id (config; NEVER a literal)
	run      shimRunner
	// backingViews / guardRelations feed the pre-flip contract-drift gate
	// (existence-only): the frozen view MUST exist in prod or the flip is blocked.
	backingViews   []string
	guardRelations []string
}

// externalShims is the Family-A (ERP/BI data-sync READ) registry. This PR ships
// the two NEOPAC SAP shims as the proof-of-pattern; Montebello, Incoplast and
// the PowerBI-read follow as further entries (PowerBI's credential BROKER is
// Family B → edge-api, not here — it holds an outbound secret, ADR-0031 §3b).
var externalShims = []externalShim{
	{
		consumer:       "neopac",
		path:           "/ext/neopac/sap-report",
		ownerEnv:       "EXTERNAL_NEOPAC_CUSTOMER_ID",
		run:            runNeopacSapReport,
		backingViews:   []string{"v_13_site_deb_sap_report"},
		guardRelations: []string{"equipments"},
	},
	{
		consumer:     "neopac",
		path:         "/ext/neopac/sap-report-sync",
		ownerEnv:     "EXTERNAL_NEOPAC_CUSTOMER_ID",
		run:          runNeopacSapReportSync,
		backingViews: []string{"v_sap_report_data_sync_customer_13"},
	},
}

// ── The NEOPAC SAP shims (frozen shapes pinned from the back4 controllers) ───

// runNeopacSapReport reproduces sap-report.controller.js:
//   - resolve lineCode → id_equipment on `equipments`, tenant-fenced by $1
//     (the `id_enterprise = 13` literal is now the injected customer_id);
//   - 404 "Line code not found" when no equipment matches;
//   - read the frozen v_13_site_deb_sap_report by that equipment;
//   - return the frozen `{data}` envelope.
func runNeopacSapReport(ctx context.Context, deps shimDeps, cid int, r *http.Request) (any, *shimError) {
	lineCode := r.URL.Query().Get("lineCode")
	// $1 = injected customer_id (the real tenant fence); $2 = lineCode (UPPER()'d
	// in SQL exactly as back4 did).
	eq := deps.query(ctx,
		`SELECT id_equipment FROM equipments WHERE cd_equipment = UPPER($2) AND id_enterprise = $1`,
		cid, lineCode)
	if len(eq.rows) == 0 {
		return nil, &shimError{status: http.StatusNotFound, body: "Line code not found"}
	}
	idEquipment := eq.rows[0][0]
	data := deps.query(ctx,
		`SELECT * FROM v_13_site_deb_sap_report WHERE id_equipment = $1`, idEquipment)
	return envData{Data: data}, nil
}

// runNeopacSapReportSync reproduces data-sync.controller.js:
//   - optional German filters auftrag/linie/tag/shicht/shicht_nummer (linie
//     upper-cased), bound positionally exactly as back4 built them;
//   - LIMIT/OFFSET pagination, offset = (page-1)*limit, defaults page=1 limit=1000;
//   - the frozen `{page,limit,results,data}` envelope (page/limit as ints,
//     results = row count).
//
// The frozen view v_sap_report_data_sync_customer_13 has no id_enterprise column
// (it is pre-scoped to customer 13), so there is no $1 in this SQL — the tenant
// fence is the owner-binding assertion in the membrane. See the file header.
func runNeopacSapReportSync(ctx context.Context, deps shimDeps, _ int, r *http.Request) (any, *shimError) {
	q := r.URL.Query()
	page := parseIntDefault(q.Get("page"), 1)
	limit := parseIntDefault(q.Get("limit"), 1000)

	var conds []string
	var params []any
	add := func(col string, val any) {
		params = append(params, val)
		conds = append(conds, fmt.Sprintf("%s = $%d", col, len(params)))
	}
	if v := q.Get("auftrag"); v != "" {
		add("auftrag", v)
	}
	if v := q.Get("linie"); v != "" {
		add("linie", strings.ToUpper(v)) // back4: linie.toUpperCase()
	}
	if v := q.Get("tag"); v != "" {
		add("tag", v)
	}
	if v := q.Get("shicht"); v != "" {
		add("shicht", v)
	}
	if v := q.Get("shicht_nummer"); v != "" {
		add("shicht_nummer", v)
	}

	sql := "SELECT * FROM v_sap_report_data_sync_customer_13"
	if len(conds) > 0 {
		sql += " WHERE " + strings.Join(conds, " AND ")
	}
	params = append(params, limit)
	limitIdx := len(params)
	params = append(params, (page-1)*limit)
	offsetIdx := len(params)
	sql += fmt.Sprintf(" LIMIT $%d OFFSET $%d", limitIdx, offsetIdx)

	data := deps.query(ctx, sql, params...)
	return envPageLimitResults{Page: page, Limit: limit, Results: len(data.rows), Data: data}, nil
}

// parseIntDefault mirrors back4's `const { page = 1 } = req.query` + `parseInt`:
// absent or non-integer ⇒ the default. (back4's `parseInt("abc")` → NaN →
// JSON `null` is a degenerate edge a real SAP client never sends; the shim uses
// the default instead of emitting null — noted, not reproduced.)
func parseIntDefault(s string, def int) int {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return n
}

// ── The shared membrane (auth reproduction + owner binding + byte encoding) ──

// makeExternalHandler builds the HTTP handler for one shim. It reproduces back4's
// auth STATUS SHAPES exactly (missing key → 400, unknown/wrong-owner → 401) while
// routing the tenant through refdata's single authority (the QUERY_API_KEYS map).
//
// owner is resolved once at registration from ownerEnv. owner == 0 (env unset)
// means EVERY request 401s — no real customer_id is 0 — so a mis-provisioned shim
// fails closed rather than serving another tenant's frozen view.
func makeExternalHandler(sh externalShim, reader externalReader, keys map[string]int, owner int, logger *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// 1) Reproduce back4's auth contract byte-for-byte, but resolve the
		//    tenant through refdata's key→customer_id authority (no `== 13`).
		apiKey := r.Header.Get("x-api-key")
		if apiKey == "" {
			writeShimError(w, errMissingAPIKey) // 400 "x-api-key is required!"
			return
		}
		cid, ok := keys[apiKey]
		if !ok || cid != owner {
			// Unknown key OR a valid key bound to a DIFFERENT customer → 401.
			// This is the tenant fence for the frozen customer-scoped view: no
			// data read happens, so there is no cross-tenant leak.
			writeShimError(w, errUnauthorized) // 401 "Unauthorized access"
			return
		}
		// 2) Run the frozen read + reshape under the $1 = cid fence.
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		body, serr := sh.run(ctx, shimDeps{reader: reader, logger: logger, path: sh.path}, cid, r)
		if serr != nil {
			writeShimError(w, *serr)
			return
		}
		// 3) Encode the frozen envelope byte-identically to Express res.json.
		out, err := marshalNoEscape(body)
		if err != nil {
			failed.Add(1)
			http.Error(w, `{"error":"encode failed"}`, http.StatusInternalServerError)
			return
		}
		served.Add(1)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(out)
	}
}

// registerExternalShims mounts every Family-A shim on the mux. Called from main
// AFTER the key map is parsed and BEFORE the auth middleware wraps the mux — the
// external routes self-authenticate (they are in the auth-exempt set) so they can
// reproduce the foreign 400/401 shapes, but they still resolve the tenant through
// the SAME key map, so refdata remains the single injection authority.
func registerExternalShims(mux *http.ServeMux, pool *pgxpool.Pool, keys map[string]int, logger *slog.Logger) {
	reader := pgxExternalReader{pool: pool}
	for _, sh := range externalShims {
		owner := getenvInt(sh.ownerEnv, 0)
		if owner == 0 {
			logger.Warn("external shim owner unset — endpoint fails closed (401 all)",
				slog.String("consumer", sh.consumer), slog.String("path", sh.path),
				slog.String("owner_env", sh.ownerEnv))
		}
		mux.HandleFunc(sh.path, makeExternalHandler(sh, reader, keys, owner, logger))
	}
	logger.Info("external-contract shims registered (ADR-0031 Family-A)",
		slog.Int("shims", len(externalShims)))
}

// externalRoutes exposes the shim paths for the route manifest (auth exemption +
// the CI isolation gate). Classed routeExternalShim: exempt from the native auth
// middleware (they self-auth), but still gated for tenant safety by the owner
// binding (external_golden_test.go proves wrong-tenant → 401, no leak).
func externalRoutes() []mountedRoute {
	out := make([]mountedRoute, 0, len(externalShims))
	for _, sh := range externalShims {
		out = append(out, mountedRoute{sh.path, routeExternalShim})
	}
	return out
}

func getenvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
