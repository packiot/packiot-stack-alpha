// events_sync_test.go — pure helpers + tiny sentinels for events_sync.
// End-to-end coverage of the prod-fetch + tx INSERT path lives in the
// staging integration loop (a real prod read + a real staging tx that
// only the staging compose env can produce safely).
package reconcile

import (
	"errors"
	"testing"
)

func TestEventCursorSource_StableSuffix(t *testing.T) {
	if got := eventCursorSource("cpack-prod-go"); got != "cpack-prod-go-events" {
		t.Errorf("eventCursorSource = %q, want %q", got, "cpack-prod-go-events")
	}
	if got := eventCursorSource("azpack-prod-go"); got != "azpack-prod-go-events" {
		t.Errorf("eventCursorSource(azpack) = %q, want %q", got, "azpack-prod-go-events")
	}
}

func TestEventCursorSource_DoesNotCollideWithUserLogsCursor(t *testing.T) {
	// The user_logs cursor lives at source=cpack-prod-go. The events
	// cursor MUST NOT share that key or the two replay loops would
	// trample each other's last_log_id. This test guards the suffix
	// convention against well-meaning refactors.
	userLogsSource := "cpack-prod-go"
	if eventCursorSource(userLogsSource) == userLogsSource {
		t.Fatal("events cursor source must differ from user_logs cursor source")
	}
}

func TestEventsSync_SentinelsDistinct(t *testing.T) {
	// RunEventsSync branches on these via errors.Is — they must be
	// reference-distinct so equality matches exactly the intended branch.
	if errors.Is(errEventAlreadyMapped, errEventUnmappedEquipment) {
		t.Error("errEventAlreadyMapped must not satisfy errors.Is(errEventUnmappedEquipment)")
	}
	if errors.Is(errEventUnmappedEquipment, errEventAlreadyMapped) {
		t.Error("errEventUnmappedEquipment must not satisfy errors.Is(errEventAlreadyMapped)")
	}
}
