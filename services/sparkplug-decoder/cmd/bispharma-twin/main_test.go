package main

import (
	"io"
	"log/slog"
	"testing"
	"time"
)

// newTestTwin builds a twin with two lines (L01: gross/net/scrap, L02: gross/net)
// and no MQTT client, so advance() can be exercised in isolation.
func newTestTwin(stopProb float64, minT, maxT int) *twin {
	cfg := config{
		interval:     15 * time.Second,
		ratePerMin:   600,
		scrapRate:    0.03,
		stopProb:     stopProb,
		stopMinTicks: minT,
		stopMaxTicks: maxT,
	}
	metrics := []*member{
		{name: "L01g", line: "L01", kind: kindGross},
		{name: "L01n", line: "L01", kind: kindNet},
		{name: "L01s", line: "L01", kind: kindScrap},
		{name: "L02g", line: "L02", kind: kindGross},
		{name: "L02n", line: "L02", kind: kindNet},
	}
	return &twin{cfg: cfg, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), metrics: metrics}
}

// TestAdvance_StopsFreezeLineTogether proves the stop simulation: over many ticks a
// line both runs and stops; a stopped line freezes ALL its members together (the
// count gap the deriver reads as a downtime); totalizers never go backwards.
// stopProb=0.5 over 80 ticks makes "never stops" astronomically unlikely (0.5^80),
// so this is not flaky in practice.
func TestAdvance_StopsFreezeLineTogether(t *testing.T) {
	tw := newTestTwin(0.5, 2, 4)
	prev := map[string]float64{}
	for _, m := range tw.metrics {
		prev[m.name] = m.val
	}
	sawStop, sawRun := false, false
	for i := 0; i < 80; i++ {
		tw.advance()
		gDelta := tw.metrics[0].val - prev["L01g"] // L01 gross
		nDelta := tw.metrics[1].val - prev["L01n"] // L01 net
		sDelta := tw.metrics[2].val - prev["L01s"] // L01 scrap
		if gDelta == 0 {
			sawStop = true
			if nDelta != 0 || sDelta != 0 {
				t.Fatalf("tick %d: L01 gross frozen but net/scrap advanced (n=%v s=%v) — line did not stop as a unit", i, nDelta, sDelta)
			}
		}
		if gDelta > 0 {
			sawRun = true
		}
		for _, m := range tw.metrics {
			if m.val < prev[m.name] {
				t.Fatalf("tick %d: totalizer %s went backwards (%v < %v)", i, m.name, m.val, prev[m.name])
			}
			prev[m.name] = m.val
		}
	}
	if !sawStop {
		t.Fatal("expected at least one stop (a frozen tick) over 80 ticks at stopProb=0.5")
	}
	if !sawRun {
		t.Fatal("expected at least one running tick")
	}
}

// TestAdvance_NoStopWhenDisabled proves backward compatibility: stopProb=0 keeps the
// pre-existing always-running behaviour (gross advances strictly every tick).
func TestAdvance_NoStopWhenDisabled(t *testing.T) {
	tw := newTestTwin(0, 2, 4)
	prev := 0.0
	for i := 0; i < 50; i++ {
		tw.advance()
		if tw.metrics[0].val <= prev {
			t.Fatalf("tick %d: gross must advance every tick when stops disabled (val=%v prev=%v)", i, tw.metrics[0].val, prev)
		}
		prev = tw.metrics[0].val
	}
}

// TestTicksFor covers the seconds→ticks clamp used for stop-duration config.
func TestTicksFor(t *testing.T) {
	cases := []struct{ sec, interval, want int }{
		{120, 15, 8}, {600, 15, 40}, {10, 15, 1}, {0, 15, 1}, {30, 0, 2},
	}
	for _, c := range cases {
		if got := ticksFor(c.sec, c.interval); got != c.want {
			t.Errorf("ticksFor(%d,%d)=%d want %d", c.sec, c.interval, got, c.want)
		}
	}
}
