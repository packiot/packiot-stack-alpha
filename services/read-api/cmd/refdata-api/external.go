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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
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
	// momentZ names the columns a consumer's VALUE adapter reformats from the
	// default toISOString form (millisecond `.000Z`) to moment's
	// `YYYY-MM-DDTHH:mm:ss[Z]` (second precision, literal Z). back4's Montebello/
	// Incoplast controllers post-process ts_event/ts_end/last_update through
	// moment(...).utc().format(...); reproducing the ENVELOPE reshape is not
	// enough — the timestamp VALUE must match too. Empty ⇒ every timestamp uses
	// the default toISOString pin. See withMomentZColumns / momentZFormat.
	momentZ map[string]bool
	// dateOnly names columns a consumer's DAO renders with dayjs(...).format(
	// 'YYYY-MM-DD') — a DATE string, no time-of-day, no zone suffix. This is a
	// THIRD timestamp form (distinct from both toISOString `.000Z` and momentZ's
	// `[Z]`): get-shift-validation's ShiftsValidationDAO.findByTopic post-formats
	// ts_value_production this way. Empty ⇒ no column uses it. See
	// withDateOnlyColumns / dateOnlyFormat. (Zone-of-parse for naive timestamps is
	// the §3c shadow-diff; the FORMAT is what is pinned here.)
	dateOnly map[string]bool
}

// withMomentZColumns marks the given columns to be rendered with moment's
// `[Z]` timestamp format instead of the default toISOString. Returns a copy so
// the underlying reader result is never mutated (the reader is shared/scripted).
func (er externalRows) withMomentZColumns(cols ...string) externalRows {
	m := make(map[string]bool, len(cols))
	for _, c := range cols {
		m[c] = true
	}
	er.momentZ = m
	return er
}

// withDateOnlyColumns marks columns to be rendered as a dayjs `YYYY-MM-DD` date
// string (get-shift-validation's ts_value_production). Returns a copy so the
// shared reader result is never mutated.
func (er externalRows) withDateOnlyColumns(cols ...string) externalRows {
	m := make(map[string]bool, len(cols))
	for _, c := range cols {
		m[c] = true
	}
	er.dateOnly = m
	return er
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
			// A jsonb/json column, already reserialized to node-pg's exact form by
			// the reader (see nodePgJSONText): emit it VERBATIM as a JSON value
			// (object/array/scalar), never quoted. A nil rawJSON is a SQL NULL.
			if j < len(row) {
				if rj, ok := row[j].(rawJSON); ok {
					if rj == nil {
						b.WriteString("null")
					} else {
						b.Write(rj)
					}
					continue
				}
			}
			var v any
			if j < len(row) {
				if t, ok := row[j].(time.Time); ok && er.momentZ[col] {
					// Per-consumer VALUE adapter: moment(...).utc().format(
					// 'YYYY-MM-DDTHH:mm:ss[Z]'). back4 guards `if (item.col)`,
					// so a NULL (nil, not a time.Time) is left untouched → the
					// type assertion fails and it falls through to null below.
					v = momentZFormat(t)
				} else if t, ok := row[j].(time.Time); ok && er.dateOnly[col] {
					// dayjs(...).format('YYYY-MM-DD') — a NULL falls through to
					// null (the type assertion fails on nil), same guard shape.
					v = dateOnlyFormat(t)
				} else {
					v = normalizeExternalValue(row[j])
				}
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
// Postgres numeric/decimal/bigint parity (the ADR §3c step-3 SHADOW-DIFF) is NOT
// handled here — it is resolved one layer UP, in pgxExternalReader.query: those
// OIDs are forced onto the text wire and their raw Postgres text is substituted
// as a Go string (see applyNodePgTextForm), so by the time a value reaches this
// function a numeric/bigint column is ALREADY a string and hits the default case
// below — byte-identical to node-postgres, which stringifies them the same way.
// Reproducing that at the reader (not here) is deliberate: the discriminator is
// the column OID, which only the reader can see (the back4 controllers `SELECT *`).
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

// oidMoney is Postgres `money` (pgtype exposes no named const for it). node-pg
// returns it as a string too, so it joins numeric/int8 in the text-passthrough set.
const oidMoney = 790

// nodePgStringifiedOIDs forces the result columns node-postgres serializes as JSON
// STRINGS by default — numeric/decimal (1700), bigint/int8 (20), money (790) —
// onto the TEXT wire, so the reader can pass their exact Postgres text through
// verbatim (see applyNodePgTextForm). Passed as the first arg to pool.Query; pgx
// strips it before positional binding, so $1..$N are unaffected. This is the ONE
// place the §3c numeric shadow-diff is closed.
var nodePgStringifiedOIDs = pgx.QueryResultFormatsByOID{
	pgtype.NumericOID: pgx.TextFormatCode, // 1700 numeric/decimal
	pgtype.Int8OID:    pgx.TextFormatCode, // 20   bigint
	oidMoney:          pgx.TextFormatCode, // 790  money
}

// isNodePgStringifiedOID reports whether an OID is one node-postgres returns as a
// JSON string by default. Verified against back4 src/db/database.js: a vanilla
// pg.Pool with NO setTypeParser override, so pg-types' defaults apply — numeric
// and int8 use the identity (string) parser, int4/float8 become JS numbers.
func isNodePgStringifiedOID(oid uint32) bool {
	switch oid {
	case pgtype.NumericOID, pgtype.Int8OID, oidMoney:
		return true
	}
	return false
}

// applyNodePgTextForm rewrites the text-forced columns of one decoded row to the
// EXACT Postgres text node-postgres would deliver: for each column flagged in
// textPass the raw wire bytes (text format, thanks to nodePgStringifiedOIDs)
// replace pgx's decoded value as a Go string; a NULL (raw == nil) stays nil so it
// still marshals to JSON null.
//
// WHY (the §3c numeric shadow-diff, resolved): node-pg returns numeric/bigint as a
// STRING preserving scale ("12.34", "0.00", "9007199254740993"); pgx decodes them
// to pgtype.Numeric / int64, which json-encode as UNQUOTED numbers and — for a
// zero numeric — DROP the display scale (pgtype.Numeric of 0.00 → "0", proven from
// pgtype/numeric.go: ndigits==0 ⇒ Int=0,Exp=0). Passing the raw text is precisely
// node-pg's own mechanism (text protocol + identity parser), so the emitted JSON
// string is byte-identical BY CONSTRUCTION — including the 0.00 case (56 real rows
// in v_13_site_deb_sap_report carry a zero numeric) and bigints beyond 2^53.
func applyNodePgTextForm(vals []any, raw [][]byte, textPass []bool) {
	for i := range vals {
		if i < len(textPass) && textPass[i] {
			if i < len(raw) && raw[i] != nil {
				vals[i] = string(raw[i])
			} else {
				vals[i] = nil
			}
		}
	}
}

// ── jsonb/json parity (the §3c key-ORDER axis) ───────────────────────────────

// nodePgJSONOIDs are the JSON container types node-postgres decodes with
// JSON.parse (pg-types registers it for BOTH jsonb and json) and Express res.json
// re-emits with JSON.stringify. Unlike numeric/int8 (node-pg passes those through
// as a QUOTED string), these are emitted as JSON VALUES (object/array/scalar). We
// force them onto the text wire and RESERIALIZE the raw text to match JSON.parse+
// JSON.stringify exactly (see nodePgJSONText). (jsonb already prefers text in pgx,
// so RawValues has no 0x01 version prefix — forcing text is belt-and-suspenders.)
var nodePgJSONOIDs = map[uint32]int16{
	pgtype.JSONBOID: pgx.TextFormatCode, // 3802
	pgtype.JSONOID:  pgx.TextFormatCode, // 114
}

// externalTextForcedFormats is the union forced onto the text wire: numeric/int8/
// money (→ quoted strings) AND jsonb/json (→ reserialized objects). Passed as the
// first arg to pool.Query; pgx strips it before positional binding.
var externalTextForcedFormats = func() pgx.QueryResultFormatsByOID {
	m := pgx.QueryResultFormatsByOID{}
	for k, v := range nodePgStringifiedOIDs {
		m[k] = v
	}
	for k, v := range nodePgJSONOIDs {
		m[k] = v
	}
	return m
}()

// isNodePgJSONOID reports whether an OID is a JSON container node-pg round-trips
// through JSON.parse/JSON.stringify (jsonb, json).
func isNodePgJSONOID(oid uint32) bool {
	return oid == pgtype.JSONBOID || oid == pgtype.JSONOID
}

// rawJSON is a jsonb/json value ALREADY reserialized to node-pg's exact wire form
// (compact, stored key order, JS number semantics). externalRows.MarshalJSON emits
// it VERBATIM as a JSON value — never as a quoted string (a jsonb object must stay
// an object). A nil rawJSON is a SQL NULL → JSON null.
type rawJSON []byte

// nodePgJSONText reserializes a Postgres jsonb/json text value to the EXACT bytes
// node-postgres would emit, i.e. JSON.parse then JSON.stringify. Concretely:
//   - drop jsonb's insignificant whitespace ({"a": 1} → {"a":1});
//   - KEEP the object key order — JSON.parse preserves the text's order, which for
//     jsonb is Postgres's stored length-then-byte order, and JSON.stringify keeps
//     object order. (pgx's default jsonb decode goes through a Go map, whose
//     re-marshal SORTS keys alphabetically — the exact divergence this closes.)
//   - normalize numbers through IEEE-754 float64: 1.50→1.5, 100.0→100, and ints
//     beyond 2^53 lose precision EXACTLY as JS does. Go's shortest-float format
//     equals V8's, so the number bytes match back4 byte-for-byte (verified against
//     a live node reference on real prod rows).
//
// This is deliberately NOT json.Compact (which would keep "1.50" and thus diverge
// from node-pg) and NOT a Go map round-trip (which reorders keys). No HTML
// escaping — Express's JSON.stringify doesn't escape < > &, matching the rest of
// the shim (marshalNoEscape). KNOWN theoretical edge: Go always escapes U+2028/
// U+2029 in strings while JSON.stringify does not — absent from these columns.
func nodePgJSONText(src []byte) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(src))
	// No UseNumber(): numbers decode to float64, matching JS Number semantics.
	var out bytes.Buffer
	if err := emitNodePgJSON(dec, &out); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// emitNodePgJSON walks one JSON value from dec and writes its node-pg form to out,
// preserving object key order (the load-bearing property) and compacting.
func emitNodePgJSON(dec *json.Decoder, out *bytes.Buffer) error {
	t, err := dec.Token()
	if err != nil {
		return err
	}
	if d, ok := t.(json.Delim); ok {
		switch d {
		case '{':
			out.WriteByte('{')
			for i := 0; dec.More(); i++ {
				if i > 0 {
					out.WriteByte(',')
				}
				keyTok, err := dec.Token() // an object key is always a string
				if err != nil {
					return err
				}
				kb, err := marshalNoEscape(keyTok.(string))
				if err != nil {
					return err
				}
				out.Write(kb)
				out.WriteByte(':')
				if err := emitNodePgJSON(dec, out); err != nil {
					return err
				}
			}
			if _, err := dec.Token(); err != nil { // consume closing '}'
				return err
			}
			out.WriteByte('}')
		case '[':
			out.WriteByte('[')
			for i := 0; dec.More(); i++ {
				if i > 0 {
					out.WriteByte(',')
				}
				if err := emitNodePgJSON(dec, out); err != nil {
					return err
				}
			}
			if _, err := dec.Token(); err != nil { // consume closing ']'
				return err
			}
			out.WriteByte(']')
		}
		return nil
	}
	// Scalar: string / float64 / bool / nil. marshalNoEscape matches JSON.stringify
	// (shortest float == V8; no HTML escaping; true/false/null).
	vb, err := marshalNoEscape(t)
	if err != nil {
		return err
	}
	out.Write(vb)
	return nil
}

// applyNodePgJSONForm rewrites the jsonb/json columns of one decoded row to node-
// pg's reserialized form (a rawJSON, emitted verbatim by MarshalJSON as an object/
// array/scalar). A NULL (raw == nil) becomes rawJSON(nil) → JSON null.
func applyNodePgJSONForm(vals []any, raw [][]byte, jsonPass []bool) error {
	for i := range vals {
		if i < len(jsonPass) && jsonPass[i] {
			if i < len(raw) && raw[i] != nil {
				b, err := nodePgJSONText(raw[i])
				if err != nil {
					return err
				}
				vals[i] = rawJSON(b)
			} else {
				vals[i] = rawJSON(nil)
			}
		}
	}
	return nil
}

func (p pgxExternalReader) query(ctx context.Context, sql string, args ...any) (externalRows, error) {
	// Prepend the result-format control so numeric/int8/money (→ strings) and
	// jsonb/json (→ reserialized objects) come back as text.
	qargs := make([]any, 0, len(args)+1)
	qargs = append(qargs, externalTextForcedFormats)
	qargs = append(qargs, args...)

	rows, err := p.pool.Query(ctx, sql, qargs...)
	if err != nil {
		return externalRows{}, err
	}
	defer rows.Close()
	fds := rows.FieldDescriptions()
	cols := make([]string, len(fds))
	textPass := make([]bool, len(fds))
	jsonPass := make([]bool, len(fds))
	for i, fd := range fds {
		cols[i] = string(fd.Name)
		textPass[i] = isNodePgStringifiedOID(fd.DataTypeOID)
		jsonPass[i] = isNodePgJSONOID(fd.DataTypeOID)
	}
	var data [][]any
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return externalRows{}, err
		}
		// Substitute the raw Postgres text for numeric/int8/money columns and the
		// reserialized node-pg form for jsonb/json columns. RawValues() returns the
		// same buffered row Values() just decoded (text format for the forced OIDs).
		raw := rows.RawValues()
		applyNodePgTextForm(vals, raw, textPass)
		if err := applyNodePgJSONForm(vals, raw, jsonPass); err != nil {
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
	// auth reproduces THIS endpoint's foreign auth STATUS SHAPE. nil ⇒ the
	// default header contract (x-api-key header; 400 "x-api-key is required!";
	// unknown/wrong-owner → 401 "Unauthorized access") — what NEOPAC + Montebello
	// data-sync use. The Montebello/Incoplast pull endpoints authenticate via an
	// `api_key` QUERY param with their own bodies ("api_key is required!",
	// "Not authorized!"), so they supply a queryAPIKeyAuth here. The owner
	// binding (cid must equal the config-bound owner) is enforced by EVERY
	// authenticator — that invariant is not overridable per shim.
	auth externalAuth
	// backingViews / backingFunctions / guardRelations feed the pre-flip
	// contract-drift gate (existence-only): the frozen view/function MUST exist
	// in prod or the flip is blocked. backingFunctions carries the arg count so
	// the drift gate asserts arity too (a set-returning proc renamed or its
	// signature changed breaks the read exactly like a dropped view).
	backingViews     []string
	backingFunctions []backingFn
	guardRelations   []string
}

// backingFn is a set-returning function a shim reads from (Montebello's
// get_downtime_sync_enterprsie_06(), etc.). name+argc mirror the contract's
// function object so the drift gate checks EXISTENCE and ARITY, not just a name.
type backingFn struct {
	name string
	argc int
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
	// ── Montebello (Family A, ent 6) — see external_montebello_incoplast.go ──
	{
		consumer:     "montebello",
		path:         "/ext/montebello/data-sync",
		ownerEnv:     "EXTERNAL_MONTEBELLO_CUSTOMER_ID",
		run:          runMontebelloDataSync,
		backingViews: []string{"v_piot_production_data_sync_cust6"},
		// header x-api-key auth (default) — reproduces data-sync.controller.js
	},
	{
		consumer:         "montebello",
		path:             "/ext/montebello/events",
		ownerEnv:         "EXTERNAL_MONTEBELLO_CUSTOMER_ID",
		run:              runMontebelloEvents,
		auth:             queryAPIKeyAuth("api_key is required!", "Not authorized!"),
		backingFunctions: []backingFn{{name: "get_downtime_sync_enterprsie_06", argc: 0}},
	},
	// ── Incoplast (Family A, api_key) — see external_montebello_incoplast.go ──
	{
		consumer:       "incoplast",
		path:           "/ext/incoplast/events",
		ownerEnv:       "EXTERNAL_INCOPLAST_CUSTOMER_ID",
		run:            runIncoplastEvents,
		auth:           queryAPIKeyAuth("api_key is required!", "Unauthorized access"),
		guardRelations: []string{"equipment_events", "equipment_events_man", "equipments", "packml_register"},
	},
	{
		consumer:       "incoplast",
		path:           "/ext/incoplast/jobs",
		ownerEnv:       "EXTERNAL_INCOPLAST_CUSTOMER_ID",
		run:            runIncoplastJobs,
		auth:           queryAPIKeyAuth("api_key is required!", "Unauthorized access"),
		guardRelations: []string{"production_orders", "packml_register"},
	},
	// ── back4 /integration/* shims (Family A) — see external_integration.go ──
	// These carry a `:id_enterprise` PATH PARAM (the client names the tenant in
	// back4 — the ACL replaces it with the owner-bound cid) and their own foreign
	// auth ladders (400/422, and get-shift-validation's distinct 500-for-all).
	// The wildcard path is why the framework got muxPattern + exemptMatch (auth.go).
	{
		consumer:         "montebello",
		path:             "/integration/job_data_integration/:id_enterprise",
		ownerEnv:         "EXTERNAL_MONTEBELLO_CUSTOMER_ID",
		run:              runJobDataIntegration,
		auth:             integrationEnterpriseAuth("id is required!"),
		backingFunctions: []backingFn{{name: "get_data_sync_enterprsie_06b", argc: 1}},
	},
	{
		consumer:       "montebello",
		path:           "/integration/get-shift-validation/:id_enterprise",
		ownerEnv:       "EXTERNAL_MONTEBELLO_CUSTOMER_ID",
		run:            runShiftValidation,
		auth:           integrationShiftValidationAuth, // distinct 500-for-all membrane
		guardRelations: []string{"enterprises", "packml_register", "equipment_validation_shift"},
	},
	{
		consumer:       "incoplast",
		path:           "/integration/job_report/:id_enterprise",
		ownerEnv:       "EXTERNAL_INCOPLAST_CUSTOMER_ID",
		run:            runJobReport,
		auth:           integrationEnterpriseAuth("id_enterprise is required!"),
		guardRelations: []string{"equipment_runtime_shift", "agg_equipment_values_1min", "production_orders_runtime", "production_orders", "equipments", "sites", "areas", "packml_register"},
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

// ── The pluggable authenticators (one per foreign auth STATUS SHAPE) ─────────

// externalAuth reproduces one endpoint's foreign auth STATUS SHAPE and resolves
// the tenant through refdata's single key→customer_id authority. It returns the
// resolved customer_id on success, or a *shimError whose status+body are
// byte-identical to what the back4 controller sent. EVERY authenticator MUST
// enforce the owner binding (resolved cid == the config-bound owner); that is
// the tenant fence for a frozen customer-scoped read, not a per-endpoint option.
type externalAuth func(r *http.Request, keys map[string]int, owner int) (int, *shimError)

// headerAPIKeyAuth is the DEFAULT (nil auth) contract: the x-api-key HEADER,
// with back4's exact 400/401 bodies. Used by NEOPAC (sap-report[-sync]) and
// Montebello data-sync — all three read the key from `req.header('x-api-key')`.
func headerAPIKeyAuth(r *http.Request, keys map[string]int, owner int) (int, *shimError) {
	apiKey := r.Header.Get("x-api-key")
	if apiKey == "" {
		e := errMissingAPIKey // 400 "x-api-key is required!"
		return 0, &e
	}
	cid, ok := keys[apiKey]
	if !ok || cid != owner {
		e := errUnauthorized // 401 "Unauthorized access"
		return 0, &e
	}
	return cid, nil
}

// queryAPIKeyAuth builds the auth contract for the Montebello/Incoplast PULL
// endpoints: the credential is an `api_key` QUERY param (not a header), the
// missing-key body and the reject body differ per endpoint, and back4 treats the
// literal string "undefined" as absent (`api_key == "undefined"`, the classic
// `String(undefined)` leak from a client that forgot to set the param).
//
// OWNER-BINDING NOTE (honest boundary): back4's events_incoplast / jobs_incoplast
// have NO reject branch — they resolve the api_key's OWN enterprise and query it,
// so an unknown key silently yields empty data and a foreign key would read ITS
// tenant. The ACL HARDENS this to the framework's owner binding (unknown/
// wrong-owner → 401): the happy path (the bound customer's key) is byte-identical,
// and the only behavioural change is that a non-owner key is now rejected instead
// of leaking. That reject body is CHOSEN ("Unauthorized access", the family
// convention), not pinned from those two endpoints — flagged for §3d owner
// sign-off. events_montebello DOES pin its reject ("Not authorized!"), passed
// through here verbatim.
func queryAPIKeyAuth(missingBody, rejectBody string) externalAuth {
	return func(r *http.Request, keys map[string]int, owner int) (int, *shimError) {
		apiKey := r.URL.Query().Get("api_key")
		if apiKey == "" || apiKey == "undefined" {
			return 0, &shimError{status: http.StatusBadRequest, body: missingBody}
		}
		cid, ok := keys[apiKey]
		if !ok || cid != owner {
			return 0, &shimError{status: http.StatusUnauthorized, body: rejectBody}
		}
		return cid, nil
	}
}

// ── The shared membrane (auth reproduction + owner binding + byte encoding) ──

// makeExternalHandler builds the HTTP handler for one shim. It reproduces back4's
// auth STATUS SHAPES exactly (missing key → 400, unknown/wrong-owner → 401) while
// routing the tenant through refdata's single authority (the QUERY_API_KEYS map).
// The auth SHAPE is per-shim (sh.auth; nil ⇒ the header default); the owner
// binding + byte-identical encode + timeout + metrics are shared here, once.
//
// owner is resolved once at registration from ownerEnv. owner == 0 (env unset)
// means EVERY request 401s — no real customer_id is 0 — so a mis-provisioned shim
// fails closed rather than serving another tenant's frozen view.
func makeExternalHandler(sh externalShim, reader externalReader, keys map[string]int, owner int, logger *slog.Logger) http.HandlerFunc {
	authFn := sh.auth
	if authFn == nil {
		authFn = headerAPIKeyAuth
	}
	return func(w http.ResponseWriter, r *http.Request) {
		// 1) Reproduce back4's auth contract byte-for-byte (per-shim shape), but
		//    resolve the tenant through refdata's key→customer_id authority.
		cid, serr := authFn(r, keys, owner)
		if serr != nil {
			writeShimError(w, *serr)
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
		// muxPattern (auth.go) translates the registry's Express-style ":name"
		// path into the Go 1.22 ServeMux "{name}" wildcard so a concrete
		// `/integration/job_report/123` routes to this handler; concrete /ext/*
		// paths pass through unchanged. The auth-exempt set matches the SAME
		// pattern (exemptMatch), so routing and exemption never disagree.
		mux.HandleFunc(muxPattern(sh.path), makeExternalHandler(sh, reader, keys, owner, logger))
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
