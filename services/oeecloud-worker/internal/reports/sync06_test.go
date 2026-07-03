package reports

import (
	"strings"
	"testing"
)

// The embedded body must remain the captured prod state machine: all
// numbered conditions present, the b-generation compute, the window
// literals, and no plpgsql wrapper remnants.
func TestSync06BodyFidelity(t *testing.T) {
	for _, m := range []string{
		"get_data_sync_enterprsie_06b(21)",
		"logics = 0", "1 as logics", "2 as logics", "4 as logics",
		"5 as logics", "6 as logics", "logics = 7", "logics = 9", "logics = 10",
		"trans_status", "to_delete",
		"interval '23 day'",
	} {
		if !strings.Contains(sync06Body, m) {
			t.Errorf("sync06 body lost %q", m)
		}
	}
	low := strings.ToLower(sync06Body)
	if strings.Contains(low, "end;") || strings.HasPrefix(strings.TrimSpace(low), "begin") {
		t.Error("plpgsql wrapper remnants must be stripped")
	}
}
