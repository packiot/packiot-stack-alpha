// Package events — ADR-0014 P3a: the equipment_events deriver for the
// shadow flows. SERVES status_type=4 EQUIPMENT ONLY (prod parity):
// C-PACK is status_type=0 — its events are pipeline-created (CPAC
// 30758=4) and reach the shadow flows via the mirror-worker event
// fan-out until the ADR-0010 10.4 port lands. Idle-by-correctness on
// a CPACK-only staging.
//
// Deriver ported from prod's piot_review_equipment_events()
// (ground truth: docs/adr/reference/captures/0014-p3-events-deriver-prod-funcs.sql).
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

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/caggsplit"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// Dest is one derivation destination — the shared flows.Dest.
type Dest = flows.Dest

// SCOPE ($3 = EVENTS_WIDEROW_STATE_ENTERPRISES, ADR-0031 Incoplast/ent4):
// the deriver's native scope is status_type=4 equipment (StateCurrent-driven,
// paired with BuildEventMint per the ADR-0014 P3a contract). A second class of
// tenant — the "wide-row state" tenants (e.g. Incoplast) — writes the `state`
// column directly into equipment_values via a wide-row tee and registers NO
// StateCurrent/Count LEAF topics in packml_register. For them BuildEventMint
// never fires (no KindStateCurrent metric resolves) AND they are status_type=0,
// so BOTH the per-sample minter and this deriver skip them → 0 equipment_events
// → no downtimes/availability/OEE. Because equipment_values already carries
// their `state` keyed by id_equipment (resolved from the row itself, no leaf
// topic needed), the SAME gaps-and-islands derivation mints correct
// interval events for them. We opt those enterprises in by id via $3, restricted
// to tp_equipment=1 MACHINES (lines aggregate from members — deriving line
// events from a wide-row would double-count, cf. the two-writer line bug). The
// widened scope is applied IDENTICALLY to the upsert (minter) and correct/delete
// (cleaner) passes so a minted OPEN event always has a cleaner in the same scope
// — never an orphan open row that running_time counts to now() (the int-overflow
// class from the EventMint↔deriver scope-mismatch bug).
// STREAM SOURCE (ADR-0063 B4, 2026-10-15): the per-second state stream is read from
// equipment_values directly, not from the ca_discrete_changes_1s cagg (27 s refresh
// every 15 min, 4.8 % of DB time, this deriver its only reader). It is the same
// stream: time_bucket('1 second') = date_trunc('second'); the bucket-start filter
// is kept exactly (the raw-time bound is only there for chunk exclusion); and rows
// with a NULL state are dropped because they only forward-fill the previous state
// and can never start a transition — so the same events come out under the SAME
// (id_equipment, ts_event) keys. Proven by deriver_raw_golden_test.go against the
// old cagg-based CTE.
const transitionsCTE = `
WITH stream AS (
    SELECT r.ts_event, r.id_equipment, r.id_enterprise, r.state,
           count(r.state) OVER (PARTITION BY r.id_equipment ORDER BY r.ts_event) AS grp
      FROM (SELECT DISTINCT date_trunc('second', ev.ts_value) AS ts_event, ev.id_equipment, ev.id_enterprise, ev.state
              FROM %[3]s.equipment_values ev
              JOIN %[2]s.equipments e ON e.id_equipment = ev.id_equipment
             WHERE ev.ts_value > now() - interval '25 hours' - interval '1 second'
               AND date_trunc('second', ev.ts_value) > now() - interval '25 hours'
               AND ev.state IS NOT NULL
               AND ((e.status_type = 4 AND e.tp_equipment > 0)
                    OR (e.id_enterprise = ANY($3) AND e.tp_equipment = 1))
               AND NOT (e.id_area = ANY($1)) AND NOT (e.id_enterprise = ANY($2))) r
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
INSERT INTO %[3]s.equipment_events (ts_event, ts_end, id_equipment, status, id_enterprise, duration)
SELECT ts_event, ts_end, id_equipment, status, id_enterprise, duration FROM final
ON CONFLICT (id_equipment, ts_event) DO UPDATE
   SET ts_end = EXCLUDED.ts_end, status = EXCLUDED.status, duration = EXCLUDED.duration`

const correctSQL = transitionsCTE + `
DELETE FROM %[3]s.equipment_events ev
 WHERE ev.ts_event > now() - interval '1 day'
   AND NOT ev.forced_creation_system
   AND ev.id_equipment IN (SELECT id_equipment FROM %[2]s.equipments
        WHERE ((status_type = 4 AND tp_equipment > 0)
               OR (id_enterprise = ANY($3) AND tp_equipment = 1))
          AND NOT (id_area = ANY($1)) AND NOT (id_enterprise = ANY($2)))
   AND NOT EXISTS (SELECT 1 FROM trans t
        WHERE t.id_equipment = ev.id_equipment
          AND t.ts_event = ev.ts_event AND t.status = ev.status)`

// correctSplitSQL / upsertSplitSQL: the two passes as a read planned as a SELECT
// plus the unchanged DELETE / INSERT (ADR-0063 A2, internal/caggsplit). The
// transitions CTE reads the REAL-TIME ca_discrete_changes_1s cagg, whose
// watermark TimescaleDB constifies only in a SELECT; inside the DELETE/INSERT it
// priced the raw tail of every chunk (staging 2026-10-14: 4.0 s mean, 48 s max,
// 5,033 s of DB time). The engine runs each as a caggsplit.Pass (session
// snapshot table, binary COPY — ADR-0063 A3) in its own transaction, as the single
// statement ran; RowsAffected is the apply's, so it still counts the deleted /
// upserted events. The *SplitSQL texts are the self-contained equivalents.
var (
	correctPass     = caggsplit.Spec{Temp: "der_trans_snap", Tail: "SELECT * FROM trans", Feeds: []string{"trans"}}.MustPass(correctSQL)
	upsertPass      = caggsplit.Spec{Temp: "der_final_snap", Tail: "SELECT * FROM final", Feeds: []string{"final"}}.MustPass(upsertSQL)
	correctSplitSQL = correctPass.SQL()
	upsertSplitSQL  = upsertPass.SQL()
)

// deriverPassFor renders p for d with the scope arrays inlined (COPY takes no
// bind parameters).
func deriverPassFor(d Dest, p caggsplit.Pass, exclAreas, exclEnterprises, widerowEnterprises []int) (caggsplit.Pass, error) {
	var inlineErr error
	p = p.Map(func(s string) string {
		out, err := caggsplit.InlineIntArrays(fmt.Sprintf(s, d.EvSchema, d.RefSchema, d.SilverSchema), exclAreas, exclEnterprises, widerowEnterprises)
		if err != nil {
			inlineErr = err
		}
		return out
	})
	return p, inlineErr
}

// runDeriverPass runs one rendered deriver pass in its own transaction.
func runDeriverPass(ctx context.Context, d Dest, p caggsplit.Pass, exclAreas, exclEnterprises, widerowEnterprises []int) (int64, error) {
	p, err := deriverPassFor(d, p, exclAreas, exclEnterprises, widerowEnterprises)
	if err != nil {
		return 0, err
	}
	var n int64
	err = pgx.BeginFunc(ctx, d.Pool, func(tx pgx.Tx) error {
		tag, err := p.Run(ctx, tx)
		n = tag.RowsAffected()
		return err
	})
	return n, err
}

// RunOnce derives events for one destination: correct, then upsert.
// widerowEnterprises ($3) opts extra enterprises' machines (tp=1) into the
// derivation for the wide-row-state tenants that carry no StateCurrent leaf
// topic — see the transitionsCTE scope note. Empty = native status_type=4 only.
func RunOnce(ctx context.Context, d Dest, exclAreas, exclEnterprises, widerowEnterprises []int) (deleted, upserted int64, err error) {
	del, err := runDeriverPass(ctx, d, correctPass, exclAreas, exclEnterprises, widerowEnterprises)
	if err != nil {
		return 0, 0, fmt.Errorf("correct pass: %w", err)
	}
	ups, err := runDeriverPass(ctx, d, upsertPass, exclAreas, exclEnterprises, widerowEnterprises)
	if err != nil {
		return del, 0, fmt.Errorf("upsert pass: %w", err)
	}
	return del, ups, nil
}

// Loop runs the deriver on a fixed cadence for every destination
// (prod's mega-proc ran the reviewer every minute). One tick = all
// destinations; per-destination failures are logged and the tick
// reports error if any destination failed.
func Loop(ctx context.Context, dests []Dest, exclAreas, exclEnterprises, widerowEnterprises []int, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("events deriver started (ADR-0014 P3a)",
		slog.Int("destinations", len(dests)), slog.Int("widerow_enterprises", len(widerowEnterprises)))
	jobs.Loop(ctx, jobs.Job{Name: "events-deriver", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			del, ups, err := RunOnce(ctx, d, exclAreas, exclEnterprises, widerowEnterprises)
			if err != nil {
				logger.Warn("deriver pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if del+ups > 0 {
				logger.Info("events derived", slog.String("dest", d.Name),
					slog.Int64("upserted", ups), slog.Int64("corrected", del))
			}
		}
		return firstErr
	}}, logger, obs)
}
