package rollup

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

func historyStagingConfig() HistoryRecompute {
	return HistoryRecompute{
		Dest: flows.Dest{Name: "packiot_analytics", EvSchema: "silver", RefSchema: "core",
			SilverSchema: "silver", GoldSchema: "gold", GrainSchema: "silver", ConfigSchema: "config"},
		CA: CountersAvail{
			Enabled: true, Equipments: []int{68, 69, 70, 71, 72}, IdleTimeoutSec: 300,
			LineLeadEnabled: true, LineLeadEnterprises: []int{3, 5, 2000003},
			AvailFloorEnabled: true, OeeCanonicalAPQ: true, AvailabilityExclusions: true,
		},
		MachineLevelEnterprises: []int{6},
	}
}

// Every engine pass appears in the rendered script, in engine order, so the
// template cannot silently skip a step the live engine runs.
func TestRenderHistoryRecomputeRunsEveryEngineStep(t *testing.T) {
	h := historyStagingConfig()
	sql, err := RenderHistoryRecompute(h)
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, s := range hourBackfillSteps(h.Dest, h.CA, false) {
		want = append(want, "-- hour: "+s.name)
	}
	for _, s := range shiftSteps(h.Dest, h.CA, false) {
		want = append(want, "-- shift: "+s.name)
	}
	for _, s := range daySteps(h.Dest, h.CA) {
		want = append(want, "-- day: "+s.name)
	}
	pos := 0
	for _, w := range want {
		i := strings.Index(sql[pos:], w+"\n")
		if i < 0 {
			t.Fatalf("step %q missing or out of order", w)
		}
		pos += i + len(w)
	}
	for _, must := range []string{"-- shift: line-lead", "-- shift: avail-floor", "-- shift: oee-reconcile", "-- day: oee-reconcile"} {
		if !strings.Contains(sql, must+"\n") {
			t.Errorf("engaged step %q not rendered", must)
		}
	}
}

func TestRenderHistoryRecomputeShape(t *testing.T) {
	sql, err := RenderHistoryRecompute(historyStagingConfig())
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(sql, HistoryFlagMarker+"\n"); n != 1 {
		t.Errorf("flag marker count = %d, want 1", n)
	}
	if !strings.HasSuffix(sql, HistoryEndPlaceholder+";\n") {
		t.Error("script must end with the __END__ placeholder (never a literal COMMIT)")
	}
	if strings.Contains(strings.ReplaceAll(sql, "ON COMMIT DROP", ""), "COMMIT") {
		t.Error("rendered template must not contain COMMIT")
	}
	// hour + shift eligible are bounded to the day; day eligible is not.
	if n := strings.Count(sql, "'"+HistoryFromPlaceholder+"'"); n != 2 {
		t.Errorf("window predicates = %d, want 2 (hour + shift eligible)", n)
	}
	for _, lock := range []string{"'packiot_analytics:runtime-backfill'", "'packiot_analytics:runtime'"} {
		if !strings.Contains(sql, "pg_advisory_xact_lock(hashtextextended("+lock) {
			t.Errorf("missing blocking lock %s", lock)
		}
	}
	if strings.Contains(sql, "pg_try_advisory") {
		t.Error("repair must block on the engine locks, not try them")
	}
	if strings.Contains(sql, "interval '10 days'") && strings.Contains(sql, "now() - interval '10 days'") {
		t.Error("the 10-day backfill horizon leaked through un-widened")
	}
	for _, s := range []string{"interval '75 days'", "interval '82 days'", "ANY('{6}'::int[])", "LIMIT 100000"} {
		if !strings.Contains(sql, s) {
			t.Errorf("expected %q in the rendered script", s)
		}
	}
	if strings.Contains(sql, "decompress_chunk") {
		t.Error("history repair must never call decompress_chunk")
	}
}

func TestRenderHistoryRecomputeHorizonBounds(t *testing.T) {
	for _, d := range []int{HistoryMinHorizonDays - 1, HistoryMaxHorizonDays + 1} {
		h := historyStagingConfig()
		h.HorizonDays = d
		if _, err := RenderHistoryRecompute(h); err == nil {
			t.Errorf("horizon %d accepted, want error", d)
		}
	}
}

// A new engine window that nobody classified must fail the render.
func TestCheckHistoryWindowsRejectsUnknownWindow(t *testing.T) {
	if err := checkHistoryWindows("x >= now() - interval '75 days' AND y >= now() - interval '4 hours'", 75); err == nil {
		t.Error("unknown window accepted")
	}
	if err := checkHistoryWindows("x >= now() - interval '82 days' AND y < now() - interval '65 minutes'", 75); err != nil {
		t.Errorf("known windows rejected: %v", err)
	}
}

func TestInlineBindsRejectsUnknownParam(t *testing.T) {
	if _, err := inlineBinds("a = ANY($1) AND b = ANY($2)", []int{1}); err == nil {
		t.Error("$2 with one arg accepted")
	}
	got, err := inlineBinds("a = ANY($1)", []int{1, 2})
	if err != nil || got != "a = ANY('{1,2}'::int[])" {
		t.Errorf("got %q, %v", got, err)
	}
}
