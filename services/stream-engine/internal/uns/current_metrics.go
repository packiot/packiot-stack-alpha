// current_metrics.go — the equipment_live_metrics deriver: the
// frozen table's NEW MECHANISM (owner-approved 2026-07-07).
//
// WHY THIS EXISTS: public.equipment_live_metrics (one row per
// equipment: live state/speed/downtime snapshot for mission-control
// reads) FROZE on all flows after the 10.9 cutover. It was written at
// ingest by a writer keyed to AMQP routing key `sparkplug.uns_metrics`
// (internal/writers/uns_current_metrics.go via handlers/dispatcher.go),
// whose only producer was the retired legacy Node-RED leg — post-10.9
// the transformer publishes only `sparkplug.data`, so nothing ever hit
// that key again (F1 stale since ~07-06 14:00Z, F2/F3 since ~07-03).
// Decision: derive the table periodically in the engine instead — DB
// state has everything the writer had and more; prod's producer
// (oeecloud-node-red UNS flow + piot_proc_uns_equipment_refresh_
// current_metrics) retires at migration anyway, so this job becomes
// THE mechanism everywhere. Ships flag-off (UNS_CURRENT_METRICS_ENABLED
// default false), enabled at the flip.
//
// EQUIVALENCE ARGUMENT (per column, vs the ingest writer + prod's
// piot_proc_uns_equipment_refresh_current_metrics — found verbatim in
// edge-node-red/db/20-oee-engine-parity.sql):
//   - Scope: machines AND lines (equipments.tp_equipment IN (1,3))
//     that HAVE values (INNER lateral to the latest-values probe,
//     7-day lookback for chunk pruning). LINE LIVE-STATE (added
//     2026-08-10): a tp=3 line emits no raw equipment_values of its
//     own (it is an aggregate), so it never satisfied the INNER
//     values probe and its live-state row stayed frozen NULL → grey
//     mission-control tile. A line with a configured lead_machine now
//     resolves its signal SOURCE to that machine (sig_id, PackML param
//     30702) and inherits its state / speed / open-event / status
//     history — so the line shows its lead machine's live signal. A
//     machine, or a line with NO lead_machine, is its own source
//     (sig_id = id_equipment): behaviour is byte-identical to before,
//     making the change purely additive and gracefully no-op when
//     lead_machine is unset. Entities whose signal source is silent >7d keep
//     their old row untouched — same as the ingest writer (no data,
//     no update). Corrected 2026-07-08 to match the LIVE table, which
//     holds 46 machines + 20 lines, and prod's proc (which covers
//     lines). All enterprises processed — prod's proc hardcodes an
//     enterprise-exclusion list; staging excludes NONE (only 3
//     enterprises, all wanted), so empty is correct here. The prod
//     exclusion list is a Phase-F ENABLE-TIME config item
//     (UNS_CURRENT_METRICS_EXCLUDED_ENTERPRISES, never literals) —
//     wire it when this job runs against prod, not before.
//   - state / speed / updated_at: latest non-NULL state row + latest
//     non-NULL speed row + latest row overall (updated_at=ts_value).
//     Split laterals rather than one DISTINCT ON row because state
//     arrives only on StateCurrent samples and speed only on counter
//     samples — a single latest row would NULL one of them, which the
//     column-wise ingest upsert never did.
//   - status: prod's mapping, verbatim shape — state 6 → 'running'
//     when speed >= minimum_ideal_performance_threshold ·
//     production_speed else 'lowSpeed'; state 10 → 'changeOver' when
//     the open event has change_over else 'stopped'; other states →
//     NULL (prod maps nothing else).
//   - downtime_category/downtime_subcategory: open equipment_events
//     row (ts_end IS NULL, latest ts_event, 15-day guard = prod's).
//   - status_time: seconds since the open event's onset; when no open
//     event, since the latest state sample's ts; last resort the
//     latest value ts. APPROXIMATION: without an open event the true
//     state onset isn't tracked here — the latest StateCurrent sample
//     stands in for it.
//   - status_24h: last 24 HOURLY buckets' dominant state (mode() over
//     equipment_values.state per bucket) as text[], oldest→newest,
//     NULL for empty buckets. DIVERGENCE: prod stores a minute-grain
//     (~1440-entry) array of situation strings
//     (running/lowSpeed/changeOver/stopped); hourly dominant-state
//     ints-as-text is the owner-specified cheap form.
//   - 24h stop percentages: COUNT-based 0–1 fractions, matching prod
//     verbatim (edge-node-red/db/20-oee-engine-parity.sql:15520-15523:
//     count(*) FILTER by stop_type / nullif(sum of the three counts)).
//     change_over first, planned = planned_downtime AND NOT
//     change_over, unplanned = remainder. Corrected 2026-07-08 from
//     the earlier duration-weighted·100 form to prod parity.
//     APPROXIMATION remaining: prod counts minute-grain timeline rows;
//     this counts the equipment_events themselves (same BASIS =
//     count, same SCALE = 0–1; grain differs — verify against prod
//     rows at enable time).
//   - ideal_speed: equipments.ideal_speed::varchar. Prod's updater
//     for this column is commented out (dead) — this revives the
//     equipments-sourced value per owner spec.
//   - production_record_shifts: NOT derived here — untouched on
//     conflict (omitted from both column list and DO UPDATE). Prod's
//     high-water update (max(net) over equipment_oee_shift, only
//     ratchets up) stays with the legacy engine until it retires.
//   - last_updated = now().
//
// LEDGERED DIVERGENCE (bake board): freshness changes from ingest-time
// to job-cadence (default 1 minute).
//
// GUARDRAIL: one set-based UPSERT per destination; writes ONLY
// equipment_live_metrics, keyed by id_equipment.
package uns

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// %[1]s = EvSchema (flow tables), %[2]s = RefSchema (reference plane).
const currentMetricsSQL = `
	WITH machines AS (
	    -- sig_id = the entity's live-signal SOURCE. A LINE (tp=3) that
	    -- emits no raw equipment_values of its own inherits its
	    -- configured lead_machine's signal (ADR — PackML param 30702:
	    -- lead_machine is the machine that generates the line's events).
	    -- A machine (tp=1), or a line with NO lead_machine configured,
	    -- is its own source (sig_id = id_equipment) — behaviour is then
	    -- byte-identical to before, so this is purely additive. The
	    -- speed-classification config (ideal/production speed,
	    -- threshold) is taken from the signal source too so
	    -- running/lowSpeed stays coherent with the inherited speed,
	    -- COALESCEd back to the entity's own if the sig row is missing.
	    SELECT e.id_equipment, e.id_area, e.id_site, e.id_enterprise,
	           e.nm_equipment, a.nm_area, s.nm_site,
	           CASE WHEN e.tp_equipment = 3 AND e.lead_machine IS NOT NULL
	                THEN e.lead_machine ELSE e.id_equipment END AS sig_id,
	           COALESCE(sig.ideal_speed, e.ideal_speed) AS ideal_speed,
	           COALESCE(sig.production_speed, e.production_speed) AS production_speed,
	           COALESCE(sig.minimum_ideal_performance_threshold,
	                    e.minimum_ideal_performance_threshold) AS minimum_ideal_performance_threshold
	      FROM %[2]s.equipments e
	      JOIN %[2]s.areas a ON a.id_area = e.id_area
	      JOIN %[2]s.sites s ON s.id_site = e.id_site
	      LEFT JOIN %[2]s.equipments sig ON sig.id_equipment =
	           CASE WHEN e.tp_equipment = 3 AND e.lead_machine IS NOT NULL
	                THEN e.lead_machine ELSE e.id_equipment END
	     WHERE e.tp_equipment IN (1, 3)
	), latest AS (
	    SELECT m.*,
	           la.ts_value AS updated_at,
	           ls.state, ls.ts_value AS state_since,
	           lp.speed
	      FROM machines m
	      JOIN LATERAL (
	          SELECT v.ts_value FROM %[1]s.equipment_values v
	           WHERE v.id_equipment = m.sig_id
	             AND v.ts_value >= now() - interval '7 days'
	           ORDER BY v.ts_value DESC LIMIT 1) la ON true
	      LEFT JOIN LATERAL (
	          SELECT v.state, v.ts_value FROM %[1]s.equipment_values v
	           WHERE v.id_equipment = m.sig_id AND v.state IS NOT NULL
	             AND v.ts_value >= now() - interval '7 days'
	           ORDER BY v.ts_value DESC LIMIT 1) ls ON true
	      LEFT JOIN LATERAL (
	          SELECT v.speed FROM %[1]s.equipment_values v
	           WHERE v.id_equipment = m.sig_id AND v.speed IS NOT NULL
	             AND v.ts_value >= now() - interval '7 days'
	           ORDER BY v.ts_value DESC LIMIT 1) lp ON true
	), open_event AS (
	    -- keyed by the ENTITY (m.id_equipment) but sourced from the
	    -- signal equipment's events (m.sig_id) so a line inherits its
	    -- lead_machine's open downtime.
	    SELECT DISTINCT ON (m.id_equipment)
	           m.id_equipment, ee.ts_event, ee.cd_category, ee.cd_subcategory,
	           ee.change_over
	      FROM %[1]s.equipment_events ee
	      JOIN machines m ON m.sig_id = ee.id_equipment
	     WHERE ee.ts_end IS NULL
	       AND ee.ts_event >= now() - interval '15 days'
	     ORDER BY m.id_equipment, ee.ts_event DESC
	), stop_events AS (
	    SELECT m.id_equipment,
	           greatest(0, extract(epoch FROM
	               least(COALESCE(ee.ts_end, now()), now())
	             - greatest(ee.ts_event, now() - interval '24 hours')))::float8 AS dur,
	           COALESCE(ee.change_over, false)      AS change_over,
	           COALESCE(ee.planned_downtime, false) AS planned_downtime
	      FROM %[1]s.equipment_events ee
	      JOIN machines m ON m.sig_id = ee.id_equipment
	     WHERE ee.status IS DISTINCT FROM 6
	       AND ee.ts_event >= now() - interval '15 days'
	       AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now() + interval '60 seconds'))
	           && tstzrange(now() - interval '24 hours', now())
	), stops_24h AS (
	    -- prod parity: COUNT of events by stop_type, not duration
	    -- (20-oee-engine-parity.sql:15520-15523). dur retained only for
	    -- the 24h-window overlap filter upstream, not for the ratios.
	    SELECT id_equipment,
	           count(*) AS c_total,
	           count(*) FILTER (WHERE change_over) AS c_changeover,
	           count(*) FILTER (WHERE planned_downtime AND NOT change_over) AS c_planned
	      FROM stop_events
	     GROUP BY id_equipment
	), hours AS (
	    SELECT g AS bucket FROM generate_series(
	        date_trunc('hour', now()) - interval '23 hours',
	        date_trunc('hour', now()), interval '1 hour') g
	), status_hist AS (
	    SELECT m.id_equipment,
	           array_agg(hb.dominant_state::text ORDER BY h.bucket) AS status_24h
	      FROM machines m
	      CROSS JOIN hours h
	      LEFT JOIN LATERAL (
	          SELECT mode() WITHIN GROUP (ORDER BY v.state) AS dominant_state
	            FROM %[1]s.equipment_values v
	           WHERE v.id_equipment = m.sig_id
	             AND v.state IS NOT NULL
	             AND v.ts_value >= h.bucket
	             AND v.ts_value <  h.bucket + interval '1 hour') hb ON true
	     GROUP BY m.id_equipment
	)
	INSERT INTO %[1]s.equipment_live_metrics
	       (id_enterprise, id_site, id_area, id_equipment, state, speed, updated_at,
	        status, downtime_category, downtime_subcategory, status_time,
	        nm_equipment, nm_area, nm_site, status_24h, ideal_speed,
	        change_over_perc_stops_24h, planned_perc_stops_24h,
	        unplanned_perc_stops_24h, last_updated)
	SELECT l.id_enterprise, l.id_site, l.id_area, l.id_equipment,
	       l.state, l.speed, l.updated_at,
	       CASE l.state
	           WHEN 6  THEN CASE WHEN COALESCE(l.speed, 0.0)::float8 >=
	                                  (l.minimum_ideal_performance_threshold * l.production_speed::float8)
	                             THEN 'running' ELSE 'lowSpeed' END
	           WHEN 10 THEN CASE WHEN oe.change_over THEN 'changeOver' ELSE 'stopped' END
	           ELSE NULL
	       END,
	       oe.cd_category, oe.cd_subcategory,
	       extract(epoch FROM now() - COALESCE(oe.ts_event, l.state_since, l.updated_at))::int,
	       l.nm_equipment, l.nm_area, l.nm_site,
	       sh.status_24h,
	       l.ideal_speed::varchar,
	       COALESCE(st.c_changeover::float8 / NULLIF(st.c_total, 0), 0),
	       COALESCE(st.c_planned::float8    / NULLIF(st.c_total, 0), 0),
	       COALESCE((st.c_total - COALESCE(st.c_changeover, 0) - COALESCE(st.c_planned, 0))::float8
	                / NULLIF(st.c_total, 0), 0),
	       now()
	  FROM latest l
	  LEFT JOIN open_event  oe ON oe.id_equipment = l.id_equipment
	  LEFT JOIN stops_24h   st ON st.id_equipment = l.id_equipment
	  LEFT JOIN status_hist sh ON sh.id_equipment = l.id_equipment
	ON CONFLICT (id_equipment) DO UPDATE SET
	       id_enterprise = EXCLUDED.id_enterprise,
	       id_site       = EXCLUDED.id_site,
	       id_area       = EXCLUDED.id_area,
	       state         = EXCLUDED.state,
	       speed         = EXCLUDED.speed,
	       updated_at    = EXCLUDED.updated_at,
	       status        = EXCLUDED.status,
	       downtime_category    = EXCLUDED.downtime_category,
	       downtime_subcategory = EXCLUDED.downtime_subcategory,
	       status_time   = EXCLUDED.status_time,
	       nm_equipment  = EXCLUDED.nm_equipment,
	       nm_area       = EXCLUDED.nm_area,
	       nm_site       = EXCLUDED.nm_site,
	       status_24h    = EXCLUDED.status_24h,
	       ideal_speed   = EXCLUDED.ideal_speed,
	       change_over_perc_stops_24h = EXCLUDED.change_over_perc_stops_24h,
	       planned_perc_stops_24h     = EXCLUDED.planned_perc_stops_24h,
	       unplanned_perc_stops_24h   = EXCLUDED.unplanned_perc_stops_24h,
	       last_updated  = EXCLUDED.last_updated`

// RunCurrentMetrics executes one derivation pass for one destination.
func RunCurrentMetrics(ctx context.Context, d flows.Dest) (int64, error) {
	tag, err := d.Pool.Exec(ctx, fmt.Sprintf(currentMetricsSQL, d.EvSchema, d.RefSchema))
	if err != nil {
		return 0, fmt.Errorf("uns current-metrics: %w", err)
	}
	return tag.RowsAffected(), nil
}

// LoopCurrentMetrics schedules the deriver as its OWN job (not a
// piggyback on the uns-refresh cadence — freshness of the live-state
// snapshot is this table's whole contract).
func LoopCurrentMetrics(ctx context.Context, dests []flows.Dest, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("uns current-metrics deriver started (frozen-table replacement mechanism)")
	jobs.Loop(ctx, jobs.Job{Name: "uns-current-metrics", Every: every, Run: func(ctx context.Context) error {
		return jobs.RunPerDest(ctx, dests, "uns-current-metrics", logger, RunCurrentMetrics)
	}}, logger, obs)
}
