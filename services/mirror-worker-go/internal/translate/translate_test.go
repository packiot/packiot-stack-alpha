// translate_test.go — unit tests for the pure helpers in Translator.
//
// The body of Translator.Site / Area / Equipment / ProductionOrder /
// EquipmentEvent runs SQL against live prod + staging pools — those
// integration-shaped tests would need a Postgres fixture and are out of
// scope here. What's testable in isolation:
//
//   - RemapTopic       — pure string substitution (exported for handler use)
//   - Translator.Enterprise — config-only, no DB
//
// If we ever add a fake *db.Prod / *db.Staging behind an interface (the
// translator currently takes concrete types so reach-through SQL works
// the same in prod + tests), the SQL-bound methods become testable too.
package translate

import (
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
)

func TestRemapTopicExported(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		// Real CPACK topic shapes — taken from packml_register dumps.
		{"prod prefix line", "C-PACK/SC/SLEEVE/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1"},
		{"prod prefix unit", "C-PACK/SC/SLEEVE/SLEEVE1/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1"},
		// Idempotent: a topic that already uses the staging prefix passes through.
		{"already staging", "CPACK/SC/SLEEVE/SLEEVE1", "CPACK/SC/SLEEVE/SLEEVE1"},
		// Only the first occurrence is replaced — strings.Replace(...,1).
		// Real prod topics never contain a second 'C-PACK/' segment, but the
		// behaviour is worth pinning so a future regex change is intentional.
		{"first occurrence only", "C-PACK/X/C-PACK/Y", "CPACK/X/C-PACK/Y"},
		// Empty / no prefix — pass through unchanged.
		{"empty", "", ""},
		{"unrelated topic", "OTHER/SC/LINE", "OTHER/SC/LINE"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := RemapTopic(c.in)
			if got != c.want {
				t.Errorf("RemapTopic(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestEnterprise(t *testing.T) {
	cfg := &config.Config{
		ProdEnterpriseID:    1,
		StagingEnterpriseID: 3,
	}
	tr := &Translator{cfg: cfg, logger: slog.Default()}

	t.Run("happy path", func(t *testing.T) {
		got, err := tr.Enterprise(1)
		if err != nil {
			t.Fatalf("Enterprise(1) err = %v", err)
		}
		if got != 3 {
			t.Errorf("Enterprise(1) = %d, want 3", got)
		}
	})

	t.Run("rejects unexpected prod ID", func(t *testing.T) {
		// Defensive — the worker only ever replays one prod enterprise. If a
		// row comes in for a different enterprise (config drift or someone
		// adding a second tenant without the prep work), we want a loud
		// failure, not silent miss-routing.
		_, err := tr.Enterprise(99)
		if err == nil {
			t.Errorf("Enterprise(99) err = nil, want non-nil")
		}
	})
}

// TestProductionOrderQueryUsesIDOrder pins the column name in the
// ProductionOrder SQL. The original TS port referenced a fictional column
// `nu_production_order` that doesn't exist on prod (or staging) — the live
// /metrics DLQ surfaced ~120 SQLSTATE 42703 failures from this exact code
// path. The actual human PO number column is `id_order` (integer, unique
// per id_enterprise — see prod's `production_orders_un` constraint).
//
// We can't easily exercise the SQL at unit-test time (it needs a live pg
// pool), so we instead read the source file and assert the textual SQL
// uses the right column. Crude but effective — catches a regression at
// `go test` time with zero infra cost.
//
// We scan only the SQL string literals (text between back-ticks) so the
// fix's explanatory comments are free to reference the bug-string by
// name without tripping the guard.
func TestProductionOrderQueryUsesIDOrder(t *testing.T) {
	src, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("read translate.go: %v", err)
	}
	body := string(src)

	// Carve out the SQL string literals — anything between back-ticks.
	// A regex would also work; manual scan keeps the dep surface tiny.
	var sqlOnly strings.Builder
	inBacktick := false
	for _, ch := range body {
		if ch == '`' {
			inBacktick = !inBacktick
			continue
		}
		if inBacktick {
			sqlOnly.WriteRune(ch)
		}
	}
	sqlBlob := sqlOnly.String()

	if strings.Contains(sqlBlob, "nu_production_order") {
		t.Errorf("translate.go SQL still references nu_production_order — prod uses id_order; the column nu_production_order does not exist (SQLSTATE 42703 in DLQ)")
	}
	// Positive guard — both the prod-side and staging-side queries must
	// filter on id_order.
	wantSubs := []string{
		"SELECT id_order FROM production_orders",
		"WHERE id_order = $1 AND id_enterprise = $2",
	}
	for _, s := range wantSubs {
		if !strings.Contains(sqlBlob, s) {
			t.Errorf("translate.go SQL missing expected substring %q after id_order fix", s)
		}
	}
}

// TestProductionOrderFallbackExcludesClaimedStagingPOs pins the
// claimed-staging-PO guard (2026-06-26 fix): the business-key fallback
// on staging must exclude POs already mapped to a different prod PO via
// mirror_id_map. Without it, the same staging PO is returned for every
// prod PO sharing an id_order — leading to wrong /stop calls + 500s in
// DLQ. Real shape from session 68: 4 stuck order-changed entries all
// targeting staging PO 12887 (claimed by prod PO 1642025) while the
// real prod targets were 1645742/1642024/etc.
//
// Same SQL-blob-scan pattern as the id_order guard above.
func TestProductionOrderFallbackExcludesClaimedStagingPOs(t *testing.T) {
	src, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("read translate.go: %v", err)
	}
	body := string(src)

	var sqlOnly strings.Builder
	inBacktick := false
	for _, ch := range body {
		if ch == '`' {
			inBacktick = !inBacktick
			continue
		}
		if inBacktick {
			sqlOnly.WriteRune(ch)
		}
	}
	sqlBlob := sqlOnly.String()

	// The NOT IN exclusion subquery must reference mirror_id_map. Match
	// on key tokens that would survive a reasonable reformat.
	wantSubs := []string{
		"NOT IN",
		"SELECT staging_id FROM mirror_id_map",
		"WHERE entity_type = 'production_order'",
	}
	for _, s := range wantSubs {
		if !strings.Contains(sqlBlob, s) {
			t.Errorf("translate.go SQL missing claimed-staging-PO guard substring %q — the business-key fallback would pick already-mapped staging POs for prod POs sharing an id_order", s)
		}
	}
}

// TestEquipmentQueryHasDeterministicOrderBy pins the deterministic
// tie-break added 2026-06-29. Before the fix, the prod-side packml_register
// SELECT used `ORDER BY active DESC NULLS LAST LIMIT 1`, which is
// non-deterministic on ties: Postgres returned whichever row it scanned
// first. Live data hit a worst case on prod equipment 84 (TEXA): 4 of
// its 7 active packml_register rows carry a literal `LLLLL` typo prefix,
// and the tie-break happened to pick one of the corrupted ones —
// silently dropping every TEXA event from the staging mirror.
//
// The fix sorts by length(packml_topic) ASC to prefer canonical short
// topics, then by id_packml_register ASC as a final unique tail.
// Same SQL-blob-scan pattern as the other regression guards: we read
// translate.go, extract the back-tick literals, and assert the strings
// are present. A regex would work too; manual scan keeps deps tiny.
func TestEquipmentQueryHasDeterministicOrderBy(t *testing.T) {
	src, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("read translate.go: %v", err)
	}
	body := string(src)

	var sqlOnly strings.Builder
	inBacktick := false
	for _, ch := range body {
		if ch == '`' {
			inBacktick = !inBacktick
			continue
		}
		if inBacktick {
			sqlOnly.WriteRune(ch)
		}
	}
	sqlBlob := sqlOnly.String()

	// Anchor on the canonical-shortness and unique-tail tokens. Match on
	// the parameterized form so reformatting (whitespace / line wrapping)
	// doesn't break the test.
	wantSubs := []string{
		"length(pr.packml_topic) ASC",
		"pr.id_packml_register ASC",
	}
	for _, s := range wantSubs {
		if !strings.Contains(sqlBlob, s) {
			t.Errorf("translate.go Equipment SQL missing deterministic-order substring %q — without it, equipments with multiple active packml_register rows get a non-deterministic tie-break (prod equipment 84 hit this with `LLLLL`-prefixed corrupted topics)", s)
		}
	}
}

// TestEquipmentEventMatcherHasStartDriftGuard pins the lower-bound on
// staging.ts_event introduced to fix DLQ ids 259 + 283 — stale open-
// ended staging events (ts_end IS NULL, opened days ago) were matching
// every later prod event via COALESCE(ts_end, now()) overlap. Without
// the lower bound, the matcher returns absurd cross-day mismatches.
//
// Same shape of guard as TestProductionOrderQueryUsesIDOrder: scan SQL
// blobs only, fail if the predicate is missing.
func TestEquipmentEventMatcherHasStartDriftGuard(t *testing.T) {
	src, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatalf("read translate.go: %v", err)
	}
	body := string(src)

	var sqlOnly strings.Builder
	inBacktick := false
	for _, ch := range body {
		if ch == '`' {
			inBacktick = !inBacktick
			continue
		}
		if inBacktick {
			sqlOnly.WriteRune(ch)
		}
	}
	sqlBlob := sqlOnly.String()

	// The strict-match query MUST bound staging.ts_event from below.
	// We anchor on the parameterized form to avoid false positives from
	// any other `ts_event >=` predicates that might appear later.
	want := "ts_event >= $3::timestamptz - ($6::int * interval '1 second')"
	if !strings.Contains(sqlBlob, want) {
		t.Errorf("translate.go matcher SQL missing start-drift lower bound %q — without it, stale open-ended staging events match unrelated later prod events (DLQ ids 259, 283)", want)
	}
}
