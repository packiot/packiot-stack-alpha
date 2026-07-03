// boxes13.go — ADR-0014 P4: the customer-13 (Neopac) box-scan
// aggregator, ported verbatim from upsert_equipment_boxes_cust_13
// (captured 2026-07-03, READ ONLY).
//
// THE BEEP CHAIN: the client's scanner posts label batches which land
// as analogs->'Label_Neopac' JSON arrays on a SENTINEL equipment_values
// row (id_enterprise=13, site/area/equipment = 0) — i.e. the ingest
// side is parameter 30850 (port 10.1, already live). This job shreds
// the JSONB: each label carries OrderID, GoodsReceiptQty, WorkCenter
// (→ equipments.cd_equipment), ActualDeliveryDate + ActualDeliveryTime
// (ISO-8601 duration PT#H#M#S!), composed at Europe/Zurich, upserted
// ON CONFLICT (ts_value, id_order).
//
// Cadence: prod cron unreadable (documented divergence) — the 12h
// re-scan window + upsert make any reasonable cadence output-
// equivalent. Default 5 min.
package reports

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// %[1]s = flow schema (equipment_values + equipment_boxes_cust_13);
// %[2]s = reference schema (equipments).
const boxes13SQL = `
	INSERT INTO %[1]s.equipment_boxes_cust_13
	       (ts_value, id_order, id_equipment, id_area, id_site, id_enterprise, net_production, qty)
	WITH labels_neopac AS (
	    SELECT ts_value,
	           (jsonb_array_elements(analogs->'Label_Neopac') ->> 'OrderID')::int          AS orderid,
	           (jsonb_array_elements(analogs->'Label_Neopac') ->> 'GoodsReceiptQty')::int  AS goodsreceiptqty,
	           (jsonb_array_elements(analogs->'Label_Neopac') ->> 'WorkCenter')            AS workcenter,
	           (jsonb_array_elements(analogs->'Label_Neopac') ->> 'ActualDeliveryDate')    AS dia,
	           (jsonb_array_elements(analogs->'Label_Neopac') ->> 'ActualDeliveryTime')    AS hora
	      FROM %[1]s.equipment_values
	     WHERE id_enterprise = 13 AND id_site = 0 AND id_area = 0 AND id_equipment = 0
	       AND analogs IS NOT NULL
	       AND ts_value >= now() - interval '12 hour'
	),
	final_data AS (
	    SELECT DISTINCT
	           ((regexp_replace(dia, 'T', ' '))::date +
	            regexp_replace(hora, '^PT(\d+)H(\d+)M(\d+)S$', '\1:\2:\3')::time)
	            AT TIME ZONE 'Europe/Zurich' AS ts_value,
	           ln.orderid::text AS id_order,
	           eq.id_equipment, eq.id_area, eq.id_site, eq.id_enterprise,
	           ln.goodsreceiptqty AS net_production,
	           1 AS qty
	      FROM labels_neopac ln
	      LEFT JOIN %[2]s.equipments eq
	        ON eq.cd_equipment = ln.workcenter AND eq.id_enterprise = 13
	)
	SELECT ts_value, id_order, id_equipment, id_area, id_site, id_enterprise, net_production, qty
	  FROM final_data
	ON CONFLICT (ts_value, id_order) DO UPDATE SET
	       id_equipment = EXCLUDED.id_equipment, id_area = EXCLUDED.id_area,
	       id_site = EXCLUDED.id_site, id_enterprise = EXCLUDED.id_enterprise,
	       net_production = EXCLUDED.net_production, qty = EXCLUDED.qty`

// RunBoxes13 executes one shred pass against one flow.
func RunBoxes13(ctx context.Context, pool *pgxpool.Pool, evSchema, refSchema string) (int64, error) {
	tag, err := pool.Exec(ctx, fmt.Sprintf(boxes13SQL, evSchema, refSchema))
	if err != nil {
		return 0, fmt.Errorf("boxes13 upsert: %w", err)
	}
	return tag.RowsAffected(), nil
}

// Boxes13Dest is one flow target.
type Boxes13Dest struct {
	Name      string
	Pool      *pgxpool.Pool
	EvSchema  string
	RefSchema string
}

// LoopBoxes13 runs the shred on the jobs runner for every destination.
func LoopBoxes13(ctx context.Context, dests []Boxes13Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("boxes13 writer started (ADR-0014 P4, the Neopac beep chain)")
	jobs.Loop(ctx, jobs.Job{Name: "boxes13", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			n, err := RunBoxes13(ctx, d.Pool, d.EvSchema, d.RefSchema)
			if err != nil {
				logger.Warn("boxes13 pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if n > 0 {
				logger.Info("boxes13 rows upserted", slog.String("dest", d.Name), slog.Int64("rows", n))
			}
		}
		return firstErr
	}}, logger, obs)
}
