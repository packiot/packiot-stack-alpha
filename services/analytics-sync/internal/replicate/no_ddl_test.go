package replicate

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

var ddlRE = regexp.MustCompile(`(?i)\b(CREATE|ALTER|DROP)\s+(OR\s+REPLACE\s+)?(TEMP(ORARY)?\s+)?(SCHEMA|TABLE|(UNIQUE\s+)?INDEX|VIEW|MATERIALIZED|FUNCTION|PROCEDURE|ROLE|EXTENSION|TRIGGER|SEQUENCE|POLICY|TYPE)\b|\bTRUNCATE\s+(TABLE\s+)?[a-z_."]|(?-i:\b(GRANT|REVOKE)\s+[A-Z, ]+\s+ON\b)`)

// TestLegacyReplicatorIssuesNoDDL is the ratchet behind moving the ops-table DDL into
// db/migrations/t-legacy-replicator-role: the replicator's DEST login has no CREATE and owns
// nothing, so any DDL in the binary's code path is a "permission denied" at boot (the
// cursor one was fatal; the manual-link one silently disabled the manual-event reconciler).
func TestLegacyReplicatorIssuesNoDDL(t *testing.T) {
	fset := token.NewFileSet()
	for _, dir := range []string{".", "../db", "../../cmd/legacy-replicator"} {
		files, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		if len(files) == 0 {
			t.Fatalf("no Go files in %s (moved? update the ratchet)", dir)
		}
		for _, path := range files {
			if strings.HasSuffix(path, "_test.go") {
				continue
			}
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			f, err := parser.ParseFile(fset, path, src, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(f, func(n ast.Node) bool {
				lit, ok := n.(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					return true
				}
				if s, err := strconv.Unquote(lit.Value); err == nil {
					if m := ddlRE.FindString(s); m != "" {
						t.Errorf("%s: string literal contains DDL %q — it belongs in db/migrations", fset.Position(lit.Pos()), m)
					}
				}
				return true
			})
		}
	}
}
