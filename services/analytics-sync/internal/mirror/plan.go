package mirror

import (
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// plan is the SQL for one reflected table, built from BOTH catalogs: only columns present on both sides are
// compared and written, so a migration applied to one environment first (a deploy window) degrades to "that column
// is not mirrored yet", never to a failed pass.
type plan struct {
	t        Table
	tbl      string   // quoted schema.table
	key      []string // primary key (staging's; must exist on both sides); empty = replace whole buckets
	tenant   string   // tenant key column
	insCols  []string // written
	setCols  []string // updated on conflict
	selfRef  []string // present self-referencing columns
	cmpSrc   string   // production row as compared (jsonb)
	cmpDst   string   // staging row as compared (jsonb)
	insSrc   string   // production row as written (jsonb)
	bucket   string   // bucket expression (text)
	hotSince string   // " AND t.<TimeCol> >= now() - …" for hot passes ("" = none)
	missing  []string // columns on one side only (reported once)
}

func qi(parts ...string) string { return pgx.Identifier(parts).Sanitize() }

func qcols(cols []string, prefix string) string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = prefix + qi(c)
	}
	return strings.Join(out, ", ")
}

func lit(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func textArray(cols []string) string {
	if len(cols) == 0 {
		return "ARRAY[]::text[]"
	}
	q := make([]string, len(cols))
	for i, c := range cols {
		q[i] = lit(c)
	}
	return "ARRAY[" + strings.Join(q, ", ") + "]::text[]"
}

func minus(all []string, drop ...[]string) []string {
	skip := map[string]bool{}
	for _, d := range drop {
		for _, c := range d {
			skip[c] = true
		}
	}
	var out []string
	for _, c := range all {
		if !skip[c] {
			out = append(out, c)
		}
	}
	return out
}

func names(cols []Column) []string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = c.Name
	}
	return out
}

// buildPlan returns nil (and a reason) when the table cannot be reflected this pass.
func buildPlan(t Table, src, dst Catalog, lookbackDays int, suffix string) (*plan, string) {
	sm, okS := src[t.Name]
	dm, okD := dst[t.Name]
	switch {
	case !okS && !okD:
		return nil, "absent on both sides"
	case !okS:
		return nil, "absent in production"
	case !okD:
		return nil, "absent on staging"
	}
	if dm.TenantKey == "" || dm.TenantKey != sm.TenantKey {
		return nil, fmt.Sprintf("tenant key differs (production %q, staging %q)", sm.TenantKey, dm.TenantKey)
	}
	schema, name, _ := strings.Cut(t.Name, ".")
	p := &plan{t: t, tbl: qi(schema, name), tenant: dm.TenantKey}

	srcAll, dstAll := names(sm.Cols), names(dm.Cols)
	var common, gen, identAlways []string
	for _, c := range dm.Cols {
		if c.Generated {
			gen = append(gen, c.Name)
			continue
		}
		if c.IdentityAlways {
			identAlways = append(identAlways, c.Name)
		}
		if sm.Has(c.Name) {
			common = append(common, c.Name)
		} else {
			p.missing = append(p.missing, "staging-only "+c.Name)
		}
	}
	for _, c := range sm.Cols {
		if !dm.Has(c.Name) {
			p.missing = append(p.missing, "production-only "+c.Name)
		}
	}
	p.insCols = minus(common, t.Exclude)
	cmpCols := minus(p.insCols, t.Ignore)

	// key: staging's primary key, only if every key column is mirrored
	if len(dm.PK) > 0 && len(minus(dm.PK, p.insCols)) == 0 {
		p.key = dm.PK
	}
	// Append-only tables cannot be updated (that is the point), so their self references go in directly: foreign
	// keys are checked at the end of the INSERT statement, so rows of one chunk may reference each other.
	for _, c := range t.SelfRef {
		if t.Mode == Mirror && contains(p.insCols, c) {
			p.selfRef = append(p.selfRef, c)
		}
	}
	p.setCols = minus(p.insCols, p.key, identAlways, p.selfRef)

	// projections (production side only)
	proj := ""
	projIns := ""
	for col, expr := range t.Project {
		e := strings.ReplaceAll(expr, "{suffix}", lit(suffix))
		if contains(cmpCols, col) {
			proj += " || jsonb_build_object(" + lit(col) + ", " + e + ")"
		}
		if contains(p.insCols, col) {
			projIns += " || jsonb_build_object(" + lit(col) + ", " + e + ")"
		}
	}
	p.cmpSrc = "(to_jsonb(t) - " + textArray(minus(srcAll, cmpCols)) + ")" + proj
	p.cmpDst = "(to_jsonb(t) - " + textArray(minus(dstAll, cmpCols)) + ")"
	p.insSrc = "(to_jsonb(t) - " + textArray(minus(srcAll, p.insCols)) + ")" + projIns

	switch {
	case t.BucketExpr != "":
		p.bucket = t.BucketExpr
	case t.TimeCol != "":
		p.bucket = "coalesce(to_char(t." + qi(t.TimeCol) + " AT TIME ZONE 'UTC', 'YYYY-MM-DD'), 'none')"
	default:
		p.bucket = "'all'"
	}
	if t.Hot && t.TimeCol != "" {
		p.hotSince = fmt.Sprintf(" AND t.%s >= now() - make_interval(days => %d)", qi(t.TimeCol), lookbackDays)
	}
	return p, ""
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func (p *plan) keyExpr() string {
	if len(p.key) == 0 {
		return "md5(to_jsonb(t)::text)"
	}
	return "jsonb_build_array(" + qcols(p.key, "t.") + ")::text"
}

func (p *plan) where(ent int, hot bool) string {
	w := " WHERE " + TenantFilter(p.tenant, ent)
	if hot {
		w += p.hotSince
	}
	return w
}

// fingerprintSQL: per bucket, row count + md5 of the ordered row hashes (byte order, independent of collation).
func (p *plan) fingerprintSQL(side string, ent int, hot bool) string {
	row := p.cmpDst
	if side == "src" {
		row = p.cmpSrc
	}
	k := p.keyExpr()
	if len(p.key) == 0 {
		k = "md5((" + row + ")::text)"
	}
	return "SELECT b, count(*)::bigint, md5(string_agg(h, ',' ORDER BY k COLLATE \"C\", h COLLATE \"C\")) FROM (SELECT " +
		p.bucket + " AS b, " + k + " AS k, md5((" + row + ")::text) AS h FROM " + p.tbl + " t" + p.where(ent, hot) +
		") x GROUP BY b"
}

// rowsSQL fetches the keyed rows of the given buckets ($1 text[]). src also returns the row to write.
func (p *plan) rowsSQL(side string, ent int, hot bool) string {
	if side == "src" {
		return "SELECT " + p.keyExpr() + ", md5((" + p.cmpSrc + ")::text), (" + p.insSrc + ")::text FROM " + p.tbl +
			" t" + p.where(ent, hot) + " AND " + p.bucket + " = ANY($1::text[])"
	}
	return "SELECT " + p.keyExpr() + ", md5((" + p.cmpDst + ")::text) FROM " + p.tbl + " t" + p.where(ent, hot) +
		" AND " + p.bucket + " = ANY($1::text[])"
}

// srcBucketRowsSQL fetches every production row of the given buckets (replace-bucket tables, no key).
func (p *plan) srcBucketRowsSQL(ent int, hot bool) string {
	return "SELECT " + p.bucket + ", (" + p.insSrc + ")::text FROM " + p.tbl + " t" + p.where(ent, hot) +
		" AND " + p.bucket + " = ANY($1::text[])"
}

// upsertSQL writes $1 (a jsonb array of production rows). Self-referencing columns go in NULL (set by selfRefSQL).
func (p *plan) upsertSQL() string {
	sel := make([]string, len(p.insCols))
	for i, c := range p.insCols {
		if contains(p.selfRef, c) {
			sel[i] = "NULL"
		} else {
			sel[i] = "r." + qi(c)
		}
	}
	s := "INSERT INTO " + p.tbl + " AS t (" + qcols(p.insCols, "") + ") OVERRIDING SYSTEM VALUE SELECT " +
		strings.Join(sel, ", ") + " FROM jsonb_populate_recordset(NULL::" + p.tbl + ", $1::jsonb) r"
	if len(p.key) == 0 {
		return s
	}
	if p.t.Mode == AppendOnly || len(p.setCols) == 0 {
		return s + " ON CONFLICT (" + qcols(p.key, "") + ") DO NOTHING"
	}
	set := make([]string, len(p.setCols))
	for i, c := range p.setCols {
		set[i] = qi(c) + " = EXCLUDED." + qi(c)
	}
	return s + " ON CONFLICT (" + qcols(p.key, "") + ") DO UPDATE SET " + strings.Join(set, ", ")
}

// selfRefSQL sets the self-referencing columns once every row of the pass exists.
func (p *plan) selfRefSQL() string {
	set := make([]string, len(p.selfRef))
	for i, c := range p.selfRef {
		set[i] = qi(c) + " = r." + qi(c)
	}
	on := make([]string, len(p.key))
	for i, k := range p.key {
		on[i] = "t." + qi(k) + " = r." + qi(k)
	}
	return "UPDATE " + p.tbl + " t SET " + strings.Join(set, ", ") + " FROM jsonb_populate_recordset(NULL::" + p.tbl +
		", $1::jsonb) r WHERE " + strings.Join(on, " AND ") + " AND ROW(" + qcols(p.selfRef, "t.") + ") IS DISTINCT FROM ROW(" +
		qcols(p.selfRef, "r.") + ")"
}

// deleteSQL deletes ONE row by literal key values (simple protocol: constants, so TimescaleDB excludes chunks at
// plan time — the stable-bound silent-no-op class on compressed chunks cannot happen). Tenant filter kept as a fence.
func (p *plan) deleteSQL(ent int) string {
	on := make([]string, len(p.key))
	for i, k := range p.key {
		on[i] = "t." + qi(k) + " = $" + itoa(i+1)
	}
	return "DELETE FROM " + p.tbl + " t" + p.where(ent, false) + " AND " + strings.Join(on, " AND ")
}

// deleteBucketSQL empties one bucket of a replace-bucket table ($1 = bucket).
func (p *plan) deleteBucketSQL(ent int, hot bool) string {
	return "DELETE FROM " + p.tbl + " t" + p.where(ent, hot) + " AND " + p.bucket + " = $1"
}
