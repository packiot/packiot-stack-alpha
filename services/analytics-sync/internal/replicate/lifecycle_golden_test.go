//go:build golden

// DB-backed golden test for the PO lifecycle replay (handlers.go) — the CPACK
// twin audit of 2026-09-29. Each scenario is a real legacy user_logs sequence
// (payload shapes copied from packiot40), replayed through the handlers against
// an ephemeral Postgres that carries the twin's constraints (running-PO unique
// index, ts_start<=ts_end check, per-equipment runtime exclusion).
//
// Run: DATABASE_URL=postgres://... go test -tags golden -run GoldenLifecycle ./internal/replicate/
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

const lifecycleSchema = `
	CREATE EXTENSION IF NOT EXISTS btree_gist;
	DROP SCHEMA IF EXISTS core CASCADE;
	DROP SCHEMA IF EXISTS gold CASCADE;
	CREATE SCHEMA core;
	CREATE SCHEMA gold;
	CREATE TABLE core.production_orders (
	    id_production_order bigserial PRIMARY KEY,
	    id_enterprise int, id_site int, id_area int, id_equipment int, id_order bigint,
	    status int, ts_start timestamptz, ts_end timestamptz,
	    production_programmed bigint, production_ordered bigint,
	    production_real bigint, production_final bigint,
	    nm_production_order text, txt_production_order_notes text,
	    recalc_needed boolean DEFAULT false,
	    gross_production double precision, net_production double precision,
	    last_update timestamptz,
	    UNIQUE (id_enterprise, id_order),
	    CONSTRAINT production_orders_ts_start_ts_end CHECK (ts_start <= ts_end)
	);
	CREATE UNIQUE INDEX po_one_running_per_equipment ON core.production_orders (id_equipment) WHERE status = 2;
	CREATE TABLE gold.production_orders_runtime (
	    id_production_order_runtime bigserial PRIMARY KEY,
	    id_production_order bigint NOT NULL, id_equipment int NOT NULL,
	    runtime_timerange tstzrange NOT NULL, recalc_needed boolean,
	    last_update timestamptz DEFAULT now(),
	    EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)
	);
	-- the LEGACY side (resolveLegacyOrder reads it unqualified)
	DROP TABLE IF EXISTS public.production_orders;
	CREATE TABLE public.production_orders (id_production_order bigint PRIMARY KEY, id_order bigint, id_enterprise int);
	INSERT INTO public.production_orders VALUES
	    (1666485, 894700, 1), (1667522, 894815, 1), (1674040, 894841, 1),      -- FLEXO
	    (1707600, 896947, 1), (1707677, 896974, 1), (1707700, 897295, 1),      -- SLEEVE2
	    (1676210, 895801, 1), (1689140, 895874, 1), (1688703, 895870, 1),      -- L8 / L10
	    (1701755, 896879, 1), (1701756, 896880, 1);                            -- BREYER2`

type lcFixture struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	r    *Resolver
	log  *slog.Logger
	id   int64
}

func newLifecycleFixture(t *testing.T) *lcFixture {
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
	if _, err := pool.Exec(ctx, lifecycleSchema); err != nil {
		t.Fatalf("schema: %v", err)
	}
	r := &Resolver{srcEnterprise: 1, dstEnterprise: 3, equip: map[int]StagingEquip{
		556: {IDEquipment: 103, IDSite: 6, IDArea: 10, IDEnterprise: 3}, // FLEXO
		822: {IDEquipment: 106, IDSite: 6, IDArea: 10, IDEnterprise: 3}, // SLEEVE2
		218: {IDEquipment: 51, IDSite: 6, IDArea: 10, IDEnterprise: 3},  // L8
		563: {IDEquipment: 52, IDSite: 6, IDArea: 10, IDEnterprise: 3},  // L10
		100: {IDEquipment: 99, IDSite: 6, IDArea: 10, IDEnterprise: 3},  // BREYER2
	}}
	return &lcFixture{t: t, ctx: ctx, pool: pool, r: r, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func (f *lcFixture) run(h Handler, category, payload string, tsLog time.Time) {
	f.t.Helper()
	f.id++
	u := &UserLog{ID: f.id, Category: category, Payload: []byte(payload), TsLog: tsLog}
	if err := h(f.ctx, f.pool, f.pool, f.r, u); err != nil && err != ErrSkip {
		f.t.Fatalf("%s #%d: %v", category, f.id, err)
	}
}

type lcPO struct {
	status     int
	start, end *time.Time
	equipment  int
	windows    []string
}

func (f *lcFixture) po(idOrder int64) lcPO {
	f.t.Helper()
	var p lcPO
	if err := f.pool.QueryRow(f.ctx, `SELECT status, ts_start, ts_end, id_equipment FROM core.production_orders WHERE id_enterprise = 3 AND id_order = $1`, idOrder).
		Scan(&p.status, &p.start, &p.end, &p.equipment); err != nil {
		f.t.Fatalf("PO %d: %v", idOrder, err)
	}
	rows, err := f.pool.Query(f.ctx, `SELECT r.id_equipment::text || ':' || to_char(lower(r.runtime_timerange) AT TIME ZONE 'UTC', 'HH24:MI') || '-' ||
	        COALESCE(to_char(upper(r.runtime_timerange) AT TIME ZONE 'UTC', 'HH24:MI'), 'open')
	   FROM gold.production_orders_runtime r JOIN core.production_orders p USING (id_production_order)
	  WHERE p.id_enterprise = 3 AND p.id_order = $1 ORDER BY lower(r.runtime_timerange)`, idOrder)
	if err != nil {
		f.t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var w string
		if err := rows.Scan(&w); err != nil {
			f.t.Fatal(err)
		}
		p.windows = append(p.windows, w)
	}
	return p
}

func ts(hhmm string) time.Time {
	t, _ := time.Parse("2006-01-02 15:04", "2026-09-05 "+hhmm)
	return t
}

func eqWindows(a []string, b ...string) bool {
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

func same(t *time.Time, want time.Time) bool { return t != nil && t.Equal(want) }

// FLEXO 894815 / 896297: created, PAUSED (the next PO starts), RESUMED by an
// order-changed with shouldCreatePo=false, finished. Then the pause is replayed
// again, as the DLQ retrier did on 09-20 after the overlap fix.
func TestGoldenLifecyclePauseResumeFinishAndLatePauseReplay(t *testing.T) {
	f := newLifecycleFixture(t)
	oc := OrderChanged(f.log)
	create := `{"idOrder":"894815","stopType":"finish","timestamp":"2026-09-05T08:00:00Z","idEquipment":556,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"894815","oldIdProductionOrder":1666485}`
	pause := `{"idOrder":"894841","stopType":"pause","timestamp":"2026-09-05T10:00:00Z","idEquipment":556,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"894841","oldIdProductionOrder":1667522}`
	resume := `{"idOrder":894815,"stopType":"finish","timestamp":"2026-09-05T12:00:00Z","idEquipment":556,"equipmentSetup":[],"shouldCreatePo":false,"shouldOpenNewPo":true,"idProductionOrder":1667522,"oldIdProductionOrder":1674040}`
	finish := `{"idOrder":"","stopType":"finish","timestamp":"2026-09-05T14:00:00Z","idEquipment":556,"equipmentSetup":[],"shouldCreatePo":null,"shouldOpenNewPo":false,"idProductionOrder":"","oldIdProductionOrder":1667522,"productionOrderQuantity":""}`
	f.run(oc, "order-changed", create, ts("08:01"))
	f.run(oc, "order-changed", pause, ts("10:01"))
	f.run(oc, "order-changed", resume, ts("12:01"))
	f.run(oc, "order-changed", finish, ts("14:01"))
	f.run(oc, "order-changed", pause, ts("14:05")) // late replay of the pause

	p := f.po(894815)
	if p.status != 3 || !same(p.start, ts("08:00")) || !same(p.end, ts("14:00")) {
		t.Errorf("894815 = status %d start %v end %v, want 3 08:00-14:00 (a late pause replay must not roll the finish back)", p.status, p.start, p.end)
	}
	if !eqWindows(p.windows, "103:08:00-10:00", "103:12:00-14:00") {
		t.Errorf("894815 windows = %v, want the run AND the resumed run", p.windows)
	}
	q := f.po(894841)
	if q.status != 3 || !eqWindows(q.windows, "103:10:00-12:00") {
		t.Errorf("894841 = status %d windows %v, want 3 [10:00-12:00)", q.status, q.windows)
	}
}

// SLEEVE2 896974: a PO is started with a mistyped number (896947), the right PO is
// created and REPLACES it on the running runtime, then it is finished normally.
func TestGoldenLifecycleOrderReplacedTakesTheRunningRuntime(t *testing.T) {
	f := newLifecycleFixture(t)
	oc := OrderChanged(f.log)
	f.run(oc, "order-changed", `{"idOrder":"896947","stopType":"finish","timestamp":"2026-09-05T08:00:00Z","idEquipment":822,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"896947","oldIdProductionOrder":1666485}`, ts("08:01"))
	f.run(OrderCreated(f.log), "order-created", `{"idArea":60,"idSite":1,"idOrder":"896974","idEquipment":822,"idEnterprise":1,"productionOrderQuantity":"200000"}`, ts("10:40"))
	f.run(OrderReplaced(f.log), "order-replaced", `{"idEquipment":822,"idEnterprise":1,"equipmentSetup":[{"id":823,"position":1}],"unitMultiplier":1,"idProductionOrder":1707677}`, ts("10:40"))
	f.run(oc, "order-changed", `{"idOrder":"897295","stopType":"finish","timestamp":"2026-09-05T15:00:00Z","idEquipment":822,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"897295","oldIdProductionOrder":1707677}`, ts("15:01"))
	// a late replay of the replace (DLQ retry) must be a no-op
	f.run(OrderReplaced(f.log), "order-replaced", `{"idEquipment":822,"idProductionOrder":1707677}`, ts("10:40"))

	p := f.po(896974)
	if p.status != 3 || !same(p.start, ts("08:00")) || !same(p.end, ts("15:00")) || !eqWindows(p.windows, "106:08:00-15:00") {
		t.Errorf("896974 = status %d start %v end %v windows %v, want 3 08:00-15:00 owning the runtime", p.status, p.start, p.end, p.windows)
	}
	g := f.po(896947)
	if g.status != 1 || g.start != nil || g.end != nil || len(g.windows) != 0 {
		t.Errorf("ghost 896947 = status %d start %v end %v windows %v, want available (1) with nothing left", g.status, g.start, g.end, g.windows)
	}
	n := f.po(897295)
	if n.status != 2 || !eqWindows(n.windows, "106:15:00-open") {
		t.Errorf("897295 = status %d windows %v, want running from 15:00", n.status, n.windows)
	}
}

// L8/L10 895874: created on L8, the operator hands the running runtime back to the
// previous PO (order-replaced), then creates 895874 on L10 (a retro timestamp).
func TestGoldenLifecycleReplacedBackThenStartedOnAnotherLine(t *testing.T) {
	f := newLifecycleFixture(t)
	oc := OrderChanged(f.log)
	f.run(OrderCreatedStarted(f.log), "order-created-started", `{"idOrder":895801,"timestamp":"2026-09-05T07:00:00Z","idEquipment":218,"productionOrderQuantity":1000}`, ts("07:01"))
	f.run(oc, "order-changed", `{"idOrder":"895874","stopType":"finish","timestamp":"2026-09-05T08:00:00Z","idEquipment":218,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"895874","oldIdProductionOrder":1676210}`, ts("08:01"))
	f.run(OrderRecalc(f.log), "order-status-changed", `{"idEquipment":218,"idProductionOrder":1676210}`, ts("09:39"))
	f.run(OrderReplaced(f.log), "order-replaced", `{"idEquipment":218,"idEnterprise":1,"equipmentSetup":[],"unitMultiplier":1,"idProductionOrder":1676210}`, ts("09:40"))
	f.run(oc, "order-changed", `{"idOrder":"895874","stopType":"finish","timestamp":"2026-09-05T09:06:00Z","idEquipment":563,"shouldCreatePo":true,"shouldOpenNewPo":true,"idProductionOrder":"895874","oldIdProductionOrder":1688703}`, ts("09:44"))

	p := f.po(895874)
	if p.equipment != 52 || p.status != 2 || !same(p.start, ts("09:06")) || !eqWindows(p.windows, "52:09:06-open") {
		t.Errorf("895874 = eq %d status %d start %v windows %v, want L10 (52), running from 09:06", p.equipment, p.status, p.start, p.windows)
	}
	o := f.po(895801)
	if o.status != 2 || !eqWindows(o.windows, "51:07:00-08:00", "51:08:00-open") {
		t.Errorf("895801 = status %d windows %v, want running again on L8 with the handed-back runtime", o.status, o.windows)
	}
}

// BREYER2 896880 (and 896933/896862/896488…): the next PO is a PRE-EXISTING
// (ERP-planned, status 1) PO started by order-changed shouldCreatePo=false.
func TestGoldenLifecycleStartsPreExistingPO(t *testing.T) {
	f := newLifecycleFixture(t)
	oc := OrderChanged(f.log)
	f.run(OrderCreated(f.log), "order-created", `{"idOrder":"896879","idEquipment":100,"productionOrderQuantity":"45000"}`, ts("06:00"))
	f.run(OrderCreated(f.log), "order-created", `{"idOrder":"896880","idEquipment":100,"productionOrderQuantity":"45000"}`, ts("06:00"))
	f.run(OrderStarted(f.log), "order-started", `{"timestamp":"2026-09-05T07:00:00Z","idEquipment":100,"idProductionOrder":1701755}`, ts("07:01"))
	f.run(oc, "order-changed", `{"idOrder":896880,"stopType":"finish","timestamp":"2026-09-05T09:00:00Z","idEquipment":100,"equipmentSetup":[],"shouldCreatePo":false,"shouldOpenNewPo":true,"idProductionOrder":1701756,"oldIdProductionOrder":1701755}`, ts("09:01"))
	f.run(oc, "order-changed", `{"idOrder":"","stopType":"finish","timestamp":"2026-09-05T11:00:00Z","idEquipment":100,"shouldCreatePo":null,"shouldOpenNewPo":false,"idProductionOrder":"","oldIdProductionOrder":1701756}`, ts("11:01"))

	p := f.po(896880)
	if p.status != 3 || !same(p.start, ts("09:00")) || !same(p.end, ts("11:00")) || !eqWindows(p.windows, "99:09:00-11:00") {
		t.Errorf("896880 = status %d start %v end %v windows %v, want 3 09:00-11:00 with its runtime", p.status, p.start, p.end, p.windows)
	}
	q := f.po(896879)
	if q.status != 3 || !same(q.end, ts("09:00")) || !eqWindows(q.windows, "99:07:00-09:00") {
		t.Errorf("896879 = status %d end %v windows %v, want 3 ending 09:00", q.status, q.end, q.windows)
	}
}

// PO 7627570 (L5): a PO superseded because another opened on its equipment ended
// as "status 3, ts_end NULL".
func TestGoldenLifecycleSupersededPOGetsAnEnd(t *testing.T) {
	f := newLifecycleFixture(t)
	f.run(OrderCreatedStarted(f.log), "order-created-started", `{"idOrder":895801,"timestamp":"2026-09-05T07:00:00Z","idEquipment":218,"productionOrderQuantity":1000}`, ts("07:01"))
	f.run(OrderCreatedStarted(f.log), "order-created-started", `{"idOrder":895870,"timestamp":"2026-09-05T09:30:00Z","idEquipment":218,"productionOrderQuantity":1000}`, ts("09:31"))
	p := f.po(895801)
	if p.status != 3 || !same(p.end, ts("09:30")) {
		t.Errorf("superseded 895801 = status %d end %v, want 3 ending 09:30", p.status, p.end)
	}
}

// Reconciler backstop (reconcile.go) for twins the replay already got wrong: a
// PAUSED twin that legacy finished later is finished (FLEXO 894815: legacy 3 /
// 08-09, twin 4 / 07-29), a NULL ts_start is filled, and neither statement ever
// moves an end backwards.
func TestGoldenLifecycleReconcileFinishesPausedAndFillsStart(t *testing.T) {
	f := newLifecycleFixture(t)
	if _, err := f.pool.Exec(f.ctx, `INSERT INTO core.production_orders (id_enterprise, id_equipment, id_order, status, ts_start, ts_end)
		VALUES (3, 103, 894815, 4, '2026-09-05 08:00Z', '2026-09-05 10:00Z'),
		       (3, 106, 896974, 3, NULL, '2026-09-05 15:00Z'),
		       (3, 51, 895801, 3, '2026-09-05 07:00Z', '2026-09-05 12:00Z')`); err != nil {
		t.Fatal(err)
	}
	exec := func(sql string, args ...any) int64 {
		ct, err := f.pool.Exec(f.ctx, sql, args...)
		if err != nil {
			t.Fatal(err)
		}
		return ct.RowsAffected()
	}
	if n := exec(sqlReconcileFinishPO, 3, ts("14:00"), nil, 3, int64(894815)); n != 1 {
		t.Errorf("paused twin finished by legacy later: %d rows, want 1", n)
	}
	if n := exec(sqlReconcileFillStart, ts("08:00"), 3, int64(896974)); n != 1 {
		t.Errorf("NULL ts_start fill: %d rows, want 1", n)
	}
	// legacy says an EARLIER end than the twin knows: never move it backwards
	if n := exec(sqlReconcileFinishPO, 3, ts("11:00"), nil, 3, int64(895801)); n != 0 {
		t.Errorf("finish moved an end backwards: %d rows", n)
	}
	if p := f.po(894815); p.status != 3 || !same(p.end, ts("14:00")) {
		t.Errorf("894815 = status %d end %v, want 3 / 14:00", p.status, p.end)
	}
	if p := f.po(896974); !same(p.start, ts("08:00")) {
		t.Errorf("896974 start = %v, want 08:00", p.start)
	}
}
