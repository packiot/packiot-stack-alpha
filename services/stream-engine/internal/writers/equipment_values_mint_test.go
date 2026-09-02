package writers

import (
	"strings"
	"testing"
)

// ADR-0010 10.4 fidelity: the event mint matches the captured prod node.
func TestEventMintSQLShape(t *testing.T) {
	for _, m := range []string{"equipment_events", "ON CONFLICT (id_equipment, ts_event)", "status = EXCLUDED.status"} {
		if !strings.Contains(eventMintSQL, m) {
			t.Errorf("event mint SQL lost: %q", m)
		}
	}
}
