package caggsplit

// SQL-text ratchet for the whole stream-engine module (ADR-0063 A3). Two ways to
// flood pg_stat_statements (pgss) with one-call entries, each with its own rule:
//
//  1. A temp table created per transaction (CREATE TEMP TABLE … ON COMMIT DROP)
//     gets a new OID every time, and PG15 pgss jumbles DML by relation OID: every
//     statement reading it gets a new queryid every tick (6,245 such entries filled
//     staging's pgss on 2026-10-14). The engine keeps its temp tables for the
//     session (Fill / Snapshot / Pass.Run). The remaining ON COMMIT DROP texts are
//     the self-contained templates the parity accessors and psql scripts run;
//     their count per file is frozen below. A new one fails this test: use a
//     session table, or add it here with the reason.
//
//  2. A value formatted into SQL TEXT. pgss replaces constants with $n in DML and
//     SELECT, so a literal there is harmless — but utility statements (CREATE
//     TABLE AS, COPY, CREATE INDEX, ANALYZE, DO) are hashed by their text, and the
//     engine now runs its cagg reads as COPY. A timestamp formatted into one would
//     make every tick a new entry. Bind it ($n) in DML, or bucket it (truncate to
//     the hour/day) where a literal is required for chunk exclusion
//     (feedback: "DML on TSDB compressed chunks with a stable bound silently
//     UPDATE 0 — literal bounds").

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// onCommitDropAllowed: file → number of string literals that may contain
// "ON COMMIT DROP" (templates + their renderers), as of 2026-10-14.
var onCommitDropAllowed = map[string]int{
	"internal/rollup/hour.go":         2, // hourEligibleSQL, hourSpeedSQL (templates; engine: fillElig / hourSpeedPass)
	"internal/rollup/shift.go":        2, // shiftEligibleSQL, shiftEventsSQL (engine: fillElig / shiftEventsPass)
	"internal/rollup/day.go":          1, // dayEligibleSQL (engine: fillElig)
	"internal/rollup/backfill.go":     1, // hourBackfillEligibleSQL (engine: fillElig)
	"internal/rollup/cagg_split.go":   1, // mustParseCTASPass reads the hourSpeedSQL form
	"internal/caggsplit/exec.go":      2, // Pass.SQL, CTASSelect
	"internal/caggsplit/caggsplit.go": 1, // the Statements boundary regexp
}

var (
	// a timestamp literal written into SQL text
	literalTS = regexp.MustCompile(`'%[^']*'::(timestamptz|timestamp|date)\b|'20[0-9]{2}-[01][0-9]-[0-3][0-9][ T0-9:.+-]*'`)
	sqlVerb   = regexp.MustCompile(`(?i)\b(SELECT|INSERT\s+INTO|UPDATE\s+\S+\s+(\S+\s+)?SET|DELETE\s+FROM|COPY|CREATE\s+(TEMP\s+)?TABLE|CREATE\s+INDEX)\b`)
)

func moduleRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func TestSQLTextRatchet(t *testing.T) {
	root := moduleRoot(t)
	fset := token.NewFileSet()
	onCommitDrop := map[string]int{}
	var violations []string
	err := filepath.WalkDir(root, func(path string, de fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if de.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		ast.Inspect(f, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				s, err := strconv.Unquote(x.Value)
				if err != nil {
					return true
				}
				if strings.Contains(s, "ON COMMIT DROP") {
					onCommitDrop[rel]++
				}
				if sqlVerb.MatchString(s) && literalTS.MatchString(s) {
					violations = append(violations, fset.Position(x.Pos()).String()+": timestamp literal in SQL text: "+literalTS.FindString(s))
				}
			case *ast.CallExpr:
				// fmt.Sprintf("…SQL…", …, t.Format(…), …)
				sel, ok := x.Fun.(*ast.SelectorExpr)
				if !ok || sel.Sel.Name != "Sprintf" || len(x.Args) < 2 {
					return true
				}
				lit, ok := x.Args[0].(*ast.BasicLit)
				if !ok {
					return true
				}
				format, _ := strconv.Unquote(lit.Value)
				if !sqlVerb.MatchString(format) {
					return true
				}
				for _, a := range x.Args[1:] {
					if c, ok := a.(*ast.CallExpr); ok {
						if s, ok := c.Fun.(*ast.SelectorExpr); ok && (s.Sel.Name == "Format" || s.Sel.Name == "AppendFormat") {
							violations = append(violations, fset.Position(a.Pos()).String()+": time formatted into SQL text")
						}
					}
				}
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for file, n := range onCommitDrop {
		if allowed := onCommitDropAllowed[file]; n > allowed {
			violations = append(violations, file+": "+strconv.Itoa(n)+" ON COMMIT DROP temp table text(s), "+strconv.Itoa(allowed)+
				" allowed — a per-transaction temp table gives every statement reading it a new pg_stat_statements queryid "+
				"every run; use a session table (caggsplit.Fill / Snapshot / Pass.Run)")
		}
	}
	for _, v := range violations {
		t.Error(v)
	}
	if len(onCommitDrop) == 0 {
		t.Fatal("found no ON COMMIT DROP text at all — the scan is not looking at the module")
	}
}

// The ratchet's own patterns, so it cannot pass vacuously.
func TestSQLTextRatchetPatterns(t *testing.T) {
	for _, bad := range []string{
		`SELECT * FROM x WHERE ts >= '%s'::timestamptz`,
		`DELETE FROM x WHERE ts < '2026-10-14 21:00:00+00'`,
		`COPY (SELECT 1 WHERE now() > '2026-10-14') TO STDOUT`,
	} {
		if !(sqlVerb.MatchString(bad) && literalTS.MatchString(bad)) {
			t.Errorf("not caught: %s", bad)
		}
	}
	for _, ok := range []string{
		`SELECT * FROM x WHERE ts >= now() - interval '65 minutes'`,
		`UPDATE x SET a = 1 WHERE ts >= $1::timestamptz`,
		`mint %s.equipment_events eq=%d ts=%s`, // a log description, not SQL
	} {
		if sqlVerb.MatchString(ok) && literalTS.MatchString(ok) {
			t.Errorf("false positive: %s", ok)
		}
	}
}
