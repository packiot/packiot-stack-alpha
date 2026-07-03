// boxes_adapter.go — the label-adapter boxes pipeline (design:
// docs/adr/reference/0014-label-adapter-design.md). Replaces the
// per-customer boxes13.go: one pool table (customer_reports.boxes),
// per-tenant DESCRIPTOR rows (public.label_formats), two archetypes.
// Onboarding another scanner enterprise = one descriptor INSERT,
// zero code.
//
// Descriptor fields travel as SQL *parameters* into jsonb operators —
// a descriptor row cannot inject SQL. Raw analogs stay verbatim
// (prod parity); legacy per-customer tables are façade views over
// the pool.
package reports

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// LabelFormat is one tenant descriptor (public.label_formats row).
type LabelFormat struct {
	Enterprise                                                      int
	LabelKey, Archetype                                             string
	OrderField, QtyField, WorkcenterField, DateField, TimeField, TZ string
	Bucket                                                          string // counter archetype only
}

const loadFormatsSQL = `
	SELECT id_enterprise, label_key, archetype,
	       COALESCE(order_field,''), COALESCE(qty_field,''),
	       COALESCE(workcenter_field,''), COALESCE(date_field,''),
	       COALESCE(time_field,''), COALESCE(tz,'UTC'),
	       COALESCE(bucket::text,'')
	  FROM %[2]s.label_formats`

// delivery archetype: each label carries its own date + ISO-8601
// duration time (composed at the descriptor's tz) and workcenter.
// Verbatim generalization of upsert_equipment_boxes_cust_13.
const deliverySQL = `
	INSERT INTO customer_reports.boxes
	       (customer_id, label_key, ts_value, id_order, id_equipment, id_area, id_site, net_production, qty)
	WITH labels AS (
	    SELECT (jsonb_array_elements(analogs -> $1::text) ->> $2::text)                    AS ord,
	           (jsonb_array_elements(analogs -> $1::text) ->> $3::text)::double precision  AS qtyv,
	           (jsonb_array_elements(analogs -> $1::text) ->> $4::text)                    AS wc,
	           (jsonb_array_elements(analogs -> $1::text) ->> $5::text)                    AS dia,
	           (jsonb_array_elements(analogs -> $1::text) ->> $6::text)                    AS hora
	      FROM %[1]s.equipment_values
	     WHERE id_enterprise = $7 AND id_site = 0 AND id_area = 0 AND id_equipment = 0
	       AND analogs IS NOT NULL AND analogs ? $1::text
	       AND ts_value >= now() - interval '12 hour'
	)
	SELECT DISTINCT $7::int, $1::text,
	       ((regexp_replace(dia, 'T', ' '))::date +
	        regexp_replace(hora, '^PT(\d+)H(\d+)M(\d+)S$', '\1:\2:\3')::time) AT TIME ZONE $8::text,
	       ln.ord, eq.id_equipment, eq.id_area, eq.id_site, ln.qtyv, 1
	  FROM labels ln
	  LEFT JOIN %[2]s.equipments eq
	    ON eq.cd_equipment = ln.wc AND eq.id_enterprise = $7
	ON CONFLICT (customer_id, label_key, ts_value, id_order) DO UPDATE SET
	       id_equipment = EXCLUDED.id_equipment, id_area = EXCLUDED.id_area,
	       id_site = EXCLUDED.id_site, net_production = EXCLUDED.net_production,
	       qty = EXCLUDED.qty`

// counter archetype: the label rides the producing equipment's own
// row; bucket-aggregated (generalization of the ca_equipment_boxes
// shape). 12h re-window makes the upsert idempotent.
const counterSQL = `
	INSERT INTO customer_reports.boxes
	       (customer_id, label_key, ts_value, id_order, id_equipment, id_area, id_site, net_production, qty)
	SELECT $2::int, $1::text, time_bucket($3::interval, ts_value),
	       (analogs -> $1::text ->> $4::text),
	       id_equipment, id_area, id_site,
	       sum((analogs -> $1::text ->> $5::text)::double precision), count(*)
	  FROM %[1]s.equipment_values
	 WHERE id_enterprise = $2 AND analogs IS NOT NULL AND analogs ? $1::text
	   AND ts_value >= now() - interval '12 hour'
	 GROUP BY 3, 4, id_equipment, id_area, id_site
	ON CONFLICT (customer_id, label_key, ts_value, id_order) DO UPDATE SET
	       net_production = EXCLUDED.net_production, qty = EXCLUDED.qty`

// RunBoxes executes one pass for one destination: load descriptors,
// run each through its archetype.
func RunBoxes(ctx context.Context, d flows.Dest) (int64, error) {
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(loadFormatsSQL, d.EvSchema, d.RefSchema))
	if err != nil {
		return 0, fmt.Errorf("load label_formats: %w", err)
	}
	var formats []LabelFormat
	for rows.Next() {
		var f LabelFormat
		if err := rows.Scan(&f.Enterprise, &f.LabelKey, &f.Archetype,
			&f.OrderField, &f.QtyField, &f.WorkcenterField,
			&f.DateField, &f.TimeField, &f.TZ, &f.Bucket); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan label_format: %w", err)
		}
		formats = append(formats, f)
	}
	rows.Close()
	if rows.Err() != nil {
		return 0, rows.Err()
	}

	var total int64
	for _, f := range formats {
		var tag int64
		switch f.Archetype {
		case "delivery":
			t, err := d.Pool.Exec(ctx, fmt.Sprintf(deliverySQL, d.EvSchema, d.RefSchema),
				f.LabelKey, f.OrderField, f.QtyField, f.WorkcenterField,
				f.DateField, f.TimeField, f.Enterprise, f.TZ)
			if err != nil {
				return total, fmt.Errorf("delivery %d/%s: %w", f.Enterprise, f.LabelKey, err)
			}
			tag = t.RowsAffected()
		case "counter":
			t, err := d.Pool.Exec(ctx, fmt.Sprintf(counterSQL, d.EvSchema),
				f.LabelKey, f.Enterprise, f.Bucket, f.OrderField, f.QtyField)
			if err != nil {
				return total, fmt.Errorf("counter %d/%s: %w", f.Enterprise, f.LabelKey, err)
			}
			tag = t.RowsAffected()
		}
		total += tag
	}
	return total, nil
}

// LoopBoxes runs the adapter on the jobs runner for every destination.
func LoopBoxes(ctx context.Context, dests []flows.Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("boxes label-adapter started (descriptor-driven, ADR-0014)")
	jobs.Loop(ctx, jobs.Job{Name: "boxes", Every: every, Run: func(ctx context.Context) error {
		return jobs.RunPerDest(ctx, dests, "boxes", logger, func(ctx context.Context, d flows.Dest) (int64, error) {
			return RunBoxes(ctx, d)
		})
	}}, logger, obs)
}
