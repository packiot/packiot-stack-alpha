package oeeprofile

import "testing"

func TestLineOverride(t *testing.T) {
	s := func(v string) *string { return &v }
	cases := []struct {
		avail, ideal *string
		want         override
	}{
		{nil, nil, overrideNone},
		{s("count_silence"), nil, overrideIn},
		{nil, s("lead_machine"), overrideIn},
		{s("state"), nil, overrideOut},
		{nil, s("nameplate"), overrideOut},
	}
	for _, c := range cases {
		if got := lineOverride(c.avail, c.ideal); got != c.want {
			t.Errorf("lineOverride(%v,%v) = %v, want %v", c.avail, c.ideal, got, c.want)
		}
	}
}
