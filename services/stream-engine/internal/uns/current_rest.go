// current_rest.go — P3c slice 3: the remaining LIVE UNS refreshers,
// dispatcher-verified (piot_refresh_uns_areas runs the area tier;
// site analogues; the JOBS refresher is the _without_equipment_value
// generation called from the PO dispatcher — the 7.6KB plain _jobs is
// commented out = DEAD, fourth dead-generation catch).
//
// Verbatim notes:
//   - day (area/site): current-day runtime row → UNS day, end=+1day.
//   - month (area/site): current-month row + elapsed + proportional
//     target/ideal formulas (fraction of month elapsed) verbatim.
//   - week (area/site): joins equipments (tp=3) + shift-hour-list fn;
//     multi-line entities update the same UNS row LAST-WINS
//     (prod's UPDATE-from-join nondeterminism — kept verbatim).
//   - shift (area only — no site variant exists): current shift via
//     shift-hour-begin-by-area + PREVIOUS shift (ts_value = begin −
//     duration seconds) → prev1_* block + elapsed.
//   - jobs (equipment): running PO identity + numbers +
//     current_expected_time; elapsed from runtime ranges. VERBATIM
//     ODDITY KEPT: production_ordered is set from production_programmed.
//     Runs as the PO dispatcher's third step (compute → recalc → jobs).
package uns

import (
	"context"
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

const refreshDayEntitySQL = `
	WITH prod AS (
	    SELECT %[3]s, ts_value, net, gross, scrap,
	           oee, oee_p, oee_a, oee_q, available_time, running_time,
	           stopped_time, planned_downtime, ideal_production,
	           idle_time, idle_starved, idle_blocked, target, proportional_target
	      FROM %[1]s.%[4]s
	     WHERE ts_value >= date_trunc('day', now())::timestamptz AND ts_value <= now()
	)
	UPDATE %[1]s.%[5]s u SET
	       gross_production = p.gross, net_production = p.net, scrap = p.scrap,
	       begin_time = p.ts_value, end_time = p.ts_value + interval '1 day',
	       oee = p.oee, oee_p = p.oee_p, oee_a = p.oee_a, oee_q = p.oee_q,
	       available_time = p.available_time, running_time = p.running_time,
	       stopped_time = p.stopped_time, planned_downtime = p.planned_downtime,
	       ideal_production = p.ideal_production, idle_time = p.idle_time,
	       idle_starved = p.idle_starved, idle_blocked = p.idle_blocked,
	       target = p.target, proportional_target = p.proportional_target
	  FROM prod p WHERE u.%[3]s = p.%[3]s`

const refreshMonthEntitySQL = `
	WITH prod AS (
	    SELECT %[3]s, ts_value, net, gross, scrap,
	           oee, oee_a, oee_p, oee_q, available_time, running_time,
	           stopped_time, planned_downtime, ideal_production,
	           idle_time, idle_starved, idle_blocked, target,
	           extract(epoch FROM (now() - ts_value)) AS elapsed_time,
	           (target * extract(epoch FROM (now() - ts_value)))
	             / extract(epoch FROM ((date_trunc('month', now()) + interval '1 month') - date_trunc('month', now()))) AS proportional_target,
	           (ideal_production * extract(epoch FROM (now() - ts_value)))
	             / extract(epoch FROM ((date_trunc('month', now()) + interval '1 month') - date_trunc('month', now()))) AS proportional_ideal_production
	      FROM %[1]s.%[4]s
	     WHERE ts_value = date_trunc('month', now())::timestamptz
	)
	UPDATE %[1]s.%[5]s u SET
	       gross_production = p.gross, net_production = p.net, scrap = p.scrap,
	       oee = p.oee, oee_a = p.oee_a, oee_p = p.oee_p, oee_q = p.oee_q,
	       available_time = p.available_time, running_time = p.running_time,
	       stopped_time = p.stopped_time, planned_downtime = p.planned_downtime,
	       ideal_production = p.ideal_production, idle_time = p.idle_time,
	       idle_starved = p.idle_starved, idle_blocked = p.idle_blocked,
	       target = p.target, elapsed_time = p.elapsed_time,
	       proportional_target = p.proportional_target,
	       begin_time = p.ts_value,
	       end_time = date_trunc('month', now()) + interval '1 month'
	  FROM prod p WHERE u.%[3]s = p.%[3]s`

const refreshWeekEntitySQL = `
	WITH c AS (
	    SELECT erw.*, e.id_equipment, e.id_enterprise
	      FROM %[1]s.%[4]s erw
	      JOIN %[2]s.equipments e USING (%[3]s)
	      JOIN piot_get_shift_hour_list_by_equipment(e.id_enterprise, e.id_equipment) USING (%[3]s, id_equipment, id_enterprise)
	     WHERE erw.ts_value >= date_trunc('week', now())::date
	       AND erw.ts_value < date_trunc('week', now() + interval '1 week')::date
	       AND e.tp_equipment = 3
	)
	UPDATE %[1]s.%[5]s w SET
	       gross_production = c.gross, net_production = c.net, scrap = c.scrap,
	       begin_time = c.ts_value,
	       end_time = date_trunc('week', now() + interval '1 week'),
	       elapsed_time = (SELECT extract(epoch FROM now() - ts_value)
	                         FROM piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now()))),
	       target = c.target,
	       proportional_target = (SELECT c.target * (SELECT extract(epoch FROM now() - ts_value)
	               FROM piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now())))
	             / (SELECT sum(shift_size) FROM piot_get_shift_hour_list_by_equipment(c.id_enterprise, c.id_equipment))),
	       idle_time = c.idle_time, idle_blocked = c.idle_blocked, idle_starved = c.idle_starved,
	       running_time = c.running_time, stopped_time = c.stopped_time,
	       available_time = c.available_time, planned_downtime = c.planned_downtime,
	       ideal_production = c.ideal_production,
	       oee = c.oee, oee_a = c.oee_a, oee_p = c.oee_p, oee_q = c.oee_q
	  FROM c WHERE w.%[3]s = c.%[3]s`

const refreshShiftAreaSQL = `
	WITH ts AS (
	    SELECT id_area, ts_value FROM (
	        SELECT a.id_area,
	               (SELECT ts_begin FROM piot_get_shift_hour_begin_by_area(a.id_area, now())) AS ts_value
	          FROM %[2]s.areas a
	          JOIN %[2]s.enterprises et ON a.id_enterprise = et.id_enterprise AND et.active) s1
	     WHERE ts_value IS NOT NULL
	), prod AS (
	    SELECT v.id_area, v.ts_value, v.net, v.gross, v.scrap,
	           v.oee, v.oee_p, v.oee_a, v.oee_q, v.available_time, v.running_time,
	           v.stopped_time, v.planned_downtime, v.ideal_production,
	           v.idle_time, v.idle_starved, v.idle_blocked, v.target,
	           v.id_shift, v.id_shift_hour, v.ts_end, v.duration, v.proportional_target
	      FROM %[1]s.area_oee_shift v
	      JOIN ts ON v.id_area = ts.id_area AND v.ts_value = ts.ts_value
	), prod1 AS (
	    SELECT v.id_area, v.ts_value, v.net, v.gross, v.scrap,
	           v.oee, v.oee_a, v.oee_p, v.oee_q, v.target,
	           v.id_shift, v.id_shift_hour, v.ts_end, v.duration
	      FROM %[1]s.area_oee_shift v
	      JOIN ts ON v.id_area = ts.id_area
	       AND v.ts_value = ts.ts_value - (interval '1 second' * v.duration)
	)
	UPDATE %[1]s.area_live_shift u SET
	       gross_production = p.gross, net_production = p.net, scrap = p.scrap,
	       oee = p.oee, oee_p = p.oee_p, oee_a = p.oee_a, oee_q = p.oee_q,
	       available_time = p.available_time, running_time = p.running_time,
	       stopped_time = p.stopped_time, planned_downtime = p.planned_downtime,
	       ideal_production = p.ideal_production, idle_time = p.idle_time,
	       idle_starved = p.idle_starved, idle_blocked = p.idle_blocked,
	       target = p.target, id_shift = p.id_shift, id_shift_hour = p.id_shift_hour,
	       begin_time = p.ts_value, end_time = p.ts_end, duration = p.duration,
	       proportional_target = p.proportional_target,
	       prev1_oee = p1.oee, prev1_oee_a = p1.oee_a, prev1_oee_p = p1.oee_p,
	       prev1_oee_q = p1.oee_q, prev1_gross_production = p1.gross,
	       prev1_net_production = p1.net, prev1_scrap = p1.scrap,
	       prev1_target = p1.target, prev1_begin_time = p1.ts_value,
	       prev1_end_time = p1.ts_end, prev1_id_shift = p1.id_shift,
	       prev1_id_shift_hour = p1.id_shift_hour, prev1_duration = p1.duration,
	       elapsed_time = extract(epoch FROM (now() - p.ts_value))
	  FROM prod p JOIN prod1 p1 ON p.id_area = p1.id_area
	 WHERE u.id_area = p.id_area`

// The LIVE jobs refresher (dispatcher: _without_equipment_value gen).
// Stamps last_updated = now() (the equipment-grain freshness signal —
// see the hour/week/month note in uns.go); without it the current_job
// tile reads frozen at Provision-seed time even as its numbers advance.
const refreshJobsSQL = `
	WITH po AS (
	    SELECT po.id_production_order, po.id_order, po.net_production, po.gross_production,
	           (po.gross_production - po.net_production) AS scrap_incr, po.speed,
	           e.id_equipment, p.nm_product, pf.nm_product_family, c.nm_client,
	           po.production_programmed, po.ts_start,
	           COALESCE(po.ideal_production_speed, e.production_speed) AS ideal_production_speed
	      FROM %[2]s.equipments e
	      LEFT JOIN %[1]s.production_orders po ON e.id_equipment = po.id_equipment AND po.status = 2
	      LEFT JOIN %[2]s.products p ON po.id_product = p.id_product
	      LEFT JOIN %[2]s.product_families pf ON pf.id_product_family = p.id_product_family
	      LEFT JOIN %[2]s.clients c ON c.id_client = po.id_client
	     WHERE e.tp_equipment = 3
	)
	UPDATE %[1]s.equipment_live_job u SET
	       id_production_order = p.id_production_order, id_order = p.id_order,
	       nm_product = p.nm_product, nm_client = p.nm_client,
	       nm_product_family = p.nm_product_family,
	       gross_production = p.gross_production, net_production = p.net_production,
	       scrap = p.scrap_incr, speed = p.speed, target = p.production_programmed,
	       begin_time = p.ts_start, production_programmed = p.production_programmed,
	       production_ordered = p.production_programmed,
	       setup_speed = p.ideal_production_speed,
	       current_expected_time = (p.production_programmed - p.net_production) / p.ideal_production_speed * 60,
	       last_updated = now()
	  FROM po p WHERE u.id_equipment = p.id_equipment`

const refreshJobsElapsedSQL = `
	WITH po AS (
	    SELECT po.id_production_order, e.id_equipment
	      FROM %[2]s.equipments e
	      LEFT JOIN %[1]s.production_orders po ON e.id_equipment = po.id_equipment AND po.status = 2
	     WHERE e.tp_equipment = 3
	), po_time AS (
	    SELECT po.id_production_order, po.id_equipment,
	           sum(extract(epoch FROM (COALESCE(upper(runtime_timerange), now()) - lower(runtime_timerange)))) AS duration
	      FROM po
	      LEFT JOIN %[1]s.production_orders_runtime por ON po.id_production_order = por.id_production_order
	     GROUP BY 1, 2
	)
	UPDATE %[1]s.equipment_live_job u SET elapsed_time = p.duration
	  FROM po_time p WHERE u.id_equipment = p.id_equipment`

// RefreshCurrentRest runs the remaining live refreshers (day/week/
// month for area+site, shift for area).
func RefreshCurrentRest(ctx context.Context, d flows.Dest) error {
	type ent struct{ key, rtDay, unsDay, rtWeek, unsWeek, rtMonth, unsMonth string }
	ents := []ent{
		{"id_area", "area_oee_daily", "area_live_day", "area_oee_weekly", "area_live_week", "area_oee_monthly", "area_live_month"},
		{"id_site", "site_oee_daily", "site_live_day", "site_oee_weekly", "site_live_week", "site_oee_monthly", "site_live_month"},
	}
	for _, e := range ents {
		steps := []struct{ name, sql string }{
			{"day-" + e.key, fmt.Sprintf(refreshDayEntitySQL, d.EvSchema, d.RefSchema, e.key, e.rtDay, e.unsDay)},
			{"week-" + e.key, fmt.Sprintf(refreshWeekEntitySQL, d.EvSchema, d.RefSchema, e.key, e.rtWeek, e.unsWeek)},
			{"month-" + e.key, fmt.Sprintf(refreshMonthEntitySQL, d.EvSchema, d.RefSchema, e.key, e.rtMonth, e.unsMonth)},
		}
		for _, s := range steps {
			if _, err := d.Pool.Exec(ctx, s.sql); err != nil {
				return fmt.Errorf("uns %s: %w", s.name, err)
			}
		}
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(refreshShiftAreaSQL, d.EvSchema, d.RefSchema)); err != nil {
		return fmt.Errorf("uns shift-area: %w", err)
	}
	return nil
}

// RefreshCurrentJobs is the PO dispatcher's third step.
func RefreshCurrentJobs(ctx context.Context, d flows.Dest) error {
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(refreshJobsSQL, d.EvSchema, d.RefSchema)); err != nil {
		return fmt.Errorf("uns jobs: %w", err)
	}
	if _, err := d.Pool.Exec(ctx, fmt.Sprintf(refreshJobsElapsedSQL, d.EvSchema, d.RefSchema)); err != nil {
		return fmt.Errorf("uns jobs elapsed: %w", err)
	}
	return nil
}
