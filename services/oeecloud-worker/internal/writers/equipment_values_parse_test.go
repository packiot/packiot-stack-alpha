package writers

import (
	"encoding/json"
	"testing"
)

// Guards the 2026-07-12 poison-storm fix: numeric JSON strings must parse
// (Incoplast quotes UnitModeCurrent/counters); non-numeric values must return
// ok=false so the caller SKIPS instead of nack-looping forever.
func TestParseNumericValue(t *testing.T) {
	cases := []struct {
		raw     string
		want    float64
		wantOK  bool
	}{
		{`3`, 3, true},
		{`3.14`, 3.14, true},
		{`-7`, -7, true},
		{`"3"`, 3, true},        // numeric string (the Incoplast case that PARSES)
		{`"3.14"`, 3.14, true},  // numeric string with decimal
		{`" 5 "`, 5, true},      // whitespace-padded numeric string
		{`"Producing"`, 0, false}, // mode NAME — the poison case: must skip
		{`"UnitModeCurrent"`, 0, false},
		{`null`, 0, true}, // Go json treats null as a no-op → 0; matches pre-fix behavior (not a poison case)
		{`{"x":1}`, 0, false},
		{`"?"`, 0, false},
	}
	for _, c := range cases {
		got, ok := parseNumericValue(json.RawMessage(c.raw))
		if ok != c.wantOK || (ok && got != c.want) {
			t.Errorf("parseNumericValue(%s) = (%v,%v), want (%v,%v)", c.raw, got, ok, c.want, c.wantOK)
		}
	}
}
