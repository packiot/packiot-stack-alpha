package reports

import (
	"strings"
	"testing"
)

// The adapter's fidelity guards: descriptor fields must remain SQL
// PARAMETERS (injection-proof), the Neopac semantics must survive the
// generalization, and both archetypes target the pool's natural key.
func TestBoxesAdapterShape(t *testing.T) {
	for _, m := range []string{
		`regexp_replace(hora, '^PT(\d+)H(\d+)M(\d+)S$', '\1:\2:\3')`, // ISO-duration parse
		"AT TIME ZONE $8::text",                            // tz is a parameter, not literal
		"id_site = 0 AND id_area = 0 AND id_equipment = 0", // sentinel row
		"analogs ? $1::text",                               // label key is a parameter
		"ON CONFLICT (customer_id, label_key, ts_value, id_order)",
	} {
		if !strings.Contains(deliverySQL, m) {
			t.Errorf("delivery archetype lost %q", m)
		}
	}
	for _, m := range []string{
		"time_bucket($3::interval, ts_value)",
		"GROUP BY 3, 4, id_equipment, id_area, id_site",
		"ON CONFLICT (customer_id, label_key, ts_value, id_order)",
	} {
		if !strings.Contains(counterSQL, m) {
			t.Errorf("counter archetype lost %q", m)
		}
	}
	// No descriptor field may be string-interpolated: the only %-verbs
	// allowed are the two schema slots.
	for _, sql := range []string{deliverySQL, counterSQL, loadFormatsSQL} {
		cleaned := strings.ReplaceAll(strings.ReplaceAll(sql, "%[1]s", ""), "%[2]s", "")
		if strings.Contains(cleaned, "%") {
			t.Error("unexpected interpolation verb — descriptor fields must be parameters")
		}
	}
}

// The obd-port bridge must stay descriptor-parameterized (no equipment
// names in SQL) and keep prod's upsert key.
func TestBoxesBridgeShape(t *testing.T) {
	for _, m := range []string{
		"child.cd_equipment = $1", "parent.cd_equipment = $2",
		"time_bucket($4::interval", "label_key = $5",
		"ON CONFLICT (ts_value, id_equipment)",
	} {
		if !strings.Contains(bridgeSQL, m) {
			t.Errorf("bridge SQL lost %q", m)
		}
	}
	for _, banned := range []string{"TL117", "Packer", "= 13"} {
		if strings.Contains(bridgeSQL, banned) {
			t.Errorf("hardcoded tenant artifact %q in bridge SQL", banned)
		}
	}
}
