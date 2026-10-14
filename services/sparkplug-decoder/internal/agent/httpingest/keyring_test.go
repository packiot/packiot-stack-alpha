package httpingest

import (
	"bytes"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

const (
	cpackKey     = "cpack-tenant-key-0123456789abcdef"
	incoplastKey = "incoplast-tenant-key-fedcba9876543210"
)

func testRing(t *testing.T) *KeyRing {
	t.Helper()
	ring, err := ParseKeyRing([]byte(`{
		"` + HashKey(cpackKey) + `": ["cpack"],
		"` + strings.ToUpper(HashKey(incoplastKey)) + `": ["INCOPLAST", " incoplast "]
	}`))
	if err != nil {
		t.Fatalf("ParseKeyRing: %v", err)
	}
	return ring
}

type keyedRouter struct {
	h        http.Handler
	outcomes *prometheus.CounterVec
	logs     *bytes.Buffer
	a, b     *captureSink // CPACK, INCOPLAST
}

func newKeyedRouter(t *testing.T, cfg Config) keyedRouter {
	t.Helper()
	k := keyedRouter{
		outcomes: prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_keyed_total"}, []string{"outcome"}),
		logs:     &bytes.Buffer{},
		a:        &captureSink{},
		b:        &captureSink{},
	}
	srv := NewRouter(cfg, map[string]Sink{"CPACK": k.a.fn, "INCOPLAST": k.b.fn}, k.outcomes,
		slog.New(slog.NewTextHandler(k.logs, nil)))
	k.h = srv.Handler()
	return k
}

func (k keyedRouter) count(outcome string) float64 {
	return testutil.ToFloat64(k.outcomes.WithLabelValues(outcome))
}

func TestParseKeyRing_RejectsBadEntries(t *testing.T) {
	for name, raw := range map[string]string{
		"not an object":     `["x"]`,
		"raw key not hash":  `{"my-plain-key": ["CPACK"]}`,
		"short hex":         `{"abcd": ["CPACK"]}`,
		"no groups":         `{"` + HashKey("k") + `": []}`,
		"blank groups only": `{"` + HashKey("k") + `": ["  "]}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := ParseKeyRing([]byte(raw))
			if err == nil {
				t.Fatal("want error")
			}
			if strings.Contains(err.Error(), "my-plain-key") {
				t.Fatalf("error echoes the entry (could leak a pasted key): %v", err)
			}
		})
	}
}

func TestParseKeyRing_GroupsNormalised(t *testing.T) {
	ring := testRing(t)
	if ring.Len() != 2 {
		t.Fatalf("Len = %d want 2", ring.Len())
	}
	if got := strings.Join(ring.Groups(), ","); got != "CPACK,INCOPLAST" {
		t.Fatalf("Groups = %q", got)
	}
	e, ok := ring.lookup(incoplastKey)
	if !ok || e.label != "INCOPLAST" {
		t.Fatalf("incoplast lookup = %+v %v (duplicate/case groups must collapse)", e, ok)
	}
	if _, ok := ring.lookup(""); ok {
		t.Fatal("empty key must never match")
	}
	if _, ok := ring.lookup(HashKey(cpackKey)); ok {
		t.Fatal("presenting the stored hash must not authenticate")
	}
}

// A bound key publishes for its own group.
func TestKeyed_BoundKeyOwnGroup202(t *testing.T) {
	k := newKeyedRouter(t, Config{Keys: testRing(t)})
	if rec := post(t, k.h, cpackKey, bodyForGroup("CPACK")); rec.Code != http.StatusAccepted {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if rec := postGroupHeader(t, k.h, incoplastKey, "incoplast", noGroupBody); rec.Code != http.StatusAccepted {
		t.Fatalf("header-routed status %d: %s", rec.Code, rec.Body.String())
	}
	if k.a.count() != 2 || k.b.count() != 1 { // tags: 2 in bodyForGroup, 1 in noGroupBody
		t.Fatalf("A=%d B=%d tags, want 2/1", k.a.count(), k.b.count())
	}
}

// The core fix: a CPACK key cannot publish as INCOPLAST (body or header), and
// a foreign UNKNOWN group gets the same answer, so tenants can't be probed.
func TestKeyed_WrongGroup403(t *testing.T) {
	k := newKeyedRouter(t, Config{APIKey: testKey, Keys: testRing(t)})
	for _, tc := range []struct{ name, header, body string }{
		{"body group", "", bodyForGroup("INCOPLAST")},
		{"header group", "INCOPLAST", noGroupBody},
		{"body wins over header", "CPACK", bodyForGroup("INCOPLAST")},
		{"unknown group", "", bodyForGroup("NOTATENANT")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := postGroupHeader(t, k.h, cpackKey, tc.header, tc.body)
			if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), "key not authorised for group") {
				t.Fatalf("got %d %s, want 403 key not authorised", rec.Code, rec.Body.String())
			}
		})
	}
	if k.a.count() != 0 || k.b.count() != 0 {
		t.Fatalf("a rejected request reached a sink: A=%d B=%d", k.a.count(), k.b.count())
	}
	if got := k.count(OutcomeRejectedKeyScope); got != 4 {
		t.Fatalf("rejected_key_scope = %v want 4", got)
	}
	logs := k.logs.String()
	if !strings.Contains(logs, "key_groups=CPACK") {
		t.Fatalf("rejection log should name the key's bound groups: %s", logs)
	}
	for _, secret := range []string{cpackKey, HashKey(cpackKey), testKey} {
		if strings.Contains(logs, secret) {
			t.Fatal("logs contain key material")
		}
	}
}

func TestKeyed_UnknownKey401(t *testing.T) {
	k := newKeyedRouter(t, Config{APIKey: testKey, Keys: testRing(t)})
	for _, key := range []string{"", "nope", HashKey(cpackKey)} {
		if rec := post(t, k.h, key, bodyForGroup("CPACK")); rec.Code != http.StatusUnauthorized {
			t.Fatalf("key %q: status %d want 401", key, rec.Code)
		}
	}
	if got := k.count(OutcomeRejectedAuth); got != 3 {
		t.Fatalf("rejected_auth = %v want 3", got)
	}
}

// Legacy key, flag on (default): any group is admitted, counted, WARN-logged
// once per group (rate-limited), never with the key.
func TestKeyed_LegacyAllowedByDefault(t *testing.T) {
	k := newKeyedRouter(t, Config{APIKey: testKey, Keys: testRing(t)})
	for i := 0; i < 3; i++ {
		if rec := post(t, k.h, testKey, bodyForGroup("INCOPLAST")); rec.Code != http.StatusAccepted {
			t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
	}
	if rec := post(t, k.h, testKey, bodyForGroup("CPACK")); rec.Code != http.StatusAccepted {
		t.Fatalf("status %d", rec.Code)
	}
	if got := k.count(OutcomeLegacyKey); got != 4 {
		t.Fatalf("legacy_key = %v want 4", got)
	}
	logs := k.logs.String()
	if n := strings.Count(logs, "deprecated shared ingest key used"); n != 2 {
		t.Fatalf("deprecation WARN lines = %d want 2 (one per group): %s", n, logs)
	}
	if !strings.Contains(logs, "group=INCOPLAST") || strings.Contains(logs, testKey) {
		t.Fatalf("WARN must name the group and never the key: %s", logs)
	}
}

// Legacy key, flag off: 401 with a reason in the log; per-tenant keys still work.
func TestKeyed_LegacyDisabled401(t *testing.T) {
	k := newKeyedRouter(t, Config{APIKey: testKey, Keys: testRing(t), LegacyKeyDisabled: true})
	if rec := post(t, k.h, testKey, bodyForGroup("CPACK")); rec.Code != http.StatusUnauthorized {
		t.Fatalf("legacy key with flag off: status %d want 401", rec.Code)
	}
	if !strings.Contains(k.logs.String(), "legacy shared key disabled") {
		t.Fatalf("log should say why: %s", k.logs.String())
	}
	if rec := post(t, k.h, cpackKey, bodyForGroup("CPACK")); rec.Code != http.StatusAccepted {
		t.Fatalf("per-tenant key with legacy off: status %d", rec.Code)
	}
	if k.count(OutcomeLegacyKey) != 0 {
		t.Fatal("legacy_key counted while disabled")
	}
}

// Single-tenant agents honour the binding too, using the agent's scope as the
// group when the body names none.
func TestKeyed_SingleMode(t *testing.T) {
	sink := &captureSink{}
	srv := New(Config{Keys: testRing(t), ScopeGroup: "CPACK"}, sink.fn,
		prometheus.NewCounterVec(prometheus.CounterOpts{Name: "x"}, []string{"outcome"}),
		slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)))
	h := srv.Handler()
	if rec := post(t, h, cpackKey, noGroupBody); rec.Code != http.StatusAccepted {
		t.Fatalf("own scope, no body group: %d", rec.Code)
	}
	if rec := post(t, h, incoplastKey, noGroupBody); rec.Code != http.StatusForbidden {
		t.Fatalf("foreign key on a CPACK agent: %d want 403", rec.Code)
	}
}

func TestKeyed_NoUsableKeyPanics(t *testing.T) {
	for name, cfg := range map[string]Config{
		"nothing":                  {},
		"legacy disabled, no ring": {APIKey: testKey, LegacyKeyDisabled: true},
		"empty ring":               {Keys: &KeyRing{}},
	} {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Fatal("want panic")
				}
			}()
			NewRouter(cfg, map[string]Sink{"CPACK": (&captureSink{}).fn}, nil, slog.Default())
		})
	}
}

// The ring lookup scans every entry with constant-time compares: the result
// must not depend on entry position, and a near-miss digest must not match.
func TestKeyRing_ConstantTimeScanAllEntries(t *testing.T) {
	raw := `{`
	for i := 0; i < 50; i++ {
		raw += `"` + HashKey("filler-"+string(rune('a'+i%26))+strings.Repeat("x", i)) + `": ["F"],`
	}
	raw += `"` + HashKey(cpackKey) + `": ["CPACK"]}`
	ring, err := ParseKeyRing([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if e, ok := ring.lookup(cpackKey); !ok || e.label != "CPACK" {
		t.Fatalf("lookup across many entries = %+v %v", e, ok)
	}
	if _, ok := ring.lookup(cpackKey + "x"); ok {
		t.Fatal("near-miss key matched")
	}
	testing.AllocsPerRun(10, func() { ring.lookup(cpackKey) }) // smoke: no panic on repeated scans
}
