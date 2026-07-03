// Package uns — ADR-0014 P3c: the UNS current-family provisioner +
// the unblocked equipment refreshers (week, month), ported from
// piot_uns_upsert_features / piot_uns_equipment_refresh_current_week
// (+month). Design: docs/adr/reference/0014-p3c-uns-refresher-design.md.
//
// SLICE HONESTY: hour/day/shift(/jobs) refreshers read the RUNTIME
// family and are sequenced AFTER P3b; this package ships the
// CAgg-sourced grains only. The refreshers are UPDATE-only (prod
// semantics) — Provision creates the rows, exactly like prod's
// upsert_features (12-table matrix: equipment×7 + area×5; prod has
// NO site provisioning — faithful).
//
// Exclusion lists are the SAME disabled-customer config the events
// deriver uses (shared, not duplicated). Source mapping: prod reads
// ca_agg_equipment_values_1hour; the flows' adopted CAgg of the same
// bucket/columns is agg_equipment_values_1hour.
package uns

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/jobs"
)

// provisionMatrix mirrors piot_uns_upsert_features verbatim.
var provisionMatrix = []struct {
	unsTable, entityTable, idCol string
}{
	{"uns_equipment_current_day", "equipments", "id_equipment"},
	{"uns_equipment_current_hour", "equipments", "id_equipment"},
	{"uns_equipment_current_job", "equipments", "id_equipment"},
	{"uns_equipment_current_month", "equipments", "id_equipment"},
	{"uns_equipment_current_shift", "equipments", "id_equipment"},
	{"uns_equipment_current_week", "equipments", "id_equipment"},
	{"uns_area_current_day", "areas", "id_area"},
	{"uns_area_current_hour", "areas", "id_area"},
	{"uns_area_current_month", "areas", "id_area"},
	{"uns_area_current_shift", "areas", "id_area"},
	{"uns_area_current_week", "areas", "id_area"},
}

const provisionSQL = `INSERT INTO %[1]s.%[3]s (SELECT %[4]s FROM %[2]s.%[5]s) ON CONFLICT DO NOTHING`

// The metrics table gets the name-enriched upsert (verbatim).
const provisionMetricsSQL = `
	INSERT INTO %[1]s.uns_equipment_current_metrics
	       (id_equipment, id_area, id_site, id_enterprise, nm_equipment, nm_area, nm_site)
	SELECT e.id_equipment, e.id_area, e.id_site, e.id_enterprise, e.nm_equipment, a.nm_area, s.nm_site
	  FROM %[2]s.equipments e
	  JOIN %[2]s.areas a ON e.id_area = a.id_area
	  JOIN %[2]s.sites s ON e.id_site = s.id_site
	ON CONFLICT (id_equipment) DO UPDATE SET
	       id_area = EXCLUDED.id_area, id_site = EXCLUDED.id_site,
	       id_enterprise = EXCLUDED.id_enterprise, nm_equipment = EXCLUDED.nm_equipment,
	       nm_area = EXCLUDED.nm_area, nm_site = EXCLUDED.nm_site`

// Provision ports upsert_features for one destination.
func Provision(ctx context.Context, d flows.Dest) error {
	for _, m := range provisionMatrix {
		if _, err := d.Pool.Exec(ctx, fmt.Sprintf(provisionSQL,
			d.EvSchema, d.RefSchema, m.unsTable, m.idCol, m.entityTable)); err != nil {
			return fmt.Errorf("provision %s: %w", m.unsTable, err)
		}
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(provisionMetricsSQL, d.EvSchema, d.RefSchema)); err != nil {
		return fmt.Errorf("provision metrics: %w", err)
	}
	return nil
}

// equipmentGrains — the CAgg-sourced slice. date_trunc units and
// intervals are STATIC matrix entries (never user input).
var equipmentGrains = []struct {
	grain, unsTable, span string
}{
	{"week", "uns_equipment_current_week", "1 week"},
	{"month", "uns_equipment_current_month", "1 month"},
}

// Verbatim generalization of piot_uns_equipment_refresh_current_week:
// aggregate the 1hour CAgg since date_trunc(grain), UPDATE the current
// table. Exclusions ($1 areas, $2 enterprises) shared with the deriver.
const refreshEquipmentSQL = `
	WITH prod AS (
	    SELECT id_equipment, date_trunc('%[3]s', ts_value)::date AS ts_value,
	           sum(net_production_incr)   AS net_production_incr,
	           sum(gross_production_incr) AS gross_production_incr,
	           sum(scrap_incr)            AS scrap_incr,
	           avg(speed)                 AS speed
	      FROM %[1]s.agg_equipment_values_1hour v
	     WHERE ts_value >= date_trunc('%[3]s', now())::date
	       AND id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
	            WHERE tp_equipment > 1
	              AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))
	     GROUP BY id_equipment, date_trunc('%[3]s', ts_value)::date
	)
	UPDATE %[1]s.%[4]s u
	   SET gross_production = p.gross_production_incr,
	       net_production   = p.net_production_incr,
	       scrap            = p.scrap_incr,
	       speed            = p.speed,
	       begin_time       = p.ts_value,
	       end_time         = p.ts_value + interval '%[5]s'
	  FROM prod p
	 WHERE u.id_equipment = p.id_equipment`

// RefreshEquipment runs the CAgg-sourced grains for one destination.
func RefreshEquipment(ctx context.Context, d flows.Dest, exclAreas, exclEnterprises []int) error {
	for _, g := range equipmentGrains {
		if _, err := d.Pool.Exec(ctx, fmt.Sprintf(refreshEquipmentSQL,
			d.EvSchema, d.RefSchema, g.grain, g.unsTable, g.span),
			exclAreas, exclEnterprises); err != nil {
			return fmt.Errorf("refresh %s: %w", g.grain, err)
		}
	}
	return nil
}

// Loop schedules the refreshers; Provision runs on the FIRST tick and
// then hourly — running 12 ON CONFLICT probes every 5 minutes is pure
// index churn (the write-amplification cost the aggregates taxonomy
// warns about, eaten at home).
func Loop(ctx context.Context, dests []flows.Dest, exclAreas, exclEnterprises []int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("uns refresher started (P3c: provisioner + equipment week/month)")
	provisionEvery := int(time.Hour / every)
	if provisionEvery < 1 {
		provisionEvery = 1
	}
	tick := 0
	jobs.Loop(ctx, jobs.Job{Name: "uns-refresh", Every: every, Run: func(ctx context.Context) error {
		defer func() { tick++ }()
		var firstErr error
		for _, d := range dests {
			if tick%provisionEvery == 0 {
				if err := Provision(ctx, d); err != nil {
					logger.Warn("uns provision failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
					if firstErr == nil {
						firstErr = err
					}
					continue
				}
			}
			if err := RefreshEquipment(ctx, d, exclAreas, exclEnterprises); err != nil {
				logger.Warn("uns refresh failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
			}
		}
		return firstErr
	}}, logger, obs)
}
