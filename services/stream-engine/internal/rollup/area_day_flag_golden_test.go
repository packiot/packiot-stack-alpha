//go:build golden

package rollup

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// TestGoldenAreaDayFlagChangeDriven — the equipment→area DAY flag cascade fires only
// when a line day was recomputed AFTER its area day. It used to re-flag every area day
// of the last month on every tick (~400 rows recomputed per minute, measured 2026-10-01).
func TestGoldenAreaDayFlagChangeDriven(t *testing.T) {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = "golden, public"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	for _, s := range []string{goldenSchema, cascadeSchema, `
		-- line 33 is the only line of area 2. Day D = 2 days ago: line day computed 2 h ago,
		-- area day computed 1 h ago (AFTER the line) with the line's net → nothing changed.
		INSERT INTO golden.equipment_oee_daily (id_equipment, ts_value, gross, net, available_time, running_time, planned_downtime, ideal_production, computed_at)
		VALUES (33, current_date - 2, 500, 400, 3600, 1800, 0, 1000, now() - interval '2 hours');
		INSERT INTO golden.area_oee_daily (id_area, ts_value, gross, net, available_time, running_time, planned_downtime, ideal_production, computed_at)
		VALUES (2, current_date - 2, 500, 400, 3600, 1800, 0, 1000, now() - interval '1 hour');`} {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("fixture: %v", err)
		}
	}
	d := flows.Dest{Name: "golden", Pool: pool, EvSchema: "golden", RefSchema: "golden", SilverSchema: "golden",
		GoldSchema: "golden", GrainSchema: "golden", ConfigSchema: "golden"}
	areaDay := func() (computed time.Time, net float64) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT computed_at, net FROM golden.area_oee_daily WHERE id_area = 2 AND ts_value = current_date - 2`).Scan(&computed, &net); err != nil {
			t.Fatal(err)
		}
		return
	}
	before, _ := areaDay()
	if err := RunEntityGrains(ctx, d, []int{}); err != nil {
		t.Fatalf("RunEntityGrains: %v", err)
	}
	if after, _ := areaDay(); !after.Equal(before) {
		t.Fatalf("unchanged line day re-flagged its area day (computed_at %v → %v)", before, after)
	}
	// The line day is recomputed (new net) AFTER the area day → the area day must follow.
	if _, err := pool.Exec(ctx, `UPDATE golden.equipment_oee_daily SET net = 450, computed_at = now() WHERE id_equipment = 33 AND ts_value = current_date - 2`); err != nil {
		t.Fatal(err)
	}
	if err := RunEntityGrains(ctx, d, []int{}); err != nil {
		t.Fatalf("RunEntityGrains: %v", err)
	}
	after, net := areaDay()
	if !after.After(before) || net != 450 {
		t.Fatalf("changed line day did not propagate: area computed_at %v (was %v), net %v want 450", after, before, net)
	}
}
