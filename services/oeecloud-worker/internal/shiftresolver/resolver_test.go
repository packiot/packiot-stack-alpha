package shiftresolver

import (
	"testing"
	"time"
)

func loc(t *testing.T, name string) *time.Location {
	t.Helper()
	l, err := time.LoadLocation(name)
	if err != nil {
		t.Fatalf("LoadLocation(%s): %v", name, err)
	}
	return l
}

func intp(v int) *int { return &v }

// Expected values are hand-derived from the SQL expression in
// piot_get_shift_hour_by_equipment (see package doc).
func TestWeekOffsetSeconds(t *testing.T) {
	utc := time.UTC
	sp := loc(t, "America/Sao_Paulo") // UTC-3, no DST since 2019

	tests := []struct {
		name string
		ts   time.Time
		site SiteInfo
		want int64
	}{
		{
			// Wednesday 10:00 UTC, week_begin 0 → 2 days + 10 h.
			name: "utc wb=0 midweek",
			ts:   time.Date(2026, 7, 1, 10, 0, 0, 0, utc),
			site: SiteInfo{Loc: utc, WeekBegin: 0},
			want: 2*86400 + 36000,
		},
		{
			// Monday 00:00 with wb=1 (staging site 3): the shift-week
			// started 1 s "into" Monday last week, so this instant is
			// second 604799 of the PREVIOUS shift-week.
			name: "utc wb=1 monday-midnight wraps to previous week",
			ts:   time.Date(2026, 6, 29, 0, 0, 0, 0, utc),
			site: SiteInfo{Loc: utc, WeekBegin: 1},
			want: 7*86400 - 1,
		},
		{
			// CPACK shape: Sao Paulo, wb=-3000 (shift-week starts Sunday
			// 23:10 local). Sunday 23:30 local is 20 min into the new
			// shift-week: ts − Mon00:00 = −1800 s, minus (−3000) = 1200.
			name: "sao-paulo wb=-3000 just after week origin",
			ts:   time.Date(2026, 7, 5, 23, 30, 0, 0, sp),
			site: SiteInfo{Loc: sp, WeekBegin: -3000},
			want: 1200,
		},
		{
			// One minute BEFORE the Sunday-23:10 origin → near the end of
			// the previous shift-week: 6 d 23 h 09 m + 3000 s.
			name: "sao-paulo wb=-3000 just before week origin",
			ts:   time.Date(2026, 7, 5, 23, 9, 0, 0, sp),
			site: SiteInfo{Loc: sp, WeekBegin: -3000},
			want: 6*86400 + 23*3600 + 9*60 + 3000,
		},
		{
			// Timezone matters: 02:00 UTC Tuesday is 23:00 Monday in Sao
			// Paulo — still day 0 of the local week.
			name: "sao-paulo wb=0 utc-vs-local day boundary",
			ts:   time.Date(2026, 6, 30, 2, 0, 0, 0, utc),
			site: SiteInfo{Loc: sp, WeekBegin: 0},
			want: 23 * 3600,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := WeekOffsetSeconds(tt.ts, tt.site); got != tt.want {
				t.Errorf("WeekOffsetSeconds() = %d, want %d (Δ %d)", got, tt.want, got-tt.want)
			}
		})
	}
}

// Pick ports ORDER BY (id_area = eq_area) DESC NULLS LAST, id_shift_hour.
func TestPick(t *testing.T) {
	tests := []struct {
		name       string
		candidates []ShiftHour
		eqArea     int
		wantSH     int // id_shift_hour; -1 = nil
	}{
		{"empty", nil, 10, -1},
		{
			"area match beats site-level",
			[]ShiftHour{
				{IDShiftHour: 1, IDShift: 5, IDArea: nil},
				{IDShiftHour: 2, IDShift: 6, IDArea: intp(10)},
			}, 10, 2,
		},
		{
			"non-null mismatch beats null (NULLS LAST)",
			[]ShiftHour{
				{IDShiftHour: 1, IDShift: 5, IDArea: nil},
				{IDShiftHour: 2, IDShift: 6, IDArea: intp(99)},
			}, 10, 2,
		},
		{
			"lowest id_shift_hour breaks rank ties",
			[]ShiftHour{
				{IDShiftHour: 424, IDShift: 16, IDArea: intp(10)},
				{IDShiftHour: 421, IDShift: 16, IDArea: intp(10)},
				{IDShiftHour: 423, IDShift: 16, IDArea: intp(10)},
			}, 10, 421,
		},
		{
			"site-level used when nothing else matches",
			[]ShiftHour{{IDShiftHour: 7, IDShift: 3, IDArea: nil}},
			10, 7,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Pick(tt.candidates, tt.eqArea)
			if tt.wantSH == -1 {
				if got != nil {
					t.Fatalf("Pick() = %+v, want nil", got)
				}
				return
			}
			if got == nil || got.IDShiftHour != tt.wantSH {
				t.Errorf("Pick() = %+v, want id_shift_hour=%d", got, tt.wantSH)
			}
		})
	}
}

// The window comparison is begin_time <= X < end_time — begin inclusive,
// end exclusive, exactly as the SQL's <= / > pair.
func TestWindowEdges(t *testing.T) {
	site := SiteInfo{Loc: time.UTC, WeekBegin: 0}
	hours := []ShiftHour{{IDShiftHour: 1, IDShift: 1, BeginTime: 0, EndTime: 26400}}

	atBegin := time.Date(2026, 6, 29, 0, 0, 0, 0, time.UTC)  // X=0
	atEnd := time.Date(2026, 6, 29, 7, 20, 0, 0, time.UTC)   // X=26400

	inWindow := func(ts time.Time) bool {
		x := WeekOffsetSeconds(ts, site)
		for _, sh := range hours {
			if sh.BeginTime <= x && sh.EndTime > x {
				return true
			}
		}
		return false
	}
	if !inWindow(atBegin) {
		t.Error("begin_time must be inclusive")
	}
	if inWindow(atEnd) {
		t.Error("end_time must be exclusive")
	}
}
