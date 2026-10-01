//go:build cpac_integration

package events

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// setupLinkSchema: the base schema + the PLC link tables (2026-10-01). Machine
// 1000 (endpoint "E1") produces in the given runs (minute offsets from base);
// the link reports ok every minute from base-60 to now-3 EXCEPT inside
// [islandFrom, islandTo) — islandTo < 0 ⇒ the link never comes back.
func setupLinkSchema(t *testing.T, pool *pgxpool.Pool, base time.Time, runs [][2]int, islandFrom, islandTo int) {
	t.Helper()
	ctx := context.Background()
	setupSchema(t, pool)
	for _, s := range []string{
		`TRUNCATE ` + schema + `.equipment_categorical_1min`,
		`CREATE TABLE ` + schema + `.plc_endpoint_equipment (id_enterprise int, endpoint text, id_equipment bigint)`,
		`CREATE TABLE ` + schema + `.plc_link_minutes (id_enterprise int, endpoint text, ts_minute timestamptz,
			ok_ticks int, fail_ticks int, PRIMARY KEY (id_enterprise, endpoint, ts_minute))`,
		`INSERT INTO ` + schema + `.plc_endpoint_equipment VALUES (999, 'E1', 1000)`,
	} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	for _, r := range runs {
		for i := r[0]; i < r[1]; i++ {
			if _, err := pool.Exec(ctx, `INSERT INTO `+schema+`.equipment_categorical_1min VALUES (1000, $1, 5)`,
				base.Add(time.Duration(i)*time.Minute)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO `+schema+`.plc_link_minutes
		SELECT 999, 'E1', g, 12, 0
		  FROM generate_series($1::timestamptz, date_trunc('minute', now()) - interval '3 minutes', interval '1 minute') g
		 WHERE NOT (g >= $2::timestamptz AND ($3::timestamptz IS NULL OR g < $3::timestamptz))`,
		base.Add(-60*time.Minute), base.Add(time.Duration(islandFrom)*time.Minute), islandEnd(base, islandTo)); err != nil {
		t.Fatal(err)
	}
}

func islandEnd(base time.Time, to int) *time.Time {
	if to < 0 {
		return nil
	}
	e := base.Add(time.Duration(to) * time.Minute)
	return &e
}

var linkCfg = CPACConfig{Enterprises: []int{999}, ThresholdDefSec: 300, TargetTable: "equipment_events_cpac_shadow", LinkHealth: true}

type tr struct {
	off    int // minutes from base
	status int
}

func expectStream(t *testing.T, got []evRow, base time.Time, want []tr) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d rows %+v, want %+v", len(got), got, want)
	}
	for i, w := range want {
		at := base.Add(time.Duration(w.off) * time.Minute)
		if got[i].Status != w.status || !got[i].TsEvent.Equal(at) {
			t.Fatalf("row %d = status %d @ %s, want %d @ %s (all: %+v)", i, got[i].Status,
				got[i].TsEvent.Sub(base), w.status, at.Sub(base), got)
		}
	}
}

func runLink(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	for i := 0; i < 2; i++ { // idempotent: a second pass changes nothing
		if _, _, err := RunOnceCPAC(context.Background(), dest(pool), linkCfg); err != nil {
			t.Fatal(err)
		}
	}
}

// Link healthy through the silence ⇒ the silence IS a stop (unchanged behaviour).
func TestCPACLinkHealthyGapIsStop(t *testing.T) {
	pool := mustPool(t)
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)
	setupLinkSchema(t, pool, base, [][2]int{{0, 10}, {35, 45}}, 100000, 100001)
	runLink(t, pool)
	expectStream(t, dump(t, pool), base, []tr{{0, 6}, {14, 10}, {35, 6}, {49, 10}})
}

// PLC unreachable during the silence, production resumes when it returns ⇒
// NO DATA instead of a stop.
func TestCPACLinkLostGapIsNoData(t *testing.T) {
	pool := mustPool(t)
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)
	setupLinkSchema(t, pool, base, [][2]int{{0, 10}, {35, 45}}, 12, 34)
	runLink(t, pool)
	expectStream(t, dump(t, pool), base, []tr{{0, 6}, {12, NoDataStatus}, {35, 6}, {49, 10}})
}

// Link returns but the machine stays silent ⇒ NO DATA, then a real stop from
// the moment the PLC could be read again.
func TestCPACLinkBackButSilentIsStop(t *testing.T) {
	pool := mustPool(t)
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)
	setupLinkSchema(t, pool, base, [][2]int{{0, 10}}, 12, 34)
	runLink(t, pool)
	expectStream(t, dump(t, pool), base, []tr{{0, 6}, {12, NoDataStatus}, {34, 10}})
}

// Link never returns ⇒ one open NO DATA (no phantom stop — the L58 case).
func TestCPACLinkDeadIsOngoingNoData(t *testing.T) {
	pool := mustPool(t)
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)
	setupLinkSchema(t, pool, base, [][2]int{{0, 10}}, 12, -1)
	runLink(t, pool)
	got := dump(t, pool)
	expectStream(t, got, base, []tr{{0, 6}, {12, NoDataStatus}})
	if got[1].TsEnd != nil {
		t.Fatalf("ongoing no-data must stay open, ts_end=%v", got[1].TsEnd)
	}
}

// A link blip shorter than the stop threshold is ignored (neither stop nor gap).
func TestCPACLinkShortBlipIgnored(t *testing.T) {
	pool := mustPool(t)
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)
	setupLinkSchema(t, pool, base, [][2]int{{0, 10}, {35, 45}}, 20, 23)
	runLink(t, pool)
	expectStream(t, dump(t, pool), base, []tr{{0, 6}, {14, 10}, {35, 6}, {49, 10}})
}
