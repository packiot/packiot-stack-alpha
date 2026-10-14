//go:build golden

// End-to-end golden test for the PO reconciler's convergence on legacy
// (reconcile_converge.go, 2026-10-09). One full runOnce pass (twice: convergence is
// allowed to take a second pass when a neighbour must converge first) against an
// ephemeral Postgres holding BOTH sides: the twin (core/gold, the lifecycle schema)
// and a "legacy" schema read through a second pool whose search_path is legacy —
// exactly the unqualified SQL the reconciler sends to packiot40.
//
// Each PO is a real CPACK drift case from the 10-09 30-day compare (ent 1 vs ent 3),
// re-based on now() so the 14-day window logic holds whenever the test runs.
//
// Run: DATABASE_URL=postgres://... go test -tags golden -run GoldenReconcileConverge ./internal/replicate/
package replicate

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const legacyConvergeSchema = `
	DROP SCHEMA IF EXISTS legacy CASCADE;
	CREATE SCHEMA legacy;
	CREATE TABLE legacy.production_orders (
	    id_production_order bigint PRIMARY KEY, id_enterprise int, id_order bigint, id_equipment int,
	    status int, ts_start timestamptz, ts_end timestamptz,
	    production_real bigint, production_final bigint, production_programmed bigint, production_ordered bigint,
	    id_order_text text, txt_production_order_notes text,
	    ts_creation timestamptz, last_update timestamptz);
	CREATE TABLE legacy.production_orders_runtime (
	    id_production_order bigint, id_equipment int, runtime_timerange tstzrange);`

func TestGoldenReconcileConvergeOnLegacy(t *testing.T) {
	f := newLifecycleFixture(t)
	if _, err := f.pool.Exec(f.ctx, legacyConvergeSchema); err != nil {
		t.Fatal(err)
	}
	cfg := f.pool.Config().Copy()
	cfg.ConnConfig.RuntimeParams["search_path"] = "legacy"
	legacy, err := pgxpool.NewWithConfig(f.ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(legacy.Close)
	f.r.equip[75] = StagingEquip{IDEquipment: 48, IDSite: 6, IDArea: 10, IDEnterprise: 3}  // L3
	f.r.equip[90] = StagingEquip{IDEquipment: 50, IDSite: 6, IDArea: 10, IDEnterprise: 3}  // L6
	f.r.equip[337] = StagingEquip{IDEquipment: 94, IDSite: 6, IDArea: 10, IDEnterprise: 3} // PTH40-03

	b := time.Now().UTC().Truncate(time.Hour).Add(-48 * time.Hour)
	h := func(n float64) time.Time { return b.Add(time.Duration(n * float64(time.Hour))) }
	old := b.AddDate(0, 0, -50)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := f.pool.Exec(f.ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	// ── legacy (ent 1): the truth ──
	lpo := `INSERT INTO legacy.production_orders (id_production_order, id_enterprise, id_order, id_equipment, status, ts_start, ts_end, ts_creation, last_update)
	        VALUES ($1, 1, $2, $3, $4, $5, $6, $7, now())`
	lrt := `INSERT INTO legacy.production_orders_runtime VALUES ($1, $2, tstzrange($3, $4))`
	exec(lpo, 1713923, 896802, 75, 3, h(0), h(10), h(0)) // replaced in, ran 0→10
	exec(lrt, 1713923, 75, h(0), h(10))
	exec(lpo, 1713599, 896799, 75, 3, h(10), h(18), h(0)) // re-started at 10 (legacy moved ts_start)
	exec(lrt, 1713599, 75, h(10), h(18))
	exec(lpo, 1720168, 897794, 75, 3, h(18), h(30), h(0)) // end corrected by order-time-changed
	exec(lrt, 1720168, 75, h(18), h(30))
	exec(lpo, 1715081, 897519, 75, 1, nil, nil, h(0)) // put back to available, its 2-min row kept
	exec(lrt, 1715081, 75, h(34), h(35))
	exec(lpo, 1616053, 891336, 90, 1, old, nil, old) // available; ran only on the twin
	exec(lpo, 1720200, 897867, 90, 3, h(25), h(40), h(0))
	exec(lrt, 1720200, 90, h(25), h(40))
	exec(lpo, 1681123, 895499, 337, 3, old, old.Add(4*time.Hour), old) // finished 50 days ago
	exec(`UPDATE legacy.production_orders SET last_update = $1 WHERE id_order = 895499`, old)
	exec(lrt, 1681123, 337, old, old.Add(4*time.Hour))
	exec(lpo, 1720300, 897800, 75, 1, nil, nil, h(1)) // ERP-created available PO, no user_log

	// ── twin (ent 3): what the replay left ──
	tpo := `INSERT INTO core.production_orders (id_enterprise, id_equipment, id_order, status, ts_start, ts_end, net_production)
	        VALUES (3, $1, $2, $3, $4, $5, 100)`
	trt := `INSERT INTO gold.production_orders_runtime (id_production_order, id_equipment, runtime_timerange)
	        SELECT id_production_order, $2, tstzrange($3, $4) FROM core.production_orders WHERE id_enterprise = 3 AND id_order = $1`
	exec(tpo, 48, 896802, 3, h(0), h(10))
	exec(trt, 896802, 48, h(0), h(10))
	exec(tpo, 48, 896799, 3, h(0), h(18)) // kept the FIRST start → window blocked
	exec(tpo, 48, 897794, 3, h(18), h(34))
	exec(trt, 897794, 48, h(18), h(34))
	exec(tpo, 48, 897519, 3, h(34), h(35)) // finished on the twin, available in legacy
	exec(tpo, 50, 891336, 3, old, h(40))
	exec(trt, 891336, 50, h(30), h(40)) // the twin-only run…
	exec(tpo, 50, 897867, 3, h(25), h(40))
	exec(trt, 897867, 50, h(25), h(30)) // …cut this one short
	exec(tpo, 94, 895499, 3, old, h(5)) // zombie closed by the next start, weeks later
	exec(trt, 895499, 94, old, old.Add(4*time.Hour))
	exec(tpo, 49, 333400100, 3, h(1), h(20)) // twin-only PO: never touched
	exec(trt, 333400100, 49, h(1), h(20))

	rc := NewPOReconciler(legacy, f.pool, f.r, &Config{SrcEnterprise: 1, DstEnterprise: 3, ReconcileWindowDays: 14}, nil, f.log)
	rc.runOnce(f.ctx)
	rc.runOnce(f.ctx) // a blocked neighbour converges on the next pass

	hm := func(x time.Time) string { return x.UTC().Format("15:04") }
	type want struct {
		status     int
		start, end *time.Time
		windows    []string
	}
	tp := func(x time.Time) *time.Time { return &x }
	w := func(eq string, lo, hi time.Time) string { return eq + ":" + hm(lo) + "-" + hm(hi) }
	cases := map[int64]want{
		896802:    {3, tp(h(0)), tp(h(10)), []string{w("48", h(0), h(10))}},
		896799:    {3, tp(h(10)), tp(h(18)), []string{w("48", h(10), h(18))}},
		897794:    {3, tp(h(18)), tp(h(30)), []string{w("48", h(18), h(30))}},
		897519:    {1, nil, nil, nil},
		891336:    {1, tp(old), nil, nil},
		897867:    {3, tp(h(25)), tp(h(40)), []string{w("50", h(25), h(40))}},
		895499:    {3, tp(old), tp(old.Add(4 * time.Hour)), []string{w("94", old, old.Add(4*time.Hour))}},
		897800:    {1, nil, nil, nil},
		333400100: {3, tp(h(1)), tp(h(20)), []string{w("49", h(1), h(20))}},
	}
	tsEq := func(a, b *time.Time) bool {
		if a == nil || b == nil {
			return a == nil && b == nil
		}
		return a.Equal(*b)
	}
	for id, c := range cases {
		p := f.po(id)
		if p.status != c.status || !tsEq(p.start, c.start) || !tsEq(p.end, c.end) || !eqWindows(p.windows, c.windows...) {
			t.Errorf("%d: status %d start %v end %v windows %v — want %d %v %v %v",
				id, p.status, p.start, p.end, p.windows, c.status, c.start, c.end, c.windows)
		}
	}
	var created time.Time
	if err := f.pool.QueryRow(f.ctx, `SELECT ts_creation FROM core.production_orders WHERE id_enterprise = 3 AND id_order = 897800`).Scan(&created); err != nil || !created.Equal(h(1)) {
		t.Errorf("897800 ts_creation = %v (%v), want legacy's %v", created, err, h(1))
	}
	var net *float64
	if err := f.pool.QueryRow(f.ctx, `SELECT net_production FROM core.production_orders WHERE id_enterprise = 3 AND id_order = 891336`).Scan(&net); err != nil || net != nil {
		t.Errorf("reverted 891336 net = %v (%v), want NULL", net, err)
	}
}
