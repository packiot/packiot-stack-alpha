// Package events — ADR-0014 P3a: the equipment_events deriver for the
// shadow flows, ported from prod's piot_review_equipment_events()
// (ground truth: docs/adr/reference/0014-p3-events-deriver-prod-funcs.sql).
//
// ARCHITECTURE NOTE: on prod, event CREATION happens in the Node-RED
// pipeline (direct INSERTs) and piot_review_* only CORRECTS. This port
// consolidates both roles into one job whose OUTPUT is equivalent: the
// upsert pass creates AND corrects transitions; the delete pass removes
// rows the recomputed stream no longer supports. The bake compares
// resulting rows against Flow 1, which is the honest equivalence test.
//
// PORT DECISIONS (each vs the prod body):
//   - gapfill(state) LOCF aggregate → standard gaps-and-islands
//     (count(state) OVER … as group id + first_value per group): zero
//     PL/pgSQL in the refactored DB.
//   - warmup: prod's rn > 10 runs on a GAPFILLED 1-second grid = skip
//     10 SECONDS. On our sparse sample stream that would skip 10 state
//     SAMPLES (live-caught: first enablement derived 0 rows). Replaced
//     with a time guard on the window's first 10s. 25h/1-day windows
//     verbatim.
//   - prod's hardcoded exclusions (id_area != 24, 15 enterprise ids)
//     → config (EVENTS_EXCLUDED_AREAS/ENTERPRISES) — they are disabled-
//     customer toggles, not algorithm.
//   - correction matches on (ts_event, id_equipment, status), NOT
//     ts_end: prod's tuple-compare included the moving open-end and is
//     race-prone; ts_end corrections converge via the upsert pass.
//     Documented divergence, output-convergent.
package events

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Dest is one derivation destination (flow schema + reference schema
// live in the same database as the pool they run against).
type Dest struct {
	Name      string // for logs: "shadow_go_port" | "packiot_shadow"
	Pool      *pgxpool.Pool
	EvSchema  string // where ca_discrete_changes_1s + equipment_events live
	RefSchema string // where equipments lives
}

const transitionsCTE = `
WITH stream AS (
    SELECT ca.ts_value AS ts_event, ca.id_equipment, ca.id_enterprise, ca.state,
           count(ca.state) OVER (PARTITION BY ca.id_equipment ORDER BY ca.ts_value) AS grp
      FROM %[1]s.ca_discrete_changes_1s ca
      JOIN %[2]s.equipments e ON e.id_equipment = ca.id_equipment AND e.status_type = 4
     WHERE ca.ts_value > now() - interval '25 hours'
       AND e.tp_equipment > 0
       AND NOT (e.id_area = ANY($1)) AND NOT (e.id_enterprise = ANY($2))
), filled AS (
    SELECT ts_event, id_equipment, id_enterprise,
           first_value(state) OVER (PARTITION BY id_equipment, grp ORDER BY ts_event) AS status
      FROM stream
), marked AS (
    SELECT ts_event, id_equipment, id_enterprise, status,
           lag(status)  OVER (PARTITION BY id_equipment ORDER BY ts_event) AS prev_status
      FROM filled
), trans AS (
    SELECT ts_event, id_equipment, id_enterprise, status
      FROM marked
     WHERE status <> prev_status
       AND ts_event >= now() - interval '25 hours' + interval '10 seconds'
), final AS (
    SELECT ts_event,
           lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS ts_end,
           id_equipment, status, id_enterprise,
           extract(epoch FROM (coalesce(lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event), now()) - ts_event)) AS duration
      FROM trans
)`

const upsertSQL = transitionsCTE + `
INSERT INTO %[1]s.equipment_events (ts_event, ts_end, id_equipment, status, id_enterprise, duration)
SELECT ts_event, ts_end, id_equipment, status, id_enterprise, duration FROM final
ON CONFLICT (id_equipment, ts_event) DO UPDATE
   SET ts_end = EXCLUDED.ts_end, status = EXCLUDED.status, duration = EXCLUDED.duration`

const correctSQL = transitionsCTE + `
DELETE FROM %[1]s.equipment_events ev
 WHERE ev.ts_event > now() - interval '1 day'
   AND NOT ev.forced_creation_system
   AND ev.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
        WHERE status_type = 4 AND tp_equipment > 0
          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))
   AND NOT EXISTS (SELECT 1 FROM trans t
        WHERE t.id_equipment = ev.id_equipment
          AND t.ts_event = ev.ts_event AND t.status = ev.status)`

// RunOnce derives events for one destination: correct, then upsert.
func RunOnce(ctx context.Context, d Dest, exclAreas, exclEnterprises []int) (deleted, upserted int64, err error) {
	del, err := d.Pool.Exec(ctx, fmt.Sprintf(correctSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises)
	if err != nil {
		return 0, 0, fmt.Errorf("correct pass: %w", err)
	}
	ups, err := d.Pool.Exec(ctx, fmt.Sprintf(upsertSQL, d.EvSchema, d.RefSchema), exclAreas, exclEnterprises)
	if err != nil {
		return del.RowsAffected(), 0, fmt.Errorf("upsert pass: %w", err)
	}
	return del.RowsAffected(), ups.RowsAffected(), nil
}

// Loop runs the deriver on a fixed cadence for every destination
// (prod's mega-proc ran the reviewer every minute).
func Loop(ctx context.Context, dests []Dest, exclAreas, exclEnterprises []int, every time.Duration, logger *slog.Logger) {
	t := time.NewTicker(every)
	defer t.Stop()
	logger.Info("events deriver started (ADR-0014 P3a)",
		slog.Int("destinations", len(dests)), slog.Duration("interval", every))
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for _, d := range dests {
				del, ups, err := RunOnce(ctx, d, exclAreas, exclEnterprises)
				if err != nil {
					logger.Warn("deriver pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
					continue
				}
				if del+ups > 0 {
					logger.Info("events derived", slog.String("dest", d.Name),
						slog.Int64("upserted", ups), slog.Int64("corrected", del))
				}
			}
		}
	}
}
