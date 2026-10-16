package main

// PRODT-172 (RN-02 / AC-02): operator line grants on the tablet reads. The DB
// lookups and the data query are swapped through the package seams in
// operator_grants.go, so these run without a database and can prove a refused
// request never reaches its data query.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// grantFakes installs fake lookups + a recording data query for one test.
type grantFakes struct {
	grants      lineGrants
	topicEqs    map[string][]int
	grantCalls  int
	queryCalls  int
	lastSQL     string
	lastArgs    []any
	gotPrincipl operatorPrincipal
}

func installGrantFakes(t *testing.T, f *grantFakes) {
	t.Helper()
	oldG, oldT, oldQ := loadLineGrants, loadTopicEquipments, scopedQueryJSON
	t.Cleanup(func() { loadLineGrants, loadTopicEquipments, scopedQueryJSON = oldG, oldT, oldQ })
	loadLineGrants = func(_ context.Context, _ *pgxpool.Pool, _ int, p operatorPrincipal) (lineGrants, error) {
		f.grantCalls++
		f.gotPrincipl = p
		if p.unrestricted {
			return lineGrants{}, nil
		}
		return f.grants, nil
	}
	loadTopicEquipments = func(_ context.Context, _ *pgxpool.Pool, _ int, topics []string) ([]int, error) {
		var out []int
		for _, tp := range topics {
			out = append(out, f.topicEqs[tp]...)
		}
		return out, nil
	}
	scopedQueryJSON = func(_ context.Context, _ *pgxpool.Pool, _ int, sql string, args []any) ([]byte, error) {
		f.queryCalls++
		f.lastSQL, f.lastArgs = sql, args
		return []byte(`[]`), nil
	}
}

// restrictedTo builds a restricted permitted set (the already-expanded tree).
func restrictedTo(ids ...int) lineGrants {
	g := lineGrants{restricted: true, permitted: map[int]bool{}}
	for _, id := range ids {
		g.permitted[id] = true
	}
	return g
}

// operatorStack mounts the real endpoints behind the real authMiddleware: api-key
// "op-key" → tenant 9; operator token "tok-op" → user of tenant 9 with role 31;
// "tok-other" → a user of tenant 22.
func operatorStack(sa *operatorSuperAdminAuth) (http.Handler, *fakeBearer) {
	fb := &fakeBearer{table: map[string]resolvedIdentity{
		"tok-op":    {customerID: 9, userRole: 31, hasRole: true},
		"tok-other": {customerID: 22, userRole: 40, hasRole: true},
		// fakeCognito-shaped tokens of users homed in the admin tenant (1).
		"valid:dev@packiot.com":     {customerID: 1, userRole: 1, hasRole: true},
		"valid:nosuper@packiot.com": {customerID: 1, userRole: 2, hasRole: true},
	}}
	mux := http.NewServeMux()
	for _, ep := range endpoints {
		mux.HandleFunc(ep.path, makeHandler(nil, ep, discardLogger()))
	}
	return authMiddleware(map[string]int{"op-key": 9}, infraExemptSet(), fb.resolve, sa, mux), fb
}

func tabletReq(path, opToken string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, path, nil)
	r.Header.Set("X-Api-Key", "op-key")
	r.Header.Set(operatorChannelHeader, "tablet")
	if opToken != "" {
		r.Header.Set(operatorAuthHeader, "Bearer "+opToken)
	}
	return r
}

// The headline AC-02 case: a restricted operator asking /v2 for a foreign line → 403, no query.
func TestOperatorGrants_V2ForeignLine403NoQuery(t *testing.T) {
	f := &grantFakes{grants: restrictedTo(100, 101, 102)} // L1 + its machines
	installGrantFakes(t, f)
	h, _ := operatorStack(nil)
	for _, path := range []string{"/v2/events-timeline", "/v2/pending-downtime", "/v2/operator-po-list", "/v2/downtime-reasons"} {
		f.queryCalls = 0
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, tabletReq(path+"?equipment=100,500", "tok-op")) // 500 = L5, not granted
		if rr.Code != http.StatusForbidden || !strings.Contains(rr.Body.String(), "LINE_NOT_PERMITTED") {
			t.Errorf("%s foreign line: code=%d body=%s; want 403 LINE_NOT_PERMITTED", path, rr.Code, rr.Body)
		}
		if f.queryCalls != 0 {
			t.Errorf("%s: data query ran %d times for a refused request", path, f.queryCalls)
		}
		// The granted line alone is served.
		rr = httptest.NewRecorder()
		h.ServeHTTP(rr, tabletReq(path+"?equipment=100,102", "tok-op"))
		if rr.Code != http.StatusOK || f.queryCalls != 1 {
			t.Errorf("%s granted: code=%d queries=%d; want 200 and 1 query", path, rr.Code, f.queryCalls)
		}
	}
	if f.gotPrincipl.userRole != 31 || !f.gotPrincipl.hasRole || f.gotPrincipl.customerID != 9 {
		t.Errorf("principal = %+v; want role 31 of tenant 9", f.gotPrincipl)
	}
}

func TestOperatorGrants_V1TopicsResolvedAndChecked(t *testing.T) {
	f := &grantFakes{grants: restrictedTo(100, 101), topicEqs: map[string][]int{"L1": {100}, "L5": {500}}}
	installGrantFakes(t, f)
	h, _ := operatorStack(nil)
	cases := []struct {
		path string
		want int
	}{
		{"/v1/events-timeline?topics=L1,L5", http.StatusForbidden},
		{"/v1/pending-downtime?topics=L5", http.StatusForbidden},
		{"/v1/downtime-reasons?topics=L5", http.StatusForbidden},
		{"/v1/shift-hours?topic=L5", http.StatusForbidden},
		{"/v1/shift-hours-by-enterprise?topic=L5", http.StatusForbidden},
		{"/v1/day-week-begin?topic=L5", http.StatusForbidden},
		{"/v1/events-timeline?topics=L1", http.StatusOK},
		{"/v1/day-week-begin?topic=L1", http.StatusOK},
		{"/v1/events-timeline?topics=unknown", http.StatusOK}, // routes nowhere → no data anyway
	}
	for _, c := range cases {
		f.queryCalls = 0
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, tabletReq(c.path, "tok-op"))
		if rr.Code != c.want {
			t.Errorf("%s: code=%d; want %d (%s)", c.path, rr.Code, c.want, rr.Body)
		}
		if c.want == http.StatusForbidden && f.queryCalls != 0 {
			t.Errorf("%s: data query ran for a refused request", c.path)
		}
	}
}

func TestOperatorGrants_TenantWideListsFiltered(t *testing.T) {
	f := &grantFakes{grants: restrictedTo(100, 101)}
	installGrantFakes(t, f)
	h, _ := operatorStack(nil)
	for _, path := range []string{"/v1/operator-po-list", "/v1/operator-po-details"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, tabletReq(path, "tok-op"))
		if rr.Code != http.StatusOK {
			t.Fatalf("%s: code=%d", path, rr.Code)
		}
		if !strings.Contains(f.lastSQL, "line_grant.id_equipment = ANY($2::int[])") || len(f.lastArgs) != 2 {
			t.Fatalf("%s: not filtered: sql=%q args=%v", path, f.lastSQL, f.lastArgs)
		}
		ids := f.lastArgs[1].([]int32)
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		if !reflect.DeepEqual(ids, []int32{100, 101}) || f.lastArgs[0] != 9 {
			t.Errorf("%s: args=%v; want [9 [100 101]]", path, f.lastArgs)
		}
	}
}

// Header absent ⇒ byte-identical to before: no grant lookup, the endpoint's own SQL/args.
func TestOperatorGrants_NoChannelHeaderUnchanged(t *testing.T) {
	f := &grantFakes{grants: restrictedTo()} // would deny everything if consulted
	installGrantFakes(t, f)
	h, fb := operatorStack(nil)
	for _, ep := range endpoints {
		if ep.class != routeTenantScoped {
			continue
		}
		path := ep.path
		switch lineGrantPolicies[ep.path] {
		case grantEquipmentParam:
			path += "?equipment=500"
		case grantTopicParam:
			path += "?topics=L5&topic=L5"
		}
		f.queryCalls = 0
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Header.Set("X-Api-Key", "op-key")
		r.Header.Set(operatorAuthHeader, "Bearer tok-op") // ignored without the channel header
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		if rr.Code != http.StatusOK || f.queryCalls != 1 || f.lastSQL != ep.activeSQL(activeFlow) {
			t.Errorf("%s: code=%d queries=%d sql=%q; want 200 with the unmodified SQL", path, rr.Code, f.queryCalls, f.lastSQL)
		}
	}
	if f.grantCalls != 0 || fb.called {
		t.Errorf("grant lookup (%d) or operator token verify (%v) ran without the channel header", f.grantCalls, fb.called)
	}
}

func TestOperatorGrants_InvalidTokenAndCrossTenant(t *testing.T) {
	f := &grantFakes{grants: restrictedTo(100)}
	installGrantFakes(t, f)
	h, _ := operatorStack(nil)
	cases := []struct {
		name  string
		token string
		raw   string
		want  int
		body  string
	}{
		{"missing operator token", "", "", http.StatusUnauthorized, "missing or invalid credentials"},
		{"invalid operator token", "tok-forged", "", http.StatusUnauthorized, "missing or invalid credentials"},
		{"not a bearer", "", "Basic abc", http.StatusUnauthorized, "missing or invalid credentials"},
		{"user of another tenant", "tok-other", "", http.StatusForbidden, `{"error":"forbidden"}`},
	}
	for _, c := range cases {
		r := tabletReq("/v1/operator-po-list", c.token)
		if c.raw != "" {
			r.Header.Set(operatorAuthHeader, c.raw)
		}
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		if rr.Code != c.want || !strings.Contains(rr.Body.String(), c.body) {
			t.Errorf("%s: code=%d body=%s; want %d %s", c.name, rr.Code, rr.Body, c.want, c.body)
		}
	}
	if f.queryCalls != 0 || f.grantCalls != 0 {
		t.Errorf("refused requests reached the handler: queries=%d grants=%d", f.queryCalls, f.grantCalls)
	}
}

// A verified super-admin who switched tenants reads the target tenant unrestricted,
// without the operator token being resolved against the home tenant.
func TestOperatorGrants_SuperAdminEscalationUnrestricted(t *testing.T) {
	f := &grantFakes{grants: restrictedTo()} // a restricted principal would be denied everything
	installGrantFakes(t, f)
	sa := escalator([]string{"dev@packiot.com"}, map[string]bool{"dev@packiot.com": true}, map[int]bool{77: true})
	h, fb := operatorStack(sa)
	r := tabletReq("/v2/events-timeline?equipment=500&idEnterprise=77", "valid:dev@packiot.com")
	r.Header.Set("x-operator-superadmin-token", "valid:dev@packiot.com")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusOK || f.queryCalls != 1 || f.lastArgs[0] != 77 {
		t.Fatalf("escalated: code=%d queries=%d args=%v; want 200, 1 query, tenant 77", rr.Code, f.queryCalls, f.lastArgs)
	}
	if fb.called {
		t.Error("operator token was resolved against the home tenant on the escalated path")
	}
}

// An unrestricted role (super_user / legacy) behaves exactly as without the header.
func TestOperatorGrants_UnrestrictedRoleUnchanged(t *testing.T) {
	f := &grantFakes{grants: lineGrants{restricted: false}}
	installGrantFakes(t, f)
	h, _ := operatorStack(nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, tabletReq("/v1/operator-po-list", "tok-op"))
	if rr.Code != http.StatusOK || f.lastSQL != `SELECT * FROM v_operator_po_list_setup_4 WHERE id_enterprise = $1` {
		t.Errorf("unrestricted: code=%d sql=%q; want the unmodified SQL", rr.Code, f.lastSQL)
	}
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, tabletReq("/v2/events-timeline?equipment=500", "tok-op"))
	if rr.Code != http.StatusOK {
		t.Errorf("unrestricted /v2: code=%d", rr.Code)
	}
}

// Every endpoint carries an explicit line-grant decision, and the filter mode is
// only used where the backing view exposes id_equipment.
func TestOperatorGrants_EveryEndpointHasAPolicy(t *testing.T) {
	for _, ep := range endpoints {
		mode, ok := lineGrantPolicies[ep.path]
		if !ok {
			t.Errorf("endpoint %s has no lineGrantPolicies entry — decide whether operator line grants apply", ep.path)
			continue
		}
		if ep.class != routeTenantScoped && mode != grantNone {
			t.Errorf("endpoint %s is not tenant-scoped but has line-grant mode %d", ep.path, mode)
		}
	}
	if len(lineGrantPolicies) != len(endpoints) {
		t.Errorf("lineGrantPolicies has %d entries for %d endpoints (stale path?)", len(lineGrantPolicies), len(endpoints))
	}
}

// The pure grant rule — mirrors edge-api operatorLineGrant (operator-grants.ts).
func TestGrantedLineIDs(t *testing.T) {
	s := func(v string) *string { return &v }
	cases := []struct {
		name       string
		super      bool
		perms      *string
		restricted bool
		ids        []int32
	}{
		{"super_user wins over a grant", true, s(`{"operator":{"lines":[1]}}`), false, nil},
		{"NULL permissions → legacy", false, nil, false, nil},
		{"no operator key → legacy", false, s(`{"desktop":{"x":1}}`), false, nil},
		{"lines null → legacy", false, s(`{"operator":{"lines":null}}`), false, nil},
		{"lines object → legacy", false, s(`{"operator":{"lines":{"1":true}}}`), false, nil},
		{"empty array → nothing", false, s(`{"operator":{"lines":[]}}`), true, []int32{}},
		{"numbers + numeric strings, dedup", false, s(`{"operator":{"lines":[5,"7",5,"007"]}}`), true, []int32{5, 7}},
		{"junk ignored", false, s(`{"operator":{"lines":[0,-3,"x","1.5",2.5,true,null,"",3.0,99999999999]}}`), true, []int32{3}},
		{"permissions stored as a JSON string", false, s(`"{\"operator\":{\"lines\":[12]}}"`), true, []int32{12}},
		{"operator stored as a JSON string", false, s(`{"operator":"{\"lines\":[13]}"}`), true, []int32{13}},
		{"unparseable string → legacy", false, s(`"{not json"`), false, nil},
		{"supervisor only → legacy lines", false, s(`{"operator":{"supervisor":true}}`), false, nil},
	}
	for _, c := range cases {
		restricted, ids := grantedLineIDs(c.super, c.perms)
		if restricted != c.restricted || !reflect.DeepEqual(ids, c.ids) {
			t.Errorf("%s: got (%v, %v); want (%v, %v)", c.name, restricted, ids, c.restricted, c.ids)
		}
	}
}

func TestLineGrantsNoRoleDeniesAll(t *testing.T) {
	g, err := dbLoadLineGrants(context.Background(), nil, 9, operatorPrincipal{customerID: 9})
	if err != nil || !g.restricted || len(g.permitted) != 0 || g.allows(1) {
		t.Errorf("role-less user: %+v err=%v; want restricted with nothing permitted (no DB touch)", g, err)
	}
	g, err = dbLoadLineGrants(context.Background(), nil, 9, operatorPrincipal{unrestricted: true})
	if err != nil || g.restricted {
		t.Errorf("unrestricted principal: %+v err=%v", g, err)
	}
}

// A cross-tenant super-admin (allowlisted, live super_user) on a tablet of another
// tenant WITHOUT escalating is unrestricted; anyone failing those checks stays 403.
func TestOperatorGrants_HomeMismatchSuperAdmin(t *testing.T) {
	f := &grantFakes{grants: restrictedTo()} // a restricted principal would be denied everything
	installGrantFakes(t, f)
	sa := escalator([]string{"dev@packiot.com", "nosuper@packiot.com"},
		map[string]bool{"dev@packiot.com": true}, map[int]bool{})
	h, _ := operatorStack(sa)

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, tabletReq("/v2/events-timeline?equipment=500", "valid:dev@packiot.com"))
	if rr.Code != http.StatusOK || f.queryCalls != 1 || f.lastArgs[0] != 9 || f.grantCalls != 0 {
		t.Fatalf("super-admin on foreign tablet: code=%d queries=%d args=%v grantCalls=%d; want 200 unrestricted (no grant lookup) on tenant 9",
			rr.Code, f.queryCalls, f.lastArgs, f.grantCalls)
	}

	for name, h := range map[string]http.Handler{
		"allowlisted but not super_user": h,
		"escalation disabled (nil)":      func() http.Handler { h2, _ := operatorStack(nil); return h2 }(),
	} {
		tok := "valid:nosuper@packiot.com"
		if name == "escalation disabled (nil)" {
			tok = "valid:dev@packiot.com"
		}
		f.queryCalls = 0
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, tabletReq("/v2/events-timeline?equipment=500", tok))
		if rr.Code != http.StatusForbidden || !strings.Contains(rr.Body.String(), `{"error":"forbidden"}`) || f.queryCalls != 0 {
			t.Errorf("%s: code=%d body=%s queries=%d; want 403 forbidden, no query", name, rr.Code, rr.Body, f.queryCalls)
		}
	}
}
