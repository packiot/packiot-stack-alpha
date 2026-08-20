// topology.go — ADR-0010 10.3 slice 2: parameter 30700 (line order
// config) + the 10.2 writes that share its enrichment chain.
//
// Captured semantics (0010-port-10-3-po-control-capture.txt):
// one 30700 message carries unit_order = ordered []id_unit for a line.
// Prod's three nodes (Prep select → mega-node line row → Build unit
// loop) collapse into ONE tx here — same statements, same order.
//
// GUARDRAIL NOTE (per 0010-po-tables-guardrail-audit.md): this slice
// touches equipment_values (dedup-key upserts — the (ts_value,
// id_equipment) unique) and packml_register (single-row UPDATE by
// topic). It does NOT touch the PO tables.
package pocontrol

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// HandlesTopology reports whether id belongs to slice 2.
func HandlesTopology(id int) bool { return id == 30700 }

const topoPackmlSeq = `UPDATE %[2]s.packml_register SET line_unit_seq = $1 WHERE packml_topic = $2`

// The line's own EV row: infeed/outfeed = first/last unit's equipment
// (resolved via the same packml subselect prod used).
const topoLineRow = `
	INSERT INTO %[1]s.equipment_values
	       (ts_value, id_enterprise, id_site, id_area, id_equipment,
	        id_equipment_line_infeed, id_equipment_line_outfeed)
	VALUES ($1, $2, $3, $4, $5,
	        (SELECT id_equipment FROM %[2]s.packml_register WHERE id_site = $3 AND id_unit = $6 GROUP BY id_equipment),
	        (SELECT id_equipment FROM %[2]s.packml_register WHERE id_site = $3 AND id_unit = $7 GROUP BY id_equipment))
	ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
	       id_equipment_line_infeed  = EXCLUDED.id_equipment_line_infeed,
	       id_equipment_line_outfeed = EXCLUDED.id_equipment_line_outfeed`

// Historical zeroing on the line row (mega-node variant: id_ columns).
const topoZeroLine = `
	UPDATE %[1]s.equipment_values
	   SET id_equipment_line_infeed = 0, id_equipment_line_outfeed = 0
	 WHERE ts_value < $1 AND id_equipment = $2
	   AND (id_equipment_line_infeed > 0 OR id_equipment_line_outfeed > 0)`

// One member row per unit; first/last get their is_ flag, everyone
// gets position (1-based). ON CONFLICT updates ONLY the connection —
// verbatim prod.
const topoMemberRow = `
	INSERT INTO %[1]s.equipment_values
	       (ts_value, id_enterprise, id_site, id_area, id_equipment,
	        id_equipment_line_connected, position_in_equipment_line,
	        is_equipment_line_infeed, is_equipment_line_outfeed)
	VALUES ($1, $2, $3, $4,
	        (SELECT id_equipment FROM %[2]s.packml_register WHERE id_site = $3 AND id_unit = $5 GROUP BY id_equipment),
	        $6, $7, $8, $9)
	ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
	       id_equipment_line_connected = EXCLUDED.id_equipment_line_connected`

// Historical zeroing on member rows (Build-node variant: is_ columns,
// keyed by connection).
const topoZeroMembers = `
	UPDATE %[1]s.equipment_values
	   SET is_equipment_line_infeed = 0, is_equipment_line_outfeed = 0
	 WHERE ts_value < $1 AND id_equipment_line_connected = $2
	   AND (is_equipment_line_infeed > 0 OR is_equipment_line_outfeed > 0)`

// refSchema: packml_register is REFERENCE-plane — it lives in public
// on both DBs (shadow_go_port shares the main DB's reference tables;
// packiot_shadow syncs its own copy into public). Same split as the
// events deriver's Dest{EvSchema, RefSchema}.
const refSchema = "public"

// executeTopology runs the 30700 unit in one tx. SQL templates take
// %[1]s = equipment_values schema, %[2]s = reference schema.
func (h *Handler) executeTopology(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	info, ok, err := h.resolveOrNoop(ctx, m)
	if err != nil || !ok {
		return err
	}
	var unitOrder []int64
	if err := json.Unmarshal(m.Value, &unitOrder); err != nil || len(unitOrder) == 0 {
		return fmt.Errorf("30700 unit_order must be a non-empty int array: %w", err)
	}
	ts := time.UnixMilli(m.Timestamp).Round(time.Second).UTC()

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	// line_unit_seq: prod stored JS array-to-string = comma-joined.
	seq := make([]string, len(unitOrder))
	for i, u := range unitOrder {
		seq[i] = fmt.Sprint(u)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(topoPackmlSeq, schema, refSchema),
		strings.Join(seq, ","), m.TopicForRegister()); err != nil {
		return fmt.Errorf("packml seq: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(topoLineRow, schema, refSchema),
		ts, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		unitOrder[0], unitOrder[len(unitOrder)-1]); err != nil {
		return fmt.Errorf("line row: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(topoZeroLine, schema, refSchema), ts, info.IDEquipment); err != nil {
		return fmt.Errorf("zero line: %w", err)
	}
	one := 1
	for i, unit := range unitOrder {
		// Prod omits the is_ columns for middle units → NULL (not 0).
		// Readers doing IS NULL checks must see identical shape.
		var infeed, outfeed *int
		if i == 0 {
			infeed = &one
		}
		if i == len(unitOrder)-1 {
			outfeed = &one
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf(topoMemberRow, schema, refSchema),
			ts, info.IDEnterprise, info.IDSite, info.IDArea,
			unit, info.IDEquipment, i+1, infeed, outfeed); err != nil {
			return fmt.Errorf("member row unit=%d: %w", unit, err)
		}
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(topoZeroMembers, schema, refSchema), ts, info.IDEquipment); err != nil {
		return fmt.Errorf("zero members: %w", err)
	}
	h.topology.Add(1)
	return tx.Commit(ctx)
}
