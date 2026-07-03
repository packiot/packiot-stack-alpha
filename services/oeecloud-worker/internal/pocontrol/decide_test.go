package pocontrol

import (
	"strings"
	"testing"
	"time"
)

var run = &RunningPO{ID: 77, TsLower: time.Unix(1000, 0)}

// The full behavior matrix from the captured branches.
func TestDecideStartMatrix(t *testing.T) {
	cases := []struct {
		name         string
		param        int
		targetStatus int
		running      *RunningPO
		noop, juggle bool
		temp, prev   int
		endStatus    int
	}{
		{"start available, idle line", 30800, StatusAvailable, nil, false, false, 2, 3, 0},
		{"start paused target (fresh start param)", 30800, StatusPaused, nil, false, false, 2, 3, 0},
		{"resume paused, idle line", 30802, StatusPaused, nil, false, false, 2, 4, 0},
		{"start on finished target = noop", 30800, StatusFinished, nil, true, false, 0, 0, 0},
		{"start on already-running target = noop", 30800, StatusRunning, run, true, false, 0, 0, 0},
		{"start over another running PO = juggle", 30800, StatusAvailable, run, false, true, 4, 3, 3},
		{"resume over another running PO = juggle, prev paused", 30802, StatusPaused, run, false, true, 4, 4, 4},
	}
	for _, c := range cases {
		p := DecideStart(c.param, 55, c.targetStatus, c.running)
		if p.NoOp != c.noop {
			t.Errorf("%s: noop=%v want %v", c.name, p.NoOp, c.noop)
			continue
		}
		if p.NoOp {
			continue
		}
		if p.TempStatus != c.temp || p.PrevStatus != c.prev || p.Juggle != c.juggle {
			t.Errorf("%s: got temp=%d prev=%d juggle=%v", c.name, p.TempStatus, p.PrevStatus, p.Juggle)
		}
		if c.juggle {
			if p.EndPrev == nil || p.EndPrev.ID != 77 || p.EndPrev.NewStatus != c.endStatus || p.RestoreID != 55 {
				t.Errorf("%s: bad EndPrev/Restore: %+v", c.name, p)
			}
		} else if p.EndPrev != nil {
			t.Errorf("%s: unexpected EndPrev", c.name)
		}
	}
}

func TestDecideEnd(t *testing.T) {
	if !DecideEnd(30801, nil).NoOp {
		t.Error("end with nothing running must be noop (nodered po_status!=2 fallthrough)")
	}
	if p := DecideEnd(30801, run); p.NewStatus != StatusFinished || p.ID != 77 {
		t.Errorf("end: %+v", p)
	}
	if p := DecideEnd(30803, run); p.NewStatus != StatusPaused {
		t.Errorf("pause: %+v", p)
	}
}

func TestHandlesPortedSlices(t *testing.T) {
	for id, want := range map[int]bool{30800: true, 30801: true, 30802: true, 30803: true,
		30700: true,              // slice 2
		30805: true,              // slice 3
		30810: true,              // slice 4
		30861: true, 30880: true, // slice 5 + 10.8 factory door
		30850: false} { // analogs stays with the po_parameter writer
		if Handles(id) != want {
			t.Errorf("Handles(%d) != %v", id, want)
		}
	}
}

func TestHandlesTopology(t *testing.T) {
	if !Handles(30700) || !HandlesTopology(30700) {
		t.Error("30700 must dispatch to pocontrol (slice 2)")
	}
	if HandlesTopology(30701) {
		t.Error("30701 stays with the po_parameter writer")
	}
}

func TestTopologySQLShape(t *testing.T) {
	for sql, must := range map[string][]string{
		topoPackmlSeq:   {"line_unit_seq"},
		topoLineRow:     {"id_equipment_line_infeed", "GROUP BY id_equipment", "ON CONFLICT (ts_value, id_equipment)"},
		topoZeroLine:    {"id_equipment_line_infeed = 0", "ts_value < $1"},
		topoMemberRow:   {"position_in_equipment_line", "id_equipment_line_connected = EXCLUDED.id_equipment_line_connected"},
		topoZeroMembers: {"is_equipment_line_infeed = 0", "id_equipment_line_connected = $2"},
	} {
		for _, m := range must {
			if !strings.Contains(sql, m) {
				t.Errorf("topology SQL lost %q", m)
			}
		}
	}
}

func TestCreatePOShape(t *testing.T) {
	if !Handles(30805) || !HandlesCreatePO(30805) {
		t.Error("30805 must dispatch (slice 3)")
	}
	for sql, must := range map[string][]string{
		cpFamilyUpsert:  {"ON CONFLICT (id_enterprise, nm_product_family)", "RETURNING id_product_family"},
		cpProductInsert: {"WHERE NOT EXISTS", "cd_product = $5 AND id_enterprise = $4"},
		cpClientUpsert:  {"ON CONFLICT (nm_client, id_enterprise) DO NOTHING"},
		cpInsertPO:      {"ON CONFLICT (id_enterprise, id_order)", "custom_field = EXCLUDED.custom_field"},
	} {
		for _, m := range must {
			if !strings.Contains(sql, m) {
				t.Errorf("createpo SQL lost %q", m)
			}
		}
	}
	if strings.Contains(cpInsertPO, "ts_start") {
		t.Error("status=1 insert must not set ts_start (CHECK constraint semantics)")
	}
}

func TestEventsFamily(t *testing.T) {
	for id, want := range map[int]bool{30810: true, 30811: true, 30812: true,
		30813: true, 30814: true, 30820: true, 30815: false, 30861: false} {
		if HandlesEvents(id) != want {
			t.Errorf("HandlesEvents(%d) != %v", id, want)
		}
	}
	for sql, must := range map[string][]string{
		ujJustify:      {"WHERE id_equipment = $1 AND ts_event = $2", "cd_category_client"},
		ujManualInsert: {"WHERE NOT EXISTS", "cd_machine = $6 AND cd_category = $7"},
		ujTrimFirst:    {"forced_creation_system = true", "duration = $15"},
		ujTrimSecond:   {"SELECT $1, $2, 10,", "forced_creation_system"},
		ujScrapReset:   {"scrap_incr = 0", "ts_value = $2"},
		ujUserLog:      {"'event'"},
	} {
		for _, m := range must {
			if !strings.Contains(sql, m) {
				t.Errorf("slice4 SQL lost %q", m)
			}
		}
	}
}

func TestParseLocal(t *testing.T) {
	// naive string interpreted in factory tz (America/Sao_Paulo = UTC-3)
	got, err := parseLocal("2026-07-03 12:00:00", "America/Sao_Paulo")
	if err != nil || got.Hour() != 15 {
		t.Errorf("naive parse: %v %v (want 15 UTC)", got, err)
	}
	// RFC3339 offset wins over tz param
	got, err = parseLocal("2026-07-03T12:00:00Z", "America/Sao_Paulo")
	if err != nil || got.Hour() != 12 {
		t.Errorf("rfc3339 parse: %v %v", got, err)
	}
}

func TestSetupUserlogFamily(t *testing.T) {
	for id, want := range map[int]bool{30861: true, 30862: true, 30880: true, 30863: false} {
		if HandlesSetup(id) != want {
			t.Errorf("HandlesSetup(%d) != %v", id, want)
		}
	}
	if !strings.Contains(setupBegin, "setup_end_time = NULL") {
		t.Error("30861 must clear setup_end_time (prod semantics)")
	}
	if !strings.Contains(userLog30880, "ip, ts_log") {
		t.Error("30880 carries ip column (unlike the event-family log)")
	}
}
