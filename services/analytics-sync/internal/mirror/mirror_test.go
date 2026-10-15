package mirror

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestParseEnterprises(t *testing.T) {
	got, err := ParseEnterprises(" 5, 7,5 ,")
	if err != nil || len(got) != 2 || got[0] != 5 || got[1] != 7 {
		t.Fatalf("got %v %v", got, err)
	}
	if got, _ := ParseEnterprises(""); len(got) != 0 {
		t.Fatalf("empty must be off, got %v", got)
	}
	for _, bad := range []string{"5,x", "0", "-5", "5.0"} {
		if _, err := ParseEnterprises(bad); err == nil {
			t.Fatalf("%q must fail loudly (a typo must never disable the mirror)", bad)
		}
	}
}

func TestLoadDefaultsIdle(t *testing.T) {
	t.Setenv("PROD_MIRROR_ENTERPRISES", "")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Enabled() {
		t.Fatal("no enterprises = idle")
	}
	if c.IDBlock != 1_000_000_000 || c.NameSuffix != " (mirror)" || c.LookbackDays != 35 {
		t.Fatalf("defaults: %+v", c)
	}
	t.Setenv("PROD_REFLECT_NAME_SUFFIX", "")
	c, _ = Load()
	if c.NameSuffix != "" {
		t.Fatal("an explicitly empty suffix keeps production's name verbatim")
	}
}

func TestDiffBuckets(t *testing.T) {
	src := map[string]Fingerprint{"a": {1, "x"}, "b": {2, "y"}, "c": {1, "z"}}
	dst := map[string]Fingerprint{"a": {1, "x"}, "b": {2, "Y"}, "d": {3, "w"}}
	got := strings.Join(DiffBuckets(src, dst), ",")
	if got != "b,c,d" {
		t.Fatalf("got %s", got)
	}
}

func TestDiffRows(t *testing.T) {
	src := map[string]SrcRow{"[1]": {Hash: "h1"}, "[2]": {Hash: "h2"}, "[3]": {Hash: "h3"}}
	dst := map[string]string{"[1]": "h1", "[2]": "OLD", "[4]": "h4"}
	o := DiffRows(src, dst, Mirror)
	if strings.Join(o.Upsert, ",") != "[2],[3]" || strings.Join(o.Delete, ",") != "[4]" || o.Divergent != 0 {
		t.Fatalf("mirror: %+v", o)
	}
	o = DiffRows(src, dst, AppendOnly)
	if strings.Join(o.Upsert, ",") != "[3]" || len(o.Delete) != 0 || o.Divergent != 2 {
		t.Fatalf("append-only must only insert missing rows and count the rest: %+v", o)
	}
}

func TestStagingWritesDetector(t *testing.T) {
	src := map[string]SrcRow{"[1]": {Hash: "h1"}, "[2]": {Hash: "NEW"}}
	// [1]: the reflector wrote h1, production still has h1, staging differs again → a staging write.
	// [2]: production changed since → a legitimate production change, not a staging write.
	// [9]: the reflector deleted it and it is back on staging → a staging write.
	ops := Ops{Upsert: []string{"[1]", "[2]"}, Delete: []string{"[9]"}}
	n := StagingWrites(ops, src, map[string]string{"[1]": "h1", "[2]": "OLD"}, map[string]bool{"[9]": true})
	if n != 2 {
		t.Fatalf("got %d, want 2", n)
	}
}

func TestKeyValuesKeepsBigints(t *testing.T) {
	v, err := keyValues(`[9000002449267960, "2026-10-15T10:00:00+00:00", true]`)
	if err != nil {
		t.Fatal(err)
	}
	if v[0] != "9000002449267960" || v[1] != "2026-10-15T10:00:00+00:00" || v[2] != "true" {
		t.Fatalf("got %#v", v)
	}
	if _, err := keyValues(`[1, null]`); err == nil {
		t.Fatal("a NULL key column must be refused")
	}
}

func TestSpecIsConsistent(t *testing.T) {
	seen := map[string]bool{}
	for _, tb := range Reflected {
		if seen[tb.Name] {
			t.Fatalf("%s listed twice", tb.Name)
		}
		seen[tb.Name] = true
		if _, local := Local[tb.Name]; local {
			t.Fatalf("%s is both reflected and local", tb.Name)
		}
		if tb.Hot && tb.TimeCol == "" {
			t.Fatalf("%s: Hot needs TimeCol", tb.Name)
		}
		if !strings.Contains(tb.Name, ".") {
			t.Fatalf("%s: schema-qualify", tb.Name)
		}
	}
	// the environment-specific key must never be copied
	if !contains(Reflected[0].Exclude, "api_key") || Reflected[0].Name != "core.enterprises" {
		t.Fatal("core.enterprises must come first and exclude api_key")
	}
}

func catalogFixture() Catalog {
	return Catalog{
		"core.enterprises": {Cols: []Column{{Name: "id_enterprise"}, {Name: "nm_enterprise"}, {Name: "api_key"}, {Name: "updated_at"}},
			PK: []string{"id_enterprise"}, TenantKey: "id_enterprise"},
		"core.equipments": {Cols: []Column{{Name: "id_equipment"}, {Name: "id_enterprise"}, {Name: "lead_machine"}, {Name: "nm"}},
			PK: []string{"id_equipment"}, TenantKey: "id_enterprise"},
		"silver.equipment_events": {Cols: []Column{{Name: "id_equipment"}, {Name: "ts_event"}, {Name: "status"}},
			PK: []string{"id_equipment", "ts_event"}, TenantKey: "id_equipment"},
		"core.brand_new": {Cols: []Column{{Name: "id"}, {Name: "id_enterprise"}}, TenantKey: "id_enterprise"},
		"ops._bkp_x":     {Cols: []Column{{Name: "id_enterprise"}}, TenantKey: "id_enterprise"},
	}
}

func TestUnclassified(t *testing.T) {
	got := Unclassified(catalogFixture())
	if strings.Join(got, ",") != "core.brand_new" {
		t.Fatalf("got %v (a new tenant table must be reported; scratch tables never)", got)
	}
}

func TestPlanEnterprisesNeverCopiesApiKeyAndSuffixesName(t *testing.T) {
	cat := catalogFixture()
	p, why := buildPlan(Reflected[0], cat, cat, 35, " (mirror)")
	if p == nil {
		t.Fatal(why)
	}
	if contains(p.insCols, "api_key") {
		t.Fatal("api_key must not be written")
	}
	if !strings.Contains(p.cmpSrc, "'api_key'") || !strings.Contains(p.insSrc, "'api_key'") {
		t.Fatal("api_key must be removed from the production row")
	}
	if !strings.Contains(p.insSrc, `t.nm_enterprise || ' (mirror)'`) {
		t.Fatalf("name projection missing: %s", p.insSrc)
	}
	if strings.Contains(p.upsertSQL(), `"api_key"`) {
		t.Fatal("upsert touches api_key")
	}
	if !strings.Contains(p.upsertSQL(), `ON CONFLICT ("id_enterprise") DO UPDATE SET "nm_enterprise" = EXCLUDED."nm_enterprise"`) {
		t.Fatalf("upsert: %s", p.upsertSQL())
	}
}

func TestPlanSelfRefAndColumnDrift(t *testing.T) {
	src := catalogFixture()
	dst := catalogFixture()
	m := dst["core.equipments"]
	m.Cols = append(m.Cols, Column{Name: "staging_only"})
	dst["core.equipments"] = m
	var eq Table
	for _, tb := range Reflected {
		if tb.Name == "core.equipments" {
			eq = tb
		}
	}
	p, why := buildPlan(eq, src, dst, 35, "")
	if p == nil {
		t.Fatal(why)
	}
	if contains(p.insCols, "staging_only") || len(p.missing) != 1 {
		t.Fatalf("a column on one side only is not mirrored: %v %v", p.insCols, p.missing)
	}
	up := p.upsertSQL()
	if !strings.Contains(up, "NULL") || strings.Contains(up, `"lead_machine" = EXCLUDED`) {
		t.Fatalf("self references go in NULL and are not updated by the upsert: %s", up)
	}
	if !strings.Contains(p.selfRefSQL(), `"lead_machine" = r."lead_machine"`) {
		t.Fatalf("selfRef: %s", p.selfRefSQL())
	}
}

func TestPlanHotWindowAndLiteralDeletes(t *testing.T) {
	cat := catalogFixture()
	var ev Table
	for _, tb := range Reflected {
		if tb.Name == "silver.equipment_events" {
			ev = tb
		}
	}
	p, _ := buildPlan(ev, cat, cat, 7, "")
	if !strings.Contains(p.fingerprintSQL("src", 5, true), "make_interval(days => 7)") {
		t.Fatal("hot pass must bound the time window")
	}
	if strings.Contains(p.fingerprintSQL("src", 5, false), "make_interval") {
		t.Fatal("full pass must not bound the time window")
	}
	d := p.deleteSQL(5)
	if !strings.Contains(d, `t."id_equipment" = $1 AND t."ts_event" = $2`) ||
		!strings.Contains(d, "core.equipments e WHERE e.id_enterprise = 5") {
		t.Fatalf("delete must be keyed by literal values and fenced by tenant: %s", d)
	}
}

func TestPlanRefusesMissingOrMismatchedTables(t *testing.T) {
	cat := catalogFixture()
	if p, _ := buildPlan(Table{Name: "core.nope"}, cat, cat, 1, ""); p != nil {
		t.Fatal("absent table must be skipped")
	}
	other := catalogFixture()
	m := other["silver.equipment_events"]
	m.TenantKey = "id_enterprise"
	other["silver.equipment_events"] = m
	if p, _ := buildPlan(Table{Name: "silver.equipment_events"}, cat, other, 1, ""); p != nil {
		t.Fatal("a tenant-key mismatch must be skipped, never guessed")
	}
}

// The migration grants exactly the tables the reflector writes, in the same order: a table added to Reflected
// without a grant would fail every pass on staging with "permission denied" (rolled back to its savepoint).
func TestMigrationGrantsMatchSpec(t *testing.T) {
	b, err := os.ReadFile("../../../../db/migrations/t-prod-reflector-roles/01-up.sql")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)reflected text\[\] := ARRAY\[(.*?)\];`).FindSubmatch(b)
	if m == nil {
		t.Fatal("reflected array not found in the migration")
	}
	got := regexp.MustCompile(`'([a-z_]+\.[a-z_]+)'`).FindAllSubmatch(m[1], -1)
	if len(got) != len(Reflected) {
		t.Fatalf("migration lists %d tables, spec %d", len(got), len(Reflected))
	}
	for i, g := range got {
		if string(g[1]) != Reflected[i].Name {
			t.Fatalf("position %d: migration %s, spec %s", i, g[1], Reflected[i].Name)
		}
	}
}
