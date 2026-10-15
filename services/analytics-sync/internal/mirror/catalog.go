package mirror

import (
	"context"
	"fmt"
	"sort"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// Column is one catalog column.
type Column struct {
	Name           string
	Generated      bool // GENERATED ALWAYS AS (…) STORED: never written
	IdentityAlways bool // GENERATED ALWAYS AS IDENTITY: insert needs OVERRIDING SYSTEM VALUE, never updated
}

// TableMeta is one table of one side's catalog.
type TableMeta struct {
	Cols      []Column
	PK        []string // primary-key columns in key order; empty = no primary key
	TenantKey string   // first of TenantKeys present, "" = not tenant-scoped
}

// Has reports whether the table has the column.
func (m TableMeta) Has(col string) bool {
	for _, c := range m.Cols {
		if c.Name == col {
			return true
		}
	}
	return false
}

// Catalog maps "schema.table" to its metadata.
type Catalog map[string]TableMeta

// Querier is the subset of pgx used to read a catalog (a pool or a transaction).
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

const catalogSQL = `
SELECT n.nspname || '.' || c.relname, a.attname, a.attgenerated <> '', a.attidentity = 'a',
       coalesce(array_position(pk.conkey, a.attnum), 0)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
 WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
   AND n.nspname IN ('core', 'config', 'identity', 'gold', 'silver', 'bronze', 'serving', 'ops', 'customer_reports')
 ORDER BY 1, a.attnum`

// ReadCatalog reads one side's catalog.
func ReadCatalog(ctx context.Context, q Querier) (Catalog, error) {
	rows, err := q.Query(ctx, catalogSQL)
	if err != nil {
		return nil, fmt.Errorf("read catalog: %w", err)
	}
	defer rows.Close()
	cat := Catalog{}
	pkPos := map[string]map[int]string{}
	for rows.Next() {
		var tbl, col string
		var gen, ident bool
		var pos int
		if err := rows.Scan(&tbl, &col, &gen, &ident, &pos); err != nil {
			return nil, err
		}
		m := cat[tbl]
		m.Cols = append(m.Cols, Column{Name: col, Generated: gen, IdentityAlways: ident})
		cat[tbl] = m
		if pos > 0 {
			if pkPos[tbl] == nil {
				pkPos[tbl] = map[int]string{}
			}
			pkPos[tbl][pos] = col
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for tbl, m := range cat {
		if p := pkPos[tbl]; len(p) > 0 {
			for i := 1; i <= len(p); i++ {
				m.PK = append(m.PK, p[i])
			}
		}
		for _, k := range TenantKeys {
			if m.Has(k) {
				m.TenantKey = k
				break
			}
		}
		cat[tbl] = m
	}
	return cat, nil
}

func itoa(n int) string { return strconv.Itoa(n) }

func sortStrings(s []string) { sort.Strings(s) }
