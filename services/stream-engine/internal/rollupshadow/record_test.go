package rollupshadow

import (
	"testing"
	"time"
)

func TestHourToRecord(t *testing.T) {
	at := func(s string) time.Time { v, _ := time.Parse(time.RFC3339, s); return v }
	never := time.Time{}
	cases := []struct {
		name      string
		now, last time.Time
		wantOK    bool
		wantFrom  string
	}{
		{"too early in the hour", at("2026-10-15T16:05:00Z"), never, false, ""},
		{"records the previous hour", at("2026-10-15T16:07:00Z"), never, true, "2026-10-15T15:00:00Z"},
		{"once per hour", at("2026-10-15T16:30:00Z"), at("2026-10-15T16:00:00Z"), false, ""},
		{"next hour again", at("2026-10-15T17:08:00Z"), at("2026-10-15T16:00:00Z"), true, "2026-10-15T16:00:00Z"},
		{"non-UTC clock", at("2026-10-15T13:09:00-03:00"), never, true, "2026-10-15T15:00:00Z"},
	}
	for _, c := range cases {
		from, to, ok := HourToRecord(c.now, c.last)
		if ok != c.wantOK {
			t.Errorf("%s: ok = %v, want %v", c.name, ok, c.wantOK)
			continue
		}
		if ok && (from.Format(time.RFC3339) != c.wantFrom || to.Sub(from) != time.Hour) {
			t.Errorf("%s: [%s, %s), want from %s and one hour", c.name, from.Format(time.RFC3339), to.Format(time.RFC3339), c.wantFrom)
		}
	}
	if q := RecordQuery("silver"); q != `SELECT "silver".rollup_shadow_record($1, $2)` {
		t.Errorf("RecordQuery = %q", q)
	}
}
