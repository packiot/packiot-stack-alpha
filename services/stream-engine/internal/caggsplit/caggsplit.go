// Package caggsplit turns a `WITH … UPDATE|INSERT|DELETE …` statement that reads
// a REAL-TIME continuous aggregate into two statements: a read that is planned as
// a SELECT, and the unchanged DML fed from the read's result.
//
// WHY (ADR-0063 Phase A2). TimescaleDB constifies a real-time cagg's watermark
// (cagg_watermark()) only when it plans a SELECT — a CREATE TABLE AS counts,
// because its query is a SELECT. Inside INSERT/UPDATE/DELETE the watermark stays a
// runtime function call, so the planner cannot exclude the materialized side and
// prices the real-time branch over EVERY raw equipment_values chunk (staging,
// 2026-10-14: hundreds of millions of rows, total cost ~2.5e8). Under those
// estimates it picks plans that are catastrophically slow: the shift values pass
// read 63 rows in 0.68 s as a SELECT and 250-296 s inside its UPDATE, which timed
// out every runtime-rollup tick. #1770 (cpac deriver) and #1775 (closer, hour
// speed) fixed single statements by hand; this package is the same transformation
// as a reusable, shape-checked text operation.
//
// THE TRANSFORMATION. Given
//
//	WITH a AS (…), b AS (…), c AS (…)
//	UPDATE t SET … FROM c …
//
// and Spec{Temp: "x", Tail: "SELECT * FROM c", Feeds: ["c"]}, Split returns
//
//	DROP TABLE IF EXISTS pg_temp.x;
//	CREATE TEMP TABLE x ON COMMIT DROP AS
//	WITH a AS (…), b AS (…), c AS (…)
//	SELECT * FROM c;
//	WITH c AS (SELECT * FROM x)
//	UPDATE t SET … FROM c …
//
// The CTE chain and the DML text are byte-for-byte the original; only the CTEs the
// DML reads are re-pointed at the materialized rows. Both run in ONE transaction
// (an explicit one, or the implicit one of a multi-statement simple query), so
// they see the same now(), and CREATE TABLE AS keeps the exact column types, so
// the DML computes the same values (golden tests compare old vs new row for row).
// DROP … IF EXISTS lets a pass run twice in one transaction (the history renderer).
//
// The strings run as ONE simple-protocol query (several statements): callers must
// execute them without bind arguments, or over the simple protocol (pgx sanitizes
// the arguments into the text), never as a prepared statement.
package caggsplit

import (
	"fmt"
	"regexp"
	"strings"
)

// Spec says how to split one statement.
type Spec struct {
	// Temp is the temp table the read materializes. Unique per statement.
	Temp string
	// Tail is the SELECT that ends the read, over the statement's CTEs. It must
	// return at most one row per key the DML joins on, with the columns the DML
	// reads from every Feed.
	Tail string
	// Feeds are the CTEs the DML reads; each becomes `name AS (SELECT * FROM Temp)`.
	Feeds []string
}

// dmlStart finds the statement's DML keyword at the start of a line (comment lines
// start with "--", so prose that mentions UPDATE never matches).
var dmlStart = regexp.MustCompile(`(?m)^[ \t]*(UPDATE|INSERT|DELETE)\b`)

var ident = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)

// Split returns the read+apply text for stmt (see the package comment).
func (s Spec) Split(stmt string) (string, error) {
	if !ident.MatchString(s.Temp) {
		return "", fmt.Errorf("caggsplit: temp table %q is not a plain identifier", s.Temp)
	}
	if len(s.Feeds) == 0 || strings.TrimSpace(s.Tail) == "" {
		return "", fmt.Errorf("caggsplit %s: Tail and Feeds are required", s.Temp)
	}
	locs := dmlStart.FindAllStringIndex(stmt, -1)
	if len(locs) != 1 {
		return "", fmt.Errorf("caggsplit %s: want exactly one line starting with UPDATE/INSERT/DELETE, found %d", s.Temp, len(locs))
	}
	head := strings.TrimSpace(stmt[:locs[0][0]])
	dml := strings.TrimLeft(stmt[locs[0][0]:], " \t")
	if !strings.HasPrefix(head, "WITH ") {
		return "", fmt.Errorf("caggsplit %s: statement does not start with a WITH clause", s.Temp)
	}
	feeds := make([]string, len(s.Feeds))
	for i, f := range s.Feeds {
		if !ident.MatchString(f) {
			return "", fmt.Errorf("caggsplit %s: feed %q is not a plain identifier", s.Temp, f)
		}
		if !regexp.MustCompile(`\b` + f + `\s+AS\s+(MATERIALIZED\s+)?\(`).MatchString(head) {
			return "", fmt.Errorf("caggsplit %s: feed %q is not a CTE of the statement", s.Temp, f)
		}
		feeds[i] = f + " AS (SELECT * FROM " + s.Temp + ")"
	}
	return "\n\tDROP TABLE IF EXISTS pg_temp." + s.Temp + ";" +
		"\n\tCREATE TEMP TABLE " + s.Temp + " ON COMMIT DROP AS\n\t" + head +
		"\n\t" + strings.TrimSpace(s.Tail) + ";" +
		"\n\tWITH " + strings.Join(feeds, ", ") + "\n\t" + dml, nil
}

// MustSplit is Split for package-level statement templates: a shape mismatch is a
// programming error caught by the first test that loads the package.
func (s Spec) MustSplit(stmt string) string {
	out, err := s.Split(stmt)
	if err != nil {
		panic(err)
	}
	return out
}

// boundary matches the two seams Split inserts: the end of the DROP before the
// read, and the end of the read before the apply. Only these exact shapes count,
// so a ";" inside a comment of the original statement never splits it.
var boundary = regexp.MustCompile(`;\n\t(CREATE TEMP TABLE [a-z_][a-z0-9_]* ON COMMIT DROP AS\n|WITH [a-z_][a-z0-9_]* AS \(SELECT \* FROM [a-z_][a-z0-9_]*\))`)

// Statements returns the three statements of a rendered Split result — DROP,
// CREATE TEMP TABLE … AS, apply — for tests and EXPLAIN tooling.
func Statements(sql string) []string {
	var out []string
	last := 0
	for _, m := range boundary.FindAllStringIndex(sql, -1) {
		out = append(out, strings.TrimSpace(sql[last:m[0]]))
		last = m[0] + 1 // drop the ";"
	}
	return append(out, strings.TrimSpace(sql[last:]))
}
