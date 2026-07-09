// events_justify.go — ADR-0010 10.3 slice 4: the factory-side event
// family (30810 justify / 30811 manual create / 30812 manual update /
// 30813 trim-first / 30814 trim-second / 30820 scrap reset), from the
// captured prep node.
//
// TWIN DECISION (recorded): shadow-mirror's replay handlers implement
// these same business actions from user_logs — but shadow-mirror is on
// ADR-0016's RETIREMENT list, so no shared library is built for it.
// Twin consistency is enforced by semantics (same natural keys, same
// column sets), not shared code.
//
// TIMEZONE SEMANTICS (load-bearing): prod prefixes every statement
// with SET timezone and passes ts_event/ts_end as LOCAL strings. The
// port parses them in the payload's timezone and binds timestamptz
// parameters — same instants, no session state.
//
// GUARDRAIL STATEMENT: writes equipment_events / equipment_events_man
// (keyed (id_equipment, ts_event) / (ts_event)) + user_logs (append
// only) + one equipment_values dedup-key UPDATE (30820). PO tables
// untouched.
package pocontrol

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// HandlesEvents reports whether id belongs to slice 4.
func HandlesEvents(id int) bool {
	return (id >= 30810 && id <= 30814) || id == 30820
}

type eventPayload struct {
	Timezone        string          `json:"timezone"`
	TsEvent         string          `json:"ts_event"`
	TsEnd           string          `json:"ts_end"`
	PlannedDwt      *string         `json:"planned_dwt"`
	ChangeOver      *string         `json:"change_over"`
	Idle            *string         `json:"idle"`
	TxtDowntime     string          `json:"txt_downtime"`
	Sector          string          `json:"sector"`
	Category        string          `json:"category"`
	Subcategory     string          `json:"subcategory"`
	CategoryDesc    string          `json:"category_desc"`
	SubcategoryDesc string          `json:"subcategory_desc"`
	CategoryCode    *int64          `json:"category_code"`
	SubcategoryCode *int64          `json:"subcategory_code"`
	User            string          `json:"user"`
	Timestamp       json.Number     `json:"timestamp"`
	Raw             json.RawMessage `json:"-"`
}

// parseLocal interprets a factory-local time string in tz (prod's SET
// timezone semantics). Accepts RFC3339 (offset wins) and the two
// naive forms the operator UI emits.
func parseLocal(s, tz string) (time.Time, error) {
	if s == "" {
		return time.Time{}, fmt.Errorf("empty time string")
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	for _, layout := range []string{"2006-01-02 15:04:05", "2006-01-02T15:04:05"} {
		if t, err := time.ParseInLocation(layout, s, loc); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("unparseable time %q", s)
}

const ujUserLog = `
	INSERT INTO %[1]s.user_logs
	       (ts_event, id_enterprise, id_site, id_area, id_equipment,
	        nm_user, category, subcategory, description, ts_log)
	VALUES ($1, $2, $3, $4, $5, $6, 'event', $7, $8, now())`

const ujJustify = `
	UPDATE %[1]s.equipment_events SET
	       planned_downtime = COALESCE($3::boolean, planned_downtime),
	       change_over      = COALESCE($4::boolean, change_over),
	       idle             = COALESCE($5, idle),
	       txt_downtime_notes = $6, cd_subcategory = $7, cd_machine = $8,
	       cd_category = $9, desc_category = $10, desc_subcategory = $11,
	       cd_category_client = $12, cd_subcategory_client = $13
	 WHERE id_equipment = $1 AND ts_event = $2`

const ujManualInsert = `
	INSERT INTO %[1]s.equipment_events_man
	       (id_equipment, id_enterprise, planned_downtime, idle, change_over,
	        cd_machine, cd_category, cd_subcategory, txt_downtime_notes,
	        ts_event, ts_end, duration, desc_category, desc_subcategory,
	        cd_category_client, cd_subcategory_client)
	SELECT $1, $2, $3::boolean, $4, $5::boolean, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
	 WHERE NOT EXISTS (SELECT 1 FROM %[1]s.equipment_events_man
	        WHERE ts_event = $10 AND cd_machine = $6 AND cd_category = $7 AND cd_subcategory = $8)`

const ujManualUpdate = `
	UPDATE %[1]s.equipment_events_man SET
	       planned_downtime = $3::boolean, idle = COALESCE($4, idle),
	       change_over = $5::boolean, txt_downtime_notes = $6,
	       cd_subcategory = $7, cd_machine = $8, cd_category = $9,
	       desc_category = $10, desc_subcategory = $11,
	       cd_category_client = $12, cd_subcategory_client = $13
	 WHERE id_equipment = $1 AND ts_event = $2`

const ujTrimFirst = `
	UPDATE %[1]s.equipment_events SET
	       idle = COALESCE($3, idle),
	       planned_downtime = COALESCE($4::boolean, planned_downtime),
	       change_over = COALESCE($5::boolean, change_over),
	       txt_downtime_notes = $6, cd_subcategory = $7, cd_machine = $8,
	       cd_category = $9, desc_category = $10, desc_subcategory = $11,
	       cd_category_client = $12, cd_subcategory_client = $13,
	       ts_end = $14, duration = $15, forced_creation_system = true
	 WHERE id_equipment = $1 AND ts_event = $2`

// Trim-second inserts the tail event with prod's literal status 10 +
// forced_creation_system=true; ts_end/duration optional.
const ujTrimSecond = `
	INSERT INTO %[1]s.equipment_events
	       (id_equipment, id_enterprise, status, planned_downtime, idle,
	        change_over, cd_machine, cd_category, cd_subcategory,
	        txt_downtime_notes, ts_event, ts_end, duration,
	        desc_category, desc_subcategory, forced_creation_system,
	        cd_category_client, cd_subcategory_client)
	SELECT $1, $2, 10, $3::boolean, $4, $5::boolean, $6, $7, $8, $9, $10, $11, $12, $13, $14, true, $15, $16
	 WHERE NOT EXISTS (SELECT 1 FROM %[1]s.equipment_events
	        WHERE ts_event = $10 AND cd_machine = $6 AND cd_category = $7 AND cd_subcategory = $8)`

const ujScrapReset = `
	UPDATE %[1]s.equipment_values SET scrap_incr = 0
	 WHERE id_equipment = $1 AND ts_value = $2`

func (h *Handler) executeEvents(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	paramID := derefID((*int)(m.ID))
	info, ok, err := h.resolveOrNoop(ctx, m)
	if err != nil || !ok {
		return err
	}
	var p eventPayload
	if err := json.Unmarshal(m.Value, &p); err != nil {
		return fmt.Errorf("event payload: %w", err)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	logDesc := fmt.Sprint(paramID)
	logSub := ""

	switch paramID {
	case 30820:
		tsMs, terr := p.Timestamp.Int64()
		if terr != nil || tsMs == 0 {
			tsMs = m.Timestamp
		}
		ts := time.UnixMilli(tsMs).Round(time.Second).UTC()
		if _, err := tx.Exec(ctx, fmt.Sprintf(ujScrapReset, schema), info.IDEquipment, ts); err != nil {
			return fmt.Errorf("scrap reset: %w", err)
		}
		h.events.Add(1)
		return tx.Commit(ctx)

	case 30810:
		tsEvent, err := parseLocal(p.TsEvent, p.Timezone)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf(ujJustify, schema),
			info.IDEquipment, tsEvent, p.PlannedDwt, p.ChangeOver, p.Idle,
			p.TxtDowntime, p.Subcategory, p.Sector, p.Category,
			p.CategoryDesc, p.SubcategoryDesc, p.CategoryCode, p.SubcategoryCode); err != nil {
			return fmt.Errorf("justify: %w", err)
		}
		logSub = "justify"
		if err := h.writeUserLog(ctx, tx, schema, info, tsEvent, p.User, logSub, logDesc); err != nil {
			return err
		}

	case 30811, 30812:
		tsEvent, err := parseLocal(p.TsEvent, p.Timezone)
		if err != nil {
			return err
		}
		if paramID == 30811 {
			tsEnd, err := parseLocal(p.TsEnd, p.Timezone)
			if err != nil {
				return err
			}
			// prod 30811: signed duration (Date.parse diff, NOT abs).
			duration := int(tsEnd.Sub(tsEvent).Seconds())
			if _, err := tx.Exec(ctx, fmt.Sprintf(ujManualInsert, schema),
				info.IDEquipment, info.IDEnterprise, p.PlannedDwt, p.Idle, p.ChangeOver,
				p.Sector, p.Category, p.Subcategory, p.TxtDowntime,
				tsEvent, tsEnd, duration, p.CategoryDesc, p.SubcategoryDesc,
				p.CategoryCode, p.SubcategoryCode); err != nil {
				return fmt.Errorf("manual insert: %w", err)
			}
		} else {
			if _, err := tx.Exec(ctx, fmt.Sprintf(ujManualUpdate, schema),
				info.IDEquipment, tsEvent, p.PlannedDwt, p.Idle, p.ChangeOver,
				p.TxtDowntime, p.Subcategory, p.Sector, p.Category,
				p.CategoryDesc, p.SubcategoryDesc, p.CategoryCode, p.SubcategoryCode); err != nil {
				return fmt.Errorf("manual update: %w", err)
			}
		}
		logSub = "manual event"
		if err := h.writeUserLog(ctx, tx, schema, info, tsEvent, p.User, logSub, logDesc); err != nil {
			return err
		}

	case 30813, 30814:
		tsEvent, err := parseLocal(p.TsEvent, p.Timezone)
		if err != nil {
			return err
		}
		var tsEnd *time.Time
		var duration *int
		if p.TsEnd != "" {
			te, err := parseLocal(p.TsEnd, p.Timezone)
			if err != nil {
				return err
			}
			tsEnd = &te
			// prod trims: Math.abs
			d := int(te.Sub(tsEvent).Seconds())
			if d < 0 {
				d = -d
			}
			duration = &d
		}
		if paramID == 30813 {
			if tsEnd == nil {
				return fmt.Errorf("30813 requires ts_end")
			}
			if _, err := tx.Exec(ctx, fmt.Sprintf(ujTrimFirst, schema),
				info.IDEquipment, tsEvent, p.Idle, p.PlannedDwt, p.ChangeOver,
				p.TxtDowntime, p.Subcategory, p.Sector, p.Category,
				p.CategoryDesc, p.SubcategoryDesc, p.CategoryCode, p.SubcategoryCode,
				*tsEnd, *duration); err != nil {
				return fmt.Errorf("trim first: %w", err)
			}
		} else {
			if _, err := tx.Exec(ctx, fmt.Sprintf(ujTrimSecond, schema),
				info.IDEquipment, info.IDEnterprise, p.PlannedDwt, p.Idle, p.ChangeOver,
				p.Sector, p.Category, p.Subcategory, p.TxtDowntime,
				tsEvent, tsEnd, duration, p.CategoryDesc, p.SubcategoryDesc,
				p.CategoryCode, p.SubcategoryCode); err != nil {
				return fmt.Errorf("trim second: %w", err)
			}
		}
		// prod 30813/30814 write no user_log — verbatim.
	}
	h.events.Add(1)
	return tx.Commit(ctx)
}

func (h *Handler) writeUserLog(ctx context.Context, tx txExecer, schema string, info *sparkplug.EquipmentInfo, tsEvent time.Time, user, sub, desc string) error {
	if _, err := tx.Exec(ctx, fmt.Sprintf(ujUserLog, schema),
		tsEvent, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		user, sub, desc); err != nil {
		return fmt.Errorf("user log: %w", err)
	}
	return nil
}
