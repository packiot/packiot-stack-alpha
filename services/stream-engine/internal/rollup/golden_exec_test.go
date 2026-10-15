//go:build golden

package rollup

import (
	"context"
	"regexp"
	"strconv"

	"github.com/jackc/pgx/v5"
)

var goldenBindParam = regexp.MustCompile(`\$([0-9]+)\b`)

// goldenExec runs one parity statement the way the engine does: statements without
// bind params go over the simple protocol with no arguments (several are
// multi-statement read/apply strings — ADR-0063 A2 — which a prepared statement
// rejects, aborting the transaction), and a parameterized statement gets the
// argument list whose length matches its highest $N.
func goldenExec(ctx context.Context, tx pgx.Tx, sql string, argsByCount map[int][]any) error {
	n := 0
	for _, m := range goldenBindParam.FindAllStringSubmatch(sql, -1) {
		if k, _ := strconv.Atoi(m[1]); k > n {
			n = k
		}
	}
	if n == 0 {
		_, err := tx.Exec(ctx, sql)
		return err
	}
	_, err := tx.Exec(ctx, sql, argsByCount[n]...)
	return err
}
