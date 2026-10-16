// operator_grants.go — PRODT-172 (spec RN-02 / AC-02): server-side LINE GRANTS
// on the operator-tablet reads.
//
// THE GAP THIS CLOSES
// ───────────────────
// The operator SPA's /v1|/v2 reads reach read-api through the operator's nginx,
// which injects a FIXED tenant X-Api-Key. X-Api-Key wins in authMiddleware
// (auth.go), so read-api knew WHICH ENTERPRISE was reading but never WHICH USER —
// any operator could read any line of the tenant by putting its id/topic in the
// URL ("requesting L5's address directly" returned L5's data).
//
// THE CONTRACT (set by the operator nginx, never by the browser)
// ─────────────────────────────────────────────────────────────
//   - `X-Operator-Channel: tablet` — a constant nginx stamps with
//     proxy_set_header, so a browser can neither forge nor drop it on that path.
//   - `X-Operator-Authorization: Bearer <Cognito ID token>` — the browser's own
//     Authorization header, forwarded verbatim.
//
// When X-Operator-Channel is non-empty on the X-Api-Key path, authMiddleware
// resolves an operatorPrincipal (resolveOperatorPrincipal below):
//   - a verified super-admin cross-tenant escalation (resolveTarget moved the
//     tenant) → unrestricted (it may read every line of the tenant it switched to);
//   - else the X-Operator-Authorization token is verified with the SAME Cognito
//     bearer resolver the Bearer branch uses. Missing/invalid → 401 (the generic
//     unauthorized()); a user of ANOTHER enterprise than the api-key's → 403
//     {"error":"forbidden"} — unless that user is a cross-tenant super-admin by
//     the escalation's own checks (isCrossTenantSuperAdmin) → unrestricted.
//
// When the header is ABSENT nothing changes, byte for byte — so this is inert
// until the nginx change ships (deploy-order safety), and every other X-Api-Key
// caller (services, integrations) is untouched.
//
// GRANT SEMANTICS — identical to edge-api src/shared/operator-access/
// operator-grants.ts (operatorLineGrant); keep the two in sync:
//   - role super_user → every line;
//   - user_roles.permissions.operator.lines is not a JSON array → every line
//     (legacy roles keep today's behaviour);
//   - an array → those ids (integers, or strings of ASCII digits; anything else
//     ignored) that are equipments of the caller's enterprise, PLUS all their
//     descendants via equipments.id_parentequipment. A machine grant does NOT
//     permit its parent line. [] → nothing;
//   - a user with no role (or a role id that is not a role of this enterprise) →
//     nothing.
//
// permissions (and permissions.operator) may be stored as a JSON STRING holding
// the object; like edge-api's asObject() we re-parse strings (recursively) and an
// unparseable string counts as "no object" → legacy/unrestricted.
//
// ENFORCEMENT (makeHandler, main.go) — see lineGrantPolicies for the per-route
// decision; every endpoint MUST have an entry (operator_grants_test.go gates it).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	operatorChannelHeader = "X-Operator-Channel"
	operatorAuthHeader    = "X-Operator-Authorization"
	// operatorPrincipalKey extends auth.go's ctxKey space.
	operatorPrincipalKey ctxKey = 2
)

// operatorPrincipal is the operator USER behind a tablet request. Server-derived
// only (verified Cognito token → users row); never client-supplied.
type operatorPrincipal struct {
	customerID   int  // the user's enterprise (== the api-key's tenant; checked in the middleware)
	userRole     int  // users.user_roles
	hasRole      bool // false ⇒ nothing permitted
	unrestricted bool // verified super-admin cross-tenant escalation
}

func withOperatorPrincipal(ctx context.Context, p operatorPrincipal) context.Context {
	return context.WithValue(ctx, operatorPrincipalKey, p)
}

// operatorPrincipalFromContext returns the tablet principal; ok=false means the
// request did not come through the operator channel (no line grants apply).
func operatorPrincipalFromContext(ctx context.Context) (operatorPrincipal, bool) {
	p, ok := ctx.Value(operatorPrincipalKey).(operatorPrincipal)
	return p, ok
}

// resolveOperatorPrincipal is called by authMiddleware on the X-Api-Key branch
// ONLY when X-Operator-Channel is set. homeCID is the api-key's tenant; escalated
// is true when the super-admin escalation already moved the tenant. It returns a
// non-zero HTTP status when the request must be refused (401 / 403).
func resolveOperatorPrincipal(ctx context.Context, r *http.Request, bearer bearerResolver, superAdmin *operatorSuperAdminAuth, homeCID int, escalated bool) (operatorPrincipal, int) {
	if escalated {
		// resolveTarget already verified this token's owner as a live, allowlisted
		// super_user; it reads the switched tenant whole (edge-api: unrestricted).
		return operatorPrincipal{unrestricted: true}, 0
	}
	tok, err := parseBearer(r.Header.Get(operatorAuthHeader))
	if err != nil || bearer == nil {
		return operatorPrincipal{}, http.StatusUnauthorized
	}
	id, err := bearer(ctx, tok)
	if err != nil {
		return operatorPrincipal{}, http.StatusUnauthorized
	}
	if id.customerID != homeCID {
		// A real user, but of another enterprise than the tablet's key. A
		// cross-tenant super-admin (the escalation's own checks: flag on, verified
		// email, allowlist, live super_user) may still use the tablet unrestricted —
		// e.g. dev@packiot.com switched onto the tablet's own tenant, where no
		// escalation applies. nil superAdmin (flag off) or any failure → 403.
		if superAdmin != nil && superAdmin.isCrossTenantSuperAdmin(ctx, tok) {
			return operatorPrincipal{unrestricted: true}, 0
		}
		return operatorPrincipal{}, http.StatusForbidden
	}
	return operatorPrincipal{customerID: id.customerID, userRole: id.userRole, hasRole: id.hasRole}, 0
}

// writeJSONError writes a one-line JSON error body the way every native route
// does (http.Error: text/plain + newline — the documented error convention in
// openapi.go's infoDescription), so callers parse it like any other error.
func writeJSONError(w http.ResponseWriter, status int, body string) {
	http.Error(w, body, status)
}

const (
	errBodyForbidden          = `{"error":"forbidden"}`
	errBodyLineNotPermitted   = `{"error":"line not permitted","reason":"LINE_NOT_PERMITTED"}`
	errBodyGrantLookupFailure = `{"error":"query failed"}`
)

// ── Grant semantics (pure) ──────────────────────────────────────────────────

var asciiDigits = regexp.MustCompile(`^[0-9]+$`)

// asObject mirrors edge-api's asObject(): a JSON object as a map; a JSON string
// is parsed again (recursively); anything else (incl. an unparseable string) → nil.
func asObject(v any) map[string]any {
	switch t := v.(type) {
	case map[string]any:
		return t
	case string:
		var inner any
		dec := json.NewDecoder(strings.NewReader(t))
		dec.UseNumber()
		if err := dec.Decode(&inner); err != nil || dec.More() {
			return nil
		}
		return asObject(inner)
	default:
		return nil
	}
}

// grantedLineIDs applies the grant rule to one role. restricted=false means every
// line (super_user, or a legacy role without an operator.lines array). With
// restricted=true, ids are the raw granted ids (deduplicated, positive int32);
// the tenant check + descendant expansion happen in SQL (lineGrantTreeSQL).
// permissionsJSON is the role's permissions as JSON text (nil = SQL NULL).
func grantedLineIDs(superUser bool, permissionsJSON *string) (restricted bool, ids []int32) {
	if superUser {
		return false, nil
	}
	var perms any
	if permissionsJSON != nil {
		dec := json.NewDecoder(strings.NewReader(*permissionsJSON))
		dec.UseNumber()
		if err := dec.Decode(&perms); err != nil {
			perms = nil
		}
	}
	op := asObject(asObject(perms)["operator"])
	lines, isArray := op["lines"].([]any)
	if !isArray {
		return false, nil
	}
	seen := map[int32]bool{}
	ids = []int32{}
	for _, v := range lines {
		var n float64
		switch t := v.(type) {
		case json.Number: // JS Number.isInteger(v) && v > 0
			f, err := strconv.ParseFloat(string(t), 64)
			if err != nil {
				continue
			}
			n = f
		case string: // /^\d+$/ → Number(v)
			if !asciiDigits.MatchString(t) {
				continue
			}
			f, err := strconv.ParseFloat(t, 64)
			if err != nil {
				continue
			}
			n = f
		default:
			continue
		}
		// An id beyond int32 cannot be an equipment (id_equipment is int4): skip it.
		if n <= 0 || n != math.Trunc(n) || n > math.MaxInt32 {
			continue
		}
		if id := int32(n); !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return true, ids
}

// lineGrants is a request's resolved permitted set.
type lineGrants struct {
	restricted bool
	permitted  map[int]bool
}

func (g lineGrants) allows(id int) bool { return !g.restricted || g.permitted[id] }

func (g lineGrants) permittedIDs() []int32 {
	out := make([]int32, 0, len(g.permitted))
	for id := range g.permitted {
		out = append(out, int32(id))
	}
	return out
}

// ── DB lookups (tenant-stamped; seams for tests) ────────────────────────────

// lineGrantRoleSQL reads the caller's role ($1 tenant, $2 id_user_role). Bare
// names resolve through the DB search_path (identity.user_roles on F3,
// public.user_roles on F1). permissions is json or jsonb depending on the DB, so
// it is read as text and interpreted in Go (grantedLineIDs).
const lineGrantRoleSQL = `SELECT COALESCE(ur.super_user, false), ur.permissions::text
	FROM user_roles ur WHERE ur.id_user_role = $2 AND ur.id_enterprise = $1`

// lineGrantTreeSQL expands granted ids to themselves + every descendant, inside
// the caller's tenant only ($1). core.equipments is FORCE RLS on app.tenant_id;
// the query runs in the tenant-stamped transaction, $1 is the primary fence.
const lineGrantTreeSQL = `WITH RECURSIVE tree AS (
	SELECT e.id_equipment FROM equipments e
	 WHERE e.id_equipment = ANY($2::int[]) AND e.id_enterprise = $1
	UNION
	SELECT c.id_equipment FROM equipments c JOIN tree t ON c.id_parentequipment = t.id_equipment
	 WHERE c.id_enterprise = $1)
SELECT id_equipment FROM tree`

// topicEquipmentsSQL resolves operator topics to the equipments they route to,
// within the tenant. NOT filtered on active: the /v1 SETOF functions join
// packml_register without an active filter, so an inactive row could still
// serve data — every row a topic matches must be permitted.
const topicEquipmentsSQL = `SELECT DISTINCT p.id_equipment FROM packml_register p
	JOIN equipments e ON e.id_equipment = p.id_equipment AND e.id_enterprise = $1
	WHERE p.packml_topic = ANY($2::text[])`

// loadLineGrants, loadTopicEquipments and scopedQueryJSON (makeHandler's data
// query) are package seams: tests swap them to prove enforcement — including
// that a refused request never runs its data query — without a database.
var (
	loadLineGrants      = dbLoadLineGrants
	loadTopicEquipments = dbLoadTopicEquipments
	scopedQueryJSON     = runQueryJSON
)

// withTenantTx runs fn in a transaction stamped with app.tenant_id (the same
// transaction-local stamp runQueryRows uses — safe behind pgbouncer).
func withTenantTx(ctx context.Context, pool *pgxpool.Pool, cid int, fn func(pgx.Tx) error) error {
	if pool == nil {
		return errors.New("no database pool")
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, fmt.Sprintf("SELECT set_config('app.tenant_id', '%d', true)", cid)); err != nil {
		return err
	}
	return fn(tx)
}

func dbLoadLineGrants(ctx context.Context, pool *pgxpool.Pool, cid int, p operatorPrincipal) (lineGrants, error) {
	if p.unrestricted {
		return lineGrants{}, nil
	}
	g := lineGrants{restricted: true, permitted: map[int]bool{}}
	if !p.hasRole {
		return g, nil // no role → nothing permitted
	}
	err := withTenantTx(ctx, pool, cid, func(tx pgx.Tx) error {
		var super bool
		var perms *string
		err := tx.QueryRow(ctx, lineGrantRoleSQL, cid, p.userRole).Scan(&super, &perms)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // not a role of this enterprise → nothing permitted
		}
		if err != nil {
			return err
		}
		restricted, ids := grantedLineIDs(super, perms)
		if !restricted {
			g.restricted = false
			return nil
		}
		if len(ids) == 0 {
			return nil
		}
		rows, err := tx.Query(ctx, lineGrantTreeSQL, cid, ids)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id int
			if err := rows.Scan(&id); err != nil {
				return err
			}
			g.permitted[id] = true
		}
		return rows.Err()
	})
	if err != nil {
		return lineGrants{}, err
	}
	return g, nil
}

func dbLoadTopicEquipments(ctx context.Context, pool *pgxpool.Pool, cid int, topics []string) ([]int, error) {
	var out []int
	err := withTenantTx(ctx, pool, cid, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, topicEquipmentsSQL, cid, topics)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id int
			if err := rows.Scan(&id); err != nil {
				return err
			}
			out = append(out, id)
		}
		return rows.Err()
	})
	return out, err
}

// ── Per-route policy ────────────────────────────────────────────────────────

type lineGrantMode int

const (
	// grantNone: deliberately NOT line-checked. /v1/operator-entities and
	// /v1/entities-per-user-role (the tablet's entity tree / line picker — it
	// must list what exists; edge-api's session decides what is selectable),
	// /v1/language-packs (global i18n). /v1/query, /v1/catalog, screen-config,
	// dashboard-config and the historian are not in the endpoints table and are
	// untouched too (front4 / BI surfaces, not the tablet's line reads).
	grantNone lineGrantMode = iota
	// grantEquipmentParam: ?equipment=<ids> — every id must be permitted.
	grantEquipmentParam
	// grantTopicParam: ?topics= / ?topic= — every equipment a topic routes to
	// must be permitted. Unknown topics resolve to nothing (and return no data).
	grantTopicParam
	// grantFilterRows: tenant-wide list — keep only rows whose id_equipment is
	// permitted (the backing view carries id_equipment).
	grantFilterRows
)

// lineGrantPolicies is the explicit decision for EVERY endpoint in main.go's
// table; operator_grants_test.go fails when an endpoint has none.
var lineGrantPolicies = map[string]lineGrantMode{
	"/v1/events-timeline":           grantTopicParam,
	"/v1/pending-downtime":          grantTopicParam,
	"/v1/shift-hours":               grantTopicParam,
	"/v1/shift-hours-by-enterprise": grantTopicParam,
	"/v1/day-week-begin":            grantTopicParam,
	"/v1/downtime-reasons":          grantTopicParam,
	"/v1/operator-po-list":          grantFilterRows,
	"/v1/operator-po-details":       grantFilterRows,
	"/v2/events-timeline":           grantEquipmentParam,
	"/v2/pending-downtime":          grantEquipmentParam,
	"/v2/operator-po-list":          grantEquipmentParam,
	"/v2/downtime-reasons":          grantEquipmentParam,
	"/v1/operator-entities":         grantNone,
	"/v1/entities-per-user-role":    grantNone,
	"/v1/language-packs":            grantNone,
}

// enforceLineGrants is makeHandler's hook for tenant-scoped routes. It returns
// the (possibly row-filtered) SQL + args to run, or a non-zero status + body when
// the request must be refused BEFORE any data query runs. Without an operator
// principal, or for an unrestricted one, it returns sql/args unchanged.
func enforceLineGrants(ctx context.Context, pool *pgxpool.Pool, path string, cid int, sql string, args []any) (string, []any, int, string) {
	mode := lineGrantPolicies[path]
	if mode == grantNone {
		return sql, args, 0, ""
	}
	p, ok := operatorPrincipalFromContext(ctx)
	if !ok || p.unrestricted {
		return sql, args, 0, ""
	}
	g, err := loadLineGrants(ctx, pool, cid, p)
	if err != nil {
		return "", nil, http.StatusInternalServerError, errBodyGrantLookupFailure
	}
	if !g.restricted {
		return sql, args, 0, ""
	}
	if (mode == grantEquipmentParam || mode == grantTopicParam) && len(args) < 2 {
		// Unreachable (the args parser 400s first); fail closed if it ever isn't.
		return "", nil, http.StatusForbidden, errBodyLineNotPermitted
	}
	switch mode {
	case grantEquipmentParam:
		ids, _ := args[1].([]int32) // args = [cid, []int32] (equipmentIDsArg)
		for _, id := range ids {
			if !g.allows(int(id)) {
				return "", nil, http.StatusForbidden, errBodyLineNotPermitted
			}
		}
	case grantTopicParam:
		var topics []string
		switch t := args[1].(type) { // topicsArg → []string, topicArg → string
		case []string:
			topics = t
		case string:
			topics = []string{t}
		}
		eqs, err := loadTopicEquipments(ctx, pool, cid, topics)
		if err != nil {
			return "", nil, http.StatusInternalServerError, errBodyGrantLookupFailure
		}
		for _, id := range eqs {
			if !g.allows(id) {
				return "", nil, http.StatusForbidden, errBodyLineNotPermitted
			}
		}
	case grantFilterRows:
		// Same columns, same order (SELECT *); only rows of permitted equipment.
		sql = fmt.Sprintf("SELECT * FROM (%s) AS line_grant WHERE line_grant.id_equipment = ANY($%d::int[])", sql, len(args)+1)
		args = append(append([]any{}, args...), g.permittedIDs())
	}
	return sql, args, 0, ""
}
