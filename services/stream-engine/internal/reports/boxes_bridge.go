// boxes_bridge.go — the box→production bridge, ported from prod's
// fn_update_packer_net_production_13_obd with the no-hardcoded-ids
// directive applied: prod baked 'TL117'/'Packer' into the function;
// here every bridge is a public.box_production_bridges DESCRIPTOR row
// (enterprise, source_cd, target_cd, label_key, bucket, lookback).
//
// Semantics (verbatim generalization): bucket the source equipment's
// box-scan net production (customer_reports.boxes pool — prod read
// the equipment_boxes_cust_13 slice, i.e. label_key='Label_Neopac'),
// upsert each bucket as the TARGET child equipment's
// net_production_incr (child = target_cd under parent source_cd).
package reports

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

const loadBridgesSQL = `
	SELECT id_enterprise, source_cd, target_cd, label_key,
	       bucket::text, lookback::text
	  FROM %[2]s.box_production_bridges`

const bridgeSQL = `
	WITH target_equipment AS (
	    SELECT child.id_equipment, child.id_enterprise, child.id_site, child.id_area
	      FROM %[2]s.equipments child
	      JOIN %[2]s.equipments parent ON parent.id_equipment = child.id_parentequipment
	     WHERE child.cd_equipment = $1 AND parent.cd_equipment = $2
	       AND child.id_enterprise = $3
	),
	prod_bucketed AS (
	    SELECT time_bucket($4::interval, b.ts_value) AS ts_value,
	           sum(b.net_production) AS net
	      FROM customer_reports.boxes b
	      JOIN %[2]s.equipments e ON e.id_equipment = b.id_equipment
	     WHERE b.customer_id = $3 AND b.label_key = $5
	       AND b.ts_value >= now() - $6::interval
	       AND e.cd_equipment = $2
	     GROUP BY 1
	)
	INSERT INTO %[1]s.equipment_values
	       (id_equipment, id_enterprise, id_site, id_area, ts_value, net_production_incr)
	SELECT te.id_equipment, te.id_enterprise, te.id_site, te.id_area, p.ts_value, p.net
	  FROM prod_bucketed p CROSS JOIN target_equipment te
	ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
	       net_production_incr = EXCLUDED.net_production_incr`

type bridge struct {
	Enterprise                   int
	SourceCd, TargetCd, LabelKey string
	Bucket, Lookback             string
}

// RunBoxesBridge executes every configured bridge for one destination.
func RunBoxesBridge(ctx context.Context, d flows.Dest) (int64, error) {
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(loadBridgesSQL, d.EvSchema, d.RefSchema))
	if err != nil {
		return 0, fmt.Errorf("load bridges: %w", err)
	}
	var bridges []bridge
	for rows.Next() {
		var b bridge
		if err := rows.Scan(&b.Enterprise, &b.SourceCd, &b.TargetCd, &b.LabelKey, &b.Bucket, &b.Lookback); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan bridge: %w", err)
		}
		bridges = append(bridges, b)
	}
	rows.Close()
	if rows.Err() != nil {
		return 0, rows.Err()
	}
	var total int64
	for _, b := range bridges {
		tag, err := d.Pool.Exec(ctx, fmt.Sprintf(bridgeSQL, d.EvSchema, d.RefSchema),
			b.TargetCd, b.SourceCd, b.Enterprise, b.Bucket, b.LabelKey, b.Lookback)
		if err != nil {
			return total, fmt.Errorf("bridge %d %s->%s: %w", b.Enterprise, b.SourceCd, b.TargetCd, err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// LoopBoxesBridge schedules the bridge on the jobs runner.
func LoopBoxesBridge(ctx context.Context, dests []flows.Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("boxes bridge started (descriptor-driven, obd port)")
	jobs.Loop(ctx, jobs.Job{Name: "boxes-bridge", Every: every, Run: func(ctx context.Context) error {
		return jobs.RunPerDest(ctx, dests, "boxes-bridge", logger, func(ctx context.Context, d flows.Dest) (int64, error) {
			return RunBoxesBridge(ctx, d)
		})
	}}, logger, obs)
}
