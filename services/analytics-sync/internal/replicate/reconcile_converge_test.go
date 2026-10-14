package replicate

import (
	"database/sql"
	"testing"
	"time"
)

func cvAt(hhmm string) time.Time {
	t, _ := time.Parse("2006-01-02 15:04", "2026-10-07 "+hhmm)
	return t
}
func cvRR(lo, hi string) runRange {
	h := cvAt(hi)
	return runRange{lo: cvAt(lo), hi: &h}
}
func cvNT(hhmm string) sql.NullTime {
	if hhmm == "" {
		return sql.NullTime{}
	}
	return sql.NullTime{Time: cvAt(hhmm), Valid: true}
}

func TestSameCoverageMergesAdjacentRuns(t *testing.T) {
	// 894508: legacy split one run into two adjacent rows; the twin holds one.
	if !sameCoverage([]runRange{cvRR("10:01", "10:43"), cvRR("10:43", "13:06")}, []runRange{cvRR("10:01", "13:06")}) {
		t.Error("adjacent legacy rows must equal one twin row")
	}
	if sameCoverage([]runRange{cvRR("09:31", "23:40")}, []runRange{cvRR("09:31", "23:59")}) {
		t.Error("different ends compared equal")
	}
	open := runRange{lo: cvAt("08:00")}
	if sameCoverage([]runRange{open}, []runRange{cvRR("08:00", "09:00")}) {
		t.Error("open vs closed compared equal")
	}
	if !sameCoverage(nil, nil) {
		t.Error("empty sets differ")
	}
}

func TestPlanHeader(t *testing.T) {
	cases := []struct {
		name string
		l    legacyPO
		tw   twinPO
		want headerFix
	}{
		{"896799 wrong first start", legacyPO{status: 3, tsStart: cvNT("19:27"), tsEnd: cvNT("23:00")}, twinPO{status: 3, tsStart: cvNT("08:53"), tsEnd: cvNT("23:00")}, headerRetime},
		{"897794 end moved back by legacy", legacyPO{status: 3, tsStart: cvNT("09:31"), tsEnd: cvNT("20:40")}, twinPO{status: 3, tsStart: cvNT("09:31"), tsEnd: cvNT("23:29")}, headerRetime},
		{"equal", legacyPO{status: 3, tsStart: cvNT("09:31"), tsEnd: cvNT("20:40")}, twinPO{status: 3, tsStart: cvNT("09:31"), tsEnd: cvNT("20:40")}, headerNone},
		{"legacy inverted: never written", legacyPO{status: 3, tsStart: cvNT("10:00"), tsEnd: cvNT("09:00")}, twinPO{status: 3, tsStart: cvNT("08:00"), tsEnd: cvNT("09:00")}, headerNone},
		{"legacy finished without start", legacyPO{status: 3, tsEnd: cvNT("09:00")}, twinPO{status: 3, tsStart: cvNT("08:00"), tsEnd: cvNT("09:00")}, headerNone},
		{"897519 put back to available", legacyPO{status: 1}, twinPO{status: 3, tsStart: cvNT("00:41"), tsEnd: cvNT("00:43")}, headerRevertAvailable},
		{"894544 paused twin, available legacy", legacyPO{status: 1}, twinPO{status: 4, tsStart: cvNT("07:19"), tsEnd: cvNT("07:22")}, headerRevertAvailable},
		{"running twin is the replay's business", legacyPO{status: 1}, twinPO{status: 2, tsStart: cvNT("07:19")}, headerNone},
		{"running legacy: finish path, not retime", legacyPO{status: 2, tsStart: cvNT("07:00")}, twinPO{status: 3, tsStart: cvNT("07:00"), tsEnd: cvNT("08:00")}, headerNone},
	}
	for _, c := range cases {
		if got := planHeader(c.l, c.tw); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestPlanWindows(t *testing.T) {
	since := cvAt("00:00").Add(-14 * 24 * time.Hour)
	resolve := func(eq int) (int, bool) {
		m := map[int]int{75: 48, 90: 50}
		v, ok := m[eq]
		return v, ok
	}
	L3 := twinPO{status: 3, idEquipment: 48}
	lr := func(eq int, lo, hi string) legacyRuntime { return legacyRuntime{idEquipment: eq, r: cvRR(lo, hi)} }

	// 897794: legacy window ends earlier → converge
	want, act, _ := planWindows(legacyPO{status: 3}, []legacyRuntime{lr(75, "09:31", "20:40")}, L3, []runRange{cvRR("09:31", "23:29")}, since, resolve)
	if !act || len(want) != 1 || !want[0].hi.Equal(cvAt("20:40")) {
		t.Errorf("897794: act=%v want=%v", act, want)
	}
	// equal coverage → nothing
	if _, act, r := planWindows(legacyPO{status: 3}, []legacyRuntime{lr(75, "10:01", "10:43"), lr(75, "10:43", "13:06")}, L3, []runRange{cvRR("10:01", "13:06")}, since, resolve); act || r != "" {
		t.Errorf("equal: act=%v reason=%q", act, r)
	}
	// 896799: no twin window → converge (create)
	if _, act, _ := planWindows(legacyPO{status: 3}, []legacyRuntime{lr(75, "19:27", "23:00")}, L3, nil, since, resolve); !act {
		t.Error("896799: missing twin window not created")
	}
	// legacy runtime on another line → refuse
	if _, act, r := planWindows(legacyPO{status: 3}, []legacyRuntime{lr(90, "09:00", "10:00")}, L3, nil, since, resolve); act || r != "equipment_mismatch" {
		t.Errorf("mismatch: act=%v reason=%q", act, r)
	}
	// legacy runtime still open → refuse
	if _, act, r := planWindows(legacyPO{status: 3}, []legacyRuntime{{idEquipment: 75, r: runRange{lo: cvAt("09:00")}}}, L3, nil, since, resolve); act || r == "" {
		t.Errorf("open legacy: act=%v reason=%q", act, r)
	}
	// older than the window → report, do not touch (history needs the runbook)
	oldTwin := []runRange{{lo: since.Add(-48 * time.Hour), hi: func() *time.Time { x := since.Add(-40 * time.Hour); return &x }()}}
	oldLeg := []legacyRuntime{{idEquipment: 75, r: runRange{lo: since.Add(-48 * time.Hour), hi: func() *time.Time { x := since.Add(-44 * time.Hour); return &x }()}}}
	if _, act, r := planWindows(legacyPO{status: 3}, oldLeg, L3, oldTwin, since, resolve); act || r != "old" {
		t.Errorf("old: act=%v reason=%q", act, r)
	}
	// finished in legacy with NO runtime rows → the header backfill owns it
	if _, act, _ := planWindows(legacyPO{status: 3}, nil, L3, []runRange{cvRR("09:00", "10:00")}, since, resolve); act {
		t.Error("legacy status 3 without rows must not delete twin windows")
	}
	// 891336: available in legacy, never ran there → twin-only windows go
	avail := twinPO{status: 1, idEquipment: 50}
	if want, act, _ := planWindows(legacyPO{status: 1}, nil, avail, []runRange{cvRR("15:29", "23:18")}, since, resolve); !act || len(want) != 0 {
		t.Errorf("891336: act=%v want=%v", act, want)
	}
	// 897519: available WITH a legacy runtime row → never create windows for it
	if _, act, _ := planWindows(legacyPO{status: 1}, []legacyRuntime{lr(75, "00:41", "00:43")}, twinPO{status: 1, idEquipment: 48}, nil, since, resolve); act {
		t.Error("available PO got a window")
	}
	// states differ (twin not reverted yet / running) → wait
	if _, act, _ := planWindows(legacyPO{status: 1}, nil, L3, []runRange{cvRR("15:29", "23:18")}, since, resolve); act {
		t.Error("acted while states differ")
	}
}
