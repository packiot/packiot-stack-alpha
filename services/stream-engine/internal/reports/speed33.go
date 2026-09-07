// Package reports hosts the ADR-0014 Phase 4 / ADR-0012 Wave 2 ports of
// the per-customer report writers — Go owns scheduling, config and
// observability; the set-based SQL stays SQL (rewriting relational
// algebra in Go buys nothing — the PL/pgSQL *orchestration* is what
// ADR-0014 retires).
package reports

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// Speed33 ports prod's c33_speed_per_job_insert_into_report() procedure
// (captured verbatim in docs/adr/reference/captures/0012-wave2-prod-writer-funcs.sql)
// to the customer_reports.speed pool table. Semantics preserved 1:1 —
// line-level equipments (tp_equipment=3) of enterprise 33, last 5 days,
// speed >= 150, finished POs (status > 2), one row per new id_order —
// with two deliberate pool-shape changes:
//   - customer_id = $1 on every row (pool multi-tenancy column)
//   - the "already reported" dedupe reads the POOL slice, not the
//     legacy table, so the two writers converge independently during
//     the dual-run window
const speed33SQL = `
INSERT INTO customer_reports.speed(
    customer_id, id_equipment, id_order, id_product, production_programmed,
    production_final, avg_speed, final_net, job_start, product_type)
(WITH data AS (
    SELECT id_equipment, ts_value, speed, net_production_incr
    FROM equipment_values
    WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1 AND tp_equipment = 3)
    AND id_enterprise = $1
    AND ts_value >= NOW() - INTERVAL '5 day'
    AND speed >= 150
    AND net_production_val IS NOT NULL
    ORDER BY ts_value
), speed AS (
    SELECT po.id_equipment, po.id_order, po.id_product, po.production_programmed, po.production_final, po.ts_start AS job_start,
        CASE
            WHEN SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse('KG') in reverse(po.txt_production_order_description)))+2) = ''
            THEN SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse(' ') in reverse(po.txt_production_order_description)))+2)
            ELSE SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse('KG') in reverse(po.txt_production_order_description)))+2)
        END AS product_type,
        AVG(d.speed)::NUMERIC(4,1) AS avg_speed,
        SUM(d.net_production_incr)::BIGINT AS final_net,
        (SUM(d.net_production_incr) / po.production_final) AS indice
    FROM production_orders po
    JOIN data d ON po.id_equipment = d.id_equipment
    WHERE d.ts_value >= po.ts_start
    AND d.ts_value < po.ts_end
    AND po.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = $1 AND tp_equipment = 3)
    AND po.ts_start >= NOW() - INTERVAL '5 day'
    AND po.status > 2
    AND po.id_order NOT IN (SELECT id_order FROM customer_reports.speed WHERE customer_id = $1)
    GROUP BY po.id_equipment, po.id_order, po.id_product, po.production_programmed, po.production_final, po.ts_start, product_type
)
SELECT $1::int, id_equipment, id_order, id_product, production_programmed,
       production_final, avg_speed, final_net, job_start, product_type
FROM speed)`

// RunSpeed33 executes one pass. Returns rows inserted.
func RunSpeed33(ctx context.Context, pool *pgxpool.Pool, customerID int) (int64, error) {
	ct, err := pool.Exec(ctx, speed33SQL, customerID)
	if err != nil {
		return 0, err
	}
	return ct.RowsAffected(), nil
}

// LoopSpeed33 runs the writer on a fixed cadence until ctx cancels.
// Prod scheduled the legacy procedure via cron (schedule unreadable to
// awslambda — inferred warm: 1.8k lifetime inserts); 10 minutes is the
// staging-tuned default, configurable by the caller.
func LoopSpeed33(ctx context.Context, pool *pgxpool.Pool, customerID int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("speed33 report writer started (Wave 2 port #1)")
	jobs.Loop(ctx, jobs.Job{Name: "speed33", Every: every, Run: func(ctx context.Context) error {
		_, err := RunSpeed33(ctx, pool, customerID)
		return err
	}}, logger, obs)
}
