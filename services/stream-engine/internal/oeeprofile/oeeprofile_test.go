package oeeprofile

import "testing"

func strp(s string) *string { return &s }

// TestWantsLineLead covers the profile→line-lead mapping (WS3 Phase 2a): a
// tenant opts into line-metered availability via availability_mode=count_silence
// OR ideal_source=lead_machine; anything else (incl. NULL/unset) does not.
func TestWantsLineLead(t *testing.T) {
	cases := []struct {
		name  string
		avail *string
		ideal *string
		want  bool
	}{
		{"count_silence opts in", strp("count_silence"), nil, true},
		{"lead_machine opts in", nil, strp("lead_machine"), true},
		{"either match opts in", strp("state"), strp("lead_machine"), true},
		{"state + nameplate does not", strp("state"), strp("nameplate"), false},
		{"both unset does not", nil, nil, false},
		{"unrelated values do not", strp("foo"), strp("bar"), false},
	}
	for _, c := range cases {
		if got := wantsLineLead(c.avail, c.ideal); got != c.want {
			t.Errorf("%s: wantsLineLead=%v want %v", c.name, got, c.want)
		}
	}
}

// TestNewResolverDefaultsTTL proves a non-positive ttl falls back to DefaultTTL.
func TestNewResolverDefaultsTTL(t *testing.T) {
	r := New(nil, 0, nil)
	if r.ttl != DefaultTTL {
		t.Errorf("ttl=%v want %v", r.ttl, DefaultTTL)
	}
}
