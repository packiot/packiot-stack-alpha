// setup_userlog.go — ADR-0010 10.3 slice 5 (30861/30862 setup
// counters) + port 10.8's factory entry (30880 user-log insert).
// With these, EVERY parameter branch of the captured prep node is
// ported.
//
// 30861/30862 update equipment_live_job — engine-populated
// (P3c); on shadow flows the UPDATE no-ops until P3c lands, exactly
// as prod's would against an absent row. GUARDRAIL: single-row
// UPDATEs by id_equipment + user_logs append; nothing else.
package pocontrol

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// HandlesSetup covers slice 5 + the 30880 audit insert.
func HandlesSetup(id int) bool { return id == 30861 || id == 30862 || id == 30880 }

const setupBegin = `
	UPDATE %[1]s.equipment_live_job
	   SET setup_begin_time = $2, setup_end_time = NULL
	 WHERE id_equipment = $1`

const setupEnd = `
	UPDATE %[1]s.equipment_live_job
	   SET setup_end_time = $2
	 WHERE id_equipment = $1`

const userLog30880 = `
	INSERT INTO %[1]s.user_logs
	       (ts_event, id_enterprise, id_site, id_area, id_equipment,
	        nm_user, category, subcategory, description, ip, ts_log)
	VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now())`

type userLogPayload struct {
	Value struct {
		TsEvent     json.RawMessage `json:"ts_event"` // ms number OR string — prod's new Date() takes both
		User        string          `json:"user"`
		Category    string          `json:"category"`
		Subcategory string          `json:"subcategory"`
		Description string          `json:"description"`
		IP          string          `json:"ip"`
	} `json:"value"`
	Timezone string `json:"timezone"`
}

func (h *Handler) executeSetupOrUserlog(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	paramID := derefID((*int)(m.ID))
	info, ok, err := h.resolveOrNoop(ctx, m)
	if err != nil || !ok {
		return err
	}

	switch paramID {
	case 30861, 30862:
		ts := time.UnixMilli(m.Timestamp).Round(time.Second).UTC()
		sql := setupBegin
		if paramID == 30862 {
			sql = setupEnd
		}
		if _, err := pool.Exec(ctx, fmt.Sprintf(sql, schema), info.IDEquipment, ts); err != nil {
			return fmt.Errorf("setup %d: %w", paramID, err)
		}
	case 30880:
		var p userLogPayload
		if err := json.Unmarshal(m.Value, &p); err != nil {
			return fmt.Errorf("30880 payload: %w", err)
		}
		tsEvent, err := parseFlexibleTs(p.Value.TsEvent, p.Timezone)
		if err != nil {
			return fmt.Errorf("30880 ts_event: %w", err)
		}
		if _, err := pool.Exec(ctx, fmt.Sprintf(userLog30880, schema),
			tsEvent, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
			p.Value.User, p.Value.Category, p.Value.Subcategory, p.Value.Description, p.Value.IP); err != nil {
			return fmt.Errorf("30880 insert: %w", err)
		}
	}
	h.events.Add(1)
	return nil
}

// parseFlexibleTs mirrors prod's new Date(x): epoch-ms number or a
// time string (local-in-timezone for naive forms).
func parseFlexibleTs(raw json.RawMessage, tz string) (time.Time, error) {
	var ms int64
	if err := json.Unmarshal(raw, &ms); err == nil && ms > 0 {
		return time.UnixMilli(ms).UTC(), nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return parseLocal(s, tz)
	}
	return time.Time{}, fmt.Errorf("unparseable ts_event %s", string(raw))
}
