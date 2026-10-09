//go:build golden

// DB-backed proof for the base (PLC) event reconciler — S2_stale_open_stops,
// 2026-10-09. The legacy and twin tables live in one ephemeral Postgres (legacy
// = public.equipment_events, twin = silver.equipment_events), the pass runs
// against both through the same pool.
//
// Run: DATABASE_URL=postgres://... go test -tags golden -run GoldenBase ./internal/replicate/
package replicate

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const baseSchema = `
	DROP SCHEMA IF EXISTS silver CASCADE;
	CREATE SCHEMA silver;
	CREATE TABLE silver.equipment_events (
	    id_equipment int NOT NULL, ts_event timestamptz NOT NULL, ts_end timestamptz, status int,
	    id_equipment_event bigint NOT NULL, id_enterprise int NOT NULL, duration int,
	    forced_creation_system boolean, last_update timestamptz,
	    UNIQUE (id_equipment, ts_event));
	DROP TABLE IF EXISTS public.equipment_events;
	CREATE TABLE public.equipment_events (
	    id_equipment int NOT NULL, ts_event timestamptz NOT NULL, ts_end timestamptz, status int,
	    id_enterprise int NOT NULL, forced_creation_system boolean NOT NULL DEFAULT false,
	    UNIQUE (id_equipment, ts_event));`

type baseFixture struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	br   *BaseReconciler
}

func newBaseFixture(t *testing.T) *baseFixture {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(ctx, baseSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	r := &Resolver{srcEnterprise: 1, dstEnterprise: 3, equip: map[int]StagingEquip{
		106: {IDEquipment: 83, IDEnterprise: 3}, // CER400
		76:  {IDEquipment: 58, IDEnterprise: 3}, // L3-BREYER
	}}
	cfg := &Config{SrcEnterprise: 1, DstEnterprise: 3, ReplicateBaseEvents: true, ReconcileBaseEventsEnabled: true,
		ReconcileBaseEventsLookbackHours: 72, ReconcileBaseEventsRefreshServing: true}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &baseFixture{t: t, ctx: ctx, pool: pool, br: NewBaseReconciler(pool, pool, r, cfg, nil, log)}
}

func (f *baseFixture) exec(sql string, args ...any) {
	f.t.Helper()
	if _, err := f.pool.Exec(f.ctx, sql, args...); err != nil {
		f.t.Fatalf("%s: %v", sql, err)
	}
}

func (f *baseFixture) twin(eq int) []string {
	f.t.Helper()
	rows, err := f.pool.Query(f.ctx, `SELECT to_char(ts_event AT TIME ZONE 'UTC', 'HH24:MI:SS.MS') || '/' || status
	                                    FROM silver.equipment_events WHERE id_equipment = $1 ORDER BY ts_event`, eq)
	if err != nil {
		f.t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			f.t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func eqStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// The CER400 case: the twin's last event is a STOP (the replay saw it through
// user_logs); legacy has the successor RUN + the next STOP, written without an
// audit row (Pub/Sub path). The pass copies exactly the missing transitions, so
// the stop gets its successor; a second pass changes nothing.
func TestGoldenBaseReconcilerFillsSuccessorsIdempotently(t *testing.T) {
	f := newBaseFixture(t)
	d := time.Now().UTC().Add(-30 * time.Hour).Truncate(time.Hour)
	f.exec(`INSERT INTO silver.equipment_events (id_equipment, ts_event, status, id_equipment_event, id_enterprise, forced_creation_system)
	        VALUES (83, $1, 10, 1, 3, false)`, d)
	f.exec(`INSERT INTO public.equipment_events (id_equipment, ts_event, status, id_enterprise, forced_creation_system) VALUES
	        (106, $1, 10, 1, false), (106, $2, 6, 1, false), (106, $3, 10, 1, false),
	        (106, $4, 10, 1, true),   -- an operator split segment: owned by event-splitted, not copied
	        (999, $2, 6, 1, false)    -- unresolved legacy equipment: skipped`,
		d, d.Add(90*time.Minute), d.Add(150*time.Minute), d.Add(155*time.Minute))
	for i := 0; i < 2; i++ {
		if err := f.br.pass(f.ctx, time.Now().Add(-72*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	h := func(dt time.Duration) string { return d.Add(dt).Format("15:04:05") + ".000" }
	want := []string{h(0) + "/10", h(90*time.Minute) + "/6", h(150*time.Minute) + "/10"}
	if got := f.twin(83); !eqStrings(got, want) {
		t.Fatalf("twin CER400 = %v, want %v", got, want)
	}
	var fcs int
	if err := f.pool.QueryRow(f.ctx, `SELECT count(*) FROM silver.equipment_events WHERE forced_creation_system IS NOT FALSE`).Scan(&fcs); err != nil || fcs != 0 {
		t.Fatalf("copied base events must be forced_creation_system=false (n=%d, err=%v)", fcs, err)
	}
}

// The replay stored a transition with the payload's milliseconds; legacy holds
// the same transition at the whole second. Neither writer may add a second row
// for it — in either order.
func TestGoldenBaseNoDuplicateAcrossMillisecondRounding(t *testing.T) {
	f := newBaseFixture(t)
	d := time.Now().UTC().Add(-5 * time.Hour).Truncate(time.Hour)
	// (a) replay first (ms), reconciler second (whole second)
	f.exec(`INSERT INTO silver.equipment_events (id_equipment, ts_event, status, id_equipment_event, id_enterprise, forced_creation_system)
	        VALUES (58, $1, 6, 1, 3, false)`, d.Add(34*time.Second+507*time.Millisecond))
	f.exec(`INSERT INTO public.equipment_events (id_equipment, ts_event, status, id_enterprise) VALUES (76, $1, 6, 1)`, d.Add(35*time.Second))
	if err := f.br.pass(f.ctx, time.Now().Add(-72*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if got := f.twin(58); len(got) != 1 {
		t.Fatalf("reconciler duplicated a replayed transition: %v", got)
	}
	// (b) reconciler first (whole second), replay second (ms)
	f.exec(`INSERT INTO public.equipment_events (id_equipment, ts_event, status, id_enterprise) VALUES (76, $1, 10, 1)`, d.Add(time.Hour))
	if err := f.br.pass(f.ctx, time.Now().Add(-72*time.Hour)); err != nil {
		t.Fatal(err)
	}
	ms := d.Add(time.Hour - 300*time.Millisecond)
	if _, err := f.pool.Exec(f.ctx, sqlInsertEquipmentEvent, 58, ms, 10, genEventID(ms, 58), 3); err != nil {
		t.Fatal(err)
	}
	if got := f.twin(58); len(got) != 2 {
		t.Fatalf("replay duplicated a reconciled transition: %v", got)
	}
}
