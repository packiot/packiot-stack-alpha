package main

import (
	"regexp"
	"testing"
)

// The Incoplast events UNION must name its columns: equipment_events gained
// ingested_at/source_seq and equipment_events_man did not, so `select * … union
// all select *` failed on every call ("each UNION query must have the same
// number of columns"). The golden tests use a scripted reader (no DB) and cannot
// see this, hence a guard on the SQL text.
func TestIncoplastEventsUnionNamesItsColumns(t *testing.T) {
	star := regexp.MustCompile(`(?i)select\s+\*\s+from\s+(silver\.|public\.)?equipment_events(_man)?\b`)
	if star.MatchString(sqlIncoplastEvents) {
		t.Fatal("sqlIncoplastEvents selects * from an event table inside a UNION; list the shared columns")
	}
}
