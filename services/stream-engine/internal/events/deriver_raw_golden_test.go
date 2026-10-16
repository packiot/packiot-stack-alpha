//go:build golden

// Golden fixture for ADR-0063 B4: the deriver's state stream read from equipment_values
// directly produces EXACTLY the transitions — same (id_equipment, ts_event) keys, same
// status, ts_end and duration — that the old CTE produced from a real-time
// ca_discrete_changes_1s cagg shaped like production's (1-second buckets grouped by the
// categorical columns, all-NULL rows excluded). The fixture has fractional-second
// timestamps (truncation), NULL-state rows that carry another column (the old cagg kept
// them, the new stream drops them) and rows straddling the 25-hour bound.
//
//	DATABASE_URL=postgres://postgres:golden@localhost:5432/golden?sslmode=disable \
//	go test -tags golden -run GoldenDeriverRawEqualsCagg -v ./internal/events/
package events

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// legacyTransitionsCTE is the stream CTE as it was until ADR-0063 B4 (frozen here as the oracle).
const legacyTransitionsCTE = `
WITH stream AS (
    SELECT ca.ts_value AS ts_event, ca.id_equipment, ca.id_enterprise, ca.state,
           count(ca.state) OVER (PARTITION BY ca.id_equipment ORDER BY ca.ts_value) AS grp
      FROM %[3]s.ca_discrete_changes_1s ca
      JOIN %[2]s.equipments e ON e.id_equipment = ca.id_equipment
     WHERE ca.ts_value > now() - interval '25 hours'
       AND ((e.status_type = 4 AND e.tp_equipment > 0)
            OR (e.id_enterprise = ANY($3) AND e.tp_equipment = 1))
       AND NOT (e.id_area = ANY($1)) AND NOT (e.id_enterprise = ANY($2))
), filled AS (`

func TestGoldenDeriverRawEqualsCagg(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	pc, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	const s = "gdr"
	for _, q := range []string{
		`CREATE EXTENSION IF NOT EXISTS timescaledb`,
		`DROP SCHEMA IF EXISTS ` + s + ` CASCADE`,
		`CREATE SCHEMA ` + s,
		`CREATE TABLE ` + s + `.equipments (id_equipment int PRIMARY KEY, id_area int, id_enterprise int, tp_equipment int, status_type int)`,
		`INSERT INTO ` + s + `.equipments VALUES (1,10,3,1,4),(2,10,3,1,4),(3,10,3,3,4),(4,10,8,1,0),(5,99,3,1,4),(6,10,3,1,0)`,
		`CREATE TABLE ` + s + `.equipment_values (ts_value timestamptz NOT NULL, id_equipment int, id_enterprise int, state int, mode int)`,
		`SELECT create_hypertable('` + s + `.equipment_values', 'ts_value', chunk_time_interval => interval '4 hours')`,
		// a sample every 20 s (+0.4 s: truncation matters) for 26 h; runs of states; some
		// samples carry no state but a mode (kept by the old cagg, dropped by the new stream);
		// a few carry neither (excluded by both).
		`INSERT INTO ` + s + `.equipment_values
		   SELECT m + interval '400 milliseconds', e, CASE WHEN e = 4 THEN 8 ELSE 3 END,
		          CASE WHEN (extract(epoch FROM m)::bigint / 20 + e) % 13 = 0 THEN NULL
		               ELSE (ARRAY[6, 6, 6, 5, 6, 10, 6, 11])[1 + ((extract(epoch FROM m)::bigint / (240 + 60 * e)) % 8)::int] END,
		          CASE WHEN (extract(epoch FROM m)::bigint / 20 + e) % 29 = 0 THEN NULL ELSE 1 END
		     FROM generate_series(1, 6) e,
		          generate_series(date_trunc('minute', now()) - interval '26 hours', now() - interval '5 seconds', interval '20 seconds') m`,
		// the production cagg's shape: 1-s buckets grouped by the categorical columns, all-NULL rows out
		`CREATE MATERIALIZED VIEW ` + s + `.ca_discrete_changes_1s
		   WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
		 SELECT time_bucket('1 second', ts_value) AS ts_value, id_equipment, id_enterprise, state, mode
		   FROM ` + s + `.equipment_values
		  WHERE NOT (state IS NULL AND mode IS NULL)
		  GROUP BY 1, 2, 3, 4, 5 WITH NO DATA`,
		`CALL refresh_continuous_aggregate('` + s + `.ca_discrete_changes_1s', NULL, date_trunc('hour', now()) - interval '2 hours')`,
		`ANALYZE ` + s + `.equipment_values`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("setup %q: %v", q[:min(len(q), 80)], err)
		}
	}
	legacy := strings.Replace(transitionsCTE, transitionsCTE[:strings.Index(transitionsCTE, "), filled AS (")+len("), filled AS (")],
		legacyTransitionsCTE, 1)
	if !strings.Contains(legacy, "ca_discrete_changes_1s") || strings.Contains(transitionsCTE, "ca_discrete_changes_1s") {
		t.Fatal("fixture premise: the legacy CTE reads the cagg and the current one does not")
	}
	args := []any{[]int{99}, []int{}, []int{8}}
	for _, c := range []struct{ name, tail string }{
		{"trans", " SELECT concat_ws('|', id_equipment, ts_event, status, id_enterprise) FROM trans ORDER BY id_equipment, ts_event"},
		{"final", " SELECT concat_ws('|', id_equipment, ts_event, ts_end, status, id_enterprise) FROM final ORDER BY id_equipment, ts_event"},
	} {
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		// both reads in one transaction: one now() for the oracle and the new stream
		q := func(cte string) []string {
			rows, err := tx.Query(ctx, fmt.Sprintf(cte, s, s, s)+c.tail, args...)
			if err != nil {
				t.Fatalf("%s: %v", c.name, err)
			}
			out, err := pgx.CollectRows(rows, pgx.RowTo[string])
			if err != nil {
				t.Fatal(err)
			}
			return out
		}
		want, got := q(legacy), q(transitionsCTE)
		_ = tx.Rollback(ctx)
		if len(want) == 0 {
			t.Fatalf("%s: the fixture exercises nothing", c.name)
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: raw stream differs from the cagg stream (%d vs %d rows)", c.name, len(got), len(want))
			for i := range want {
				if i >= len(got) || got[i] != want[i] {
					g := "<none>"
					if i < len(got) {
						g = got[i]
					}
					t.Errorf(" first difference at %d:\n got  %s\n want %s", i, g, want[i])
					break
				}
			}
		} else {
			t.Logf("%s: %d identical rows", c.name, len(want))
		}
	}
}
