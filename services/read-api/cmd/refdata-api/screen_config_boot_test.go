package main

import (
	"bytes"
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// fakeRow / fakeQuerier stand in for the pool in the boot check.
type fakeRow struct {
	vals []bool
	err  error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	for i, d := range dest {
		*(d.(*bool)) = r.vals[i]
	}
	return nil
}

type fakeQuerier struct {
	row fakeRow
	sql string
}

func (f *fakeQuerier) QueryRow(_ context.Context, sql string, _ ...any) pgx.Row {
	f.sql = sql
	return f.row
}

func TestCheckScreenConfigTable(t *testing.T) {
	cases := []struct {
		name                    string
		row                     fakeRow
		wantExists, wantWrite   bool
		wantLevel, wantLogMatch string
	}{
		{"ready", fakeRow{vals: []bool{true, true}}, true, true, "INFO", "screen-config table ready"},
		{"missing", fakeRow{vals: []bool{false, false}}, false, false, "ERROR", "t-readapi-screen-config"},
		{"no grant", fakeRow{vals: []bool{true, false}}, true, false, "ERROR", "lacks SELECT/INSERT/UPDATE"},
		{"query error", fakeRow{err: errors.New("boom")}, false, false, "WARN", "readiness check failed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var buf bytes.Buffer
			logger := slog.New(slog.NewJSONHandler(&buf, nil))
			q := &fakeQuerier{row: c.row}
			exists, writable := checkScreenConfigTable(context.Background(), q, logger)
			if exists != c.wantExists || writable != c.wantWrite {
				t.Fatalf("got exists=%v writable=%v; want %v %v", exists, writable, c.wantExists, c.wantWrite)
			}
			out := buf.String()
			if !strings.Contains(out, `"level":"`+c.wantLevel+`"`) || !strings.Contains(out, c.wantLogMatch) {
				t.Fatalf("log %q: want level %s containing %q", out, c.wantLevel, c.wantLogMatch)
			}
			if ddl.MatchString(q.sql) {
				t.Fatalf("the boot check must not issue DDL:\n%s", q.sql)
			}
		})
	}
}

var ddl = regexp.MustCompile(`(?i)\b(CREATE|ALTER|DROP)\s+(OR\s+REPLACE\s+)?(TEMP(ORARY)?\s+)?(SCHEMA|TABLE|(UNIQUE\s+)?INDEX|VIEW|MATERIALIZED|FUNCTION|PROCEDURE|ROLE|EXTENSION|TRIGGER|SEQUENCE|POLICY|TYPE)\b|\bTRUNCATE\s+(TABLE\s+)?[a-z_."]|(?-i:\b(GRANT|REVOKE)\s+[A-Z, ]+\s+ON\b)`)

// TestNoRuntimeDDL is the ratchet behind removing ensureSchema: read-api runs as
// the least-privilege readapi_ro (no CREATE, owns nothing), so any DDL in a
// string literal of a non-test Go file in this module is a boot/runtime
// "permission denied" waiting to happen. Schema changes go in db/migrations.
func TestNoRuntimeDDL(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	err = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		f, perr := parser.ParseFile(fset, path, nil, 0)
		if perr != nil {
			return perr
		}
		ast.Inspect(f, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			s, uerr := strconv.Unquote(lit.Value)
			if uerr != nil {
				return true
			}
			if m := ddl.FindString(s); m != "" {
				t.Errorf("%s: string literal contains DDL %q — move it to a db/migrations directory", fset.Position(lit.Pos()), m)
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
