package reconcile

// events_sync.go — third reconciler in the mirror-worker.
//
// Existence (RunForever)      — closes the ~95% PO-creation gap from user_logs.
// Values   (RunValueSyncForever) — keeps CPACK counters prod-anchored.
// Events   (RunEventsSyncForever) — keeps staging equipment_events prod-anchored.
//
// Why this exists: PR #75 made the value-sync the sole writer of CPACK
// equipment_values. Those INSERTs deliberately leave state/mode/speed NULL
// (they're counter deltas, not PLC snapshots) — so staging's
// piot_set_event trigger pipeline that would normally derive
// equipment_events from state transitions never fires for CPACK
// equipment. Result by 2026-06-26: 28 of 32 DLQ rows are
// translate.EquipmentEvent failures with "no staging equipment_event
// with >=30s overlap" — because no candidate rows exist on staging at
// all for many of the 62 CPACK machines.
//
// Fix shape: directly mirror prod equipment_events to staging,
// 1:1 via mirror_id_map. The interval-overlap matcher becomes a no-op
// (cache hit path takes over) and operator-action replay (event-justified
// etc.) trivially resolves the prod id → staging id.
//
// Sole-writer invariant: this reconciler is the only writer of
// equipment_events for CPACK machines on staging. The simulator skips
// id_enterprise=3 (per PR #75) and the value-sync writes
// equipment_values only. If another writer appears (e.g., simulator
// re-enabled for CPACK), staging's piot_trig_equipment_events_update_prev
// trigger would dedup our rows away on prev_status match. We bypass that
// branch via forced_creation_system=true on every INSERT.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

// eventCursorSource is the mirror_replay_cursor.source value the events
// reconciler advances. Distinct from the user_logs source so the two
// replay loops don't trample each other's cursor.
//
// Built as <SourceName>-events to remain stable if a second mirror
// source is added later (e.g. azpack-prod-go-events).
func eventCursorSource(baseSourceName string) string {
	return baseSourceName + "-events"
}

// RunEventsSyncForever blocks until ctx is canceled. First pass fires
// immediately so a fresh worker doesn't wait IntervalSec before catching
// up on cold-start drift.
func (r *Reconciler) RunEventsSyncForever(ctx context.Context) error {
	if !r.cfg.ReconcileEventsEnabled {
		r.logger.Info("events sync disabled via RECONCILE_EVENTS_ENABLED=false")
		return nil
	}
	cursor, err := r.staging.EnsureEventCursor(ctx, eventCursorSource(r.cfg.SourceName))
	if err != nil {
		// Hard-fail at boot — without a cursor the loop can't safely run.
		return fmt.Errorf("seed event cursor: %w", err)
	}
	metrics.ReconcilerEventsCursor.Set(float64(cursor))

	interval := time.Duration(r.cfg.ReconcileEventsIntervalSec) * time.Second
	r.logger.Info("events sync starting",
		slog.Int("interval_sec", r.cfg.ReconcileEventsIntervalSec),
		slog.Int("batch_size", r.cfg.ReconcileEventsBatchSize),
		slog.Int64("cursor_at_boot", cursor),
	)
	for {
		if err := r.RunEventsSync(ctx); err != nil {
			r.logger.Warn("events sync tick failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			r.logger.Info("events sync stopping")
			return nil
		}
	}
}

// RunEventsSync executes one events-sync tick: read cursor, fetch new
// prod events, mirror each onto staging. Exported so an /admin endpoint
// can trigger an out-of-band sync later if needed.
//
// Per-row tx: each prod event is mirrored in its own staging tx (insert
// equipment_events + insert mirror_id_map atomically). Cursor advances
// once at the end of the batch to the highest prod_id processed,
// regardless of per-row outcome — otherwise an unmapped equipment would
// re-fetch every tick and starve forward progress.
func (r *Reconciler) RunEventsSync(ctx context.Context) error {
	start := time.Now()
	source := eventCursorSource(r.cfg.SourceName)
	cursor, err := r.staging.ReadCursor(ctx, source)
	if err != nil {
		return fmt.Errorf("read event cursor: %w", err)
	}
	prodEvents, err := r.prodDB.FetchNewEquipmentEvents(ctx, cursor, r.cfg.ProdEnterpriseID, r.cfg.ReconcileEventsBatchSize)
	if err != nil {
		return fmt.Errorf("fetch new prod equipment_events: %w", err)
	}
	// CLOSE-SWEEP runs BEFORE the empty-batch return: quiet streams
	// (cursor at head, few new events) are EXACTLY when events sit
	// observed-open — the silent `return nil` below would otherwise skip
	// the sweep on every quiet tick.
	//
	// task #63: the events cursor observes each prod event ONCE; at
	// real-time lag it is usually still OPEN → the fan-out upsert wrote
	// ts_end NULL and nothing ever revisited it. The OLD closer re-fanned
	// prod events bounded by (ts_event >= now()-48h AND id > cursor-400k) —
	// on prod's 2.45B-id space the 400k PK bound is even narrower than 48h,
	// so any close landing outside that window was NEVER re-fanned and the
	// shadow row stayed OPEN forever, inflating F2/F3 duration+availability
	// while row COUNT parity still passed. The sweep replaces that with a
	// SHADOW-DRIVEN reconciliation: select the tiny divergent-candidate set
	// FROM THE SHADOW (open at any age + recently-closed), point-look-up
	// prod's authoritative close, and re-upsert both planes. Cost is
	// O(divergent rows), not O(prod volume). See runEventCloseSweep.
	r.closerTick++
	if r.cfg.ReconcileEventsCloseSweepEnabled &&
		(r.closerTick-1)%int64(r.cfg.ReconcileEventsCloseSweepEveryNTicks) == 0 {
		if err := r.runEventCloseSweep(ctx); err != nil {
			r.logger.Warn("event close-sweep failed", slog.String("err", err.Error()))
		}
	}

	if len(prodEvents) == 0 {
		r.logger.Debug("events sync tick: no new prod events")
		return nil
	}

	var created, skipped, failed int
	maxID := cursor
	for _, ev := range prodEvents {
		outcome, err := r.ensureOneEvent(ctx, ev)
		switch {
		case errors.Is(err, errEventAlreadyMapped):
			skipped++
			metrics.ReconcilerEventsTotal.WithLabelValues("skipped").Inc()
		case errors.Is(err, errEventUnmappedEquipment):
			skipped++
			metrics.ReconcilerEventsTotal.WithLabelValues("skipped").Inc()
			r.logger.Warn("events sync: equipment unmapped, skipping prod event (cursor still advances)",
				slog.Int64("prod_event_id", ev.IDEquipmentEvent),
				slog.Int("prod_equipment_id", ev.IDEquipment))
		case err != nil:
			failed++
			metrics.ReconcilerEventsTotal.WithLabelValues("failed").Inc()
			r.logger.Warn("events sync: ensureOneEvent failed — cursor will still advance to keep forward progress",
				slog.Int64("prod_event_id", ev.IDEquipmentEvent),
				slog.Int("prod_equipment_id", ev.IDEquipment),
				slog.String("err", err.Error()))
		default:
			created++
			_ = outcome
			metrics.ReconcilerEventsTotal.WithLabelValues("created").Inc()
		}
		if ev.IDEquipmentEvent > maxID {
			maxID = ev.IDEquipmentEvent
		}
	}

	if maxID > cursor {
		if err := r.staging.AdvanceCursorPool(ctx, source, maxID); err != nil {
			return fmt.Errorf("advance event cursor: %w", err)
		}
		metrics.ReconcilerEventsCursor.Set(float64(maxID))
	}
	r.logger.Info("events sync tick complete",
		slog.Int64("cursor_from", cursor),
		slog.Int64("cursor_to", maxID),
		slog.Int("fetched", len(prodEvents)),
		slog.Int("created", created),
		slog.Int("skipped", skipped),
		slog.Int("failed", failed),
		slog.Duration("elapsed", time.Since(start)))
	return nil
}

// Sentinel errors for branch dispatch in RunEventsSync.
var (
	errEventAlreadyMapped     = errors.New("equipment_event already mapped")
	errEventUnmappedEquipment = errors.New("equipment unmapped on staging")
)

// ensureOneEvent does the insert + mapping round-trip for one prod
// equipment_event. Tx-per-row so a single bad row can't poison the batch.
//
// Outcome: returns nil if the row was newly mirrored; errEventAlreadyMapped
// if a mapping for the prod_id already exists (catches the cursor-was-reset
// case); errEventUnmappedEquipment if translate.Equipment can't resolve
// the staging equipment id (e.g., packml_register entry missing) — both
// sentinels treated as "skip + advance cursor" by the caller.
func (r *Reconciler) ensureOneEvent(ctx context.Context, ev db.ProdEquipmentEvent) (int64, error) {
	if _, found, err := r.staging.LookupMapping(ctx, "equipment_event", r.cfg.SourceName, ev.IDEquipmentEvent); err != nil {
		return 0, fmt.Errorf("lookup existing mapping: %w", err)
	} else if found {
		return 0, errEventAlreadyMapped
	}

	stagingEqID, err := r.trans.Equipment(ctx, ev.IDEquipment)
	if err != nil {
		// Bucket "unmapped" separately — it's recoverable (packml_register
		// might land later) — vs hard translation errors (prod DB hiccup).
		if errors.Is(err, translate.ErrUnmapped) {
			return 0, errEventUnmappedEquipment
		}
		return 0, fmt.Errorf("translate equipment: %w", err)
	}

	var stagingEventID int64
	if err := r.staging.WithTx(ctx, func(tx pgx.Tx) error {
		stagingID, err := db.InsertEquipmentEvent(ctx, tx, db.InsertEquipmentEventArgs{
			IDEquipment:         stagingEqID,
			IDEnterprise:        r.cfg.StagingEnterpriseID,
			TsEvent:             ev.TsEvent,
			TsEnd:               ev.TsEnd,
			Status:              ev.Status,
			TxtDowntimeNotes:    ev.TxtDowntimeNotes,
			Idle:                ev.Idle,
			Fault:               ev.Fault,
			CdMachine:           ev.CdMachine,
			CdCategory:          ev.CdCategory,
			CdSubcategory:       ev.CdSubcategory,
			ChangeOver:          ev.ChangeOver,
			PlannedDowntime:     ev.PlannedDowntime,
			Duration:            ev.Duration,
			DescCategory:        ev.DescCategory,
			DescSubcategory:     ev.DescSubcategory,
			CdCategoryClient:    ev.CdCategoryClient,
			CdSubcategoryClient: ev.CdSubcategoryClient,
			IgnoreCost:          ev.IgnoreCost,
		})
		if err != nil {
			return err
		}
		stagingEventID = stagingID
		// SourceLogID=0 marks this as a reconciler insert, not from a
		// user_log row — same convention the PO reconciler uses.
		return db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "equipment_event",
			Source:      r.cfg.SourceName,
			ProdID:      ev.IDEquipmentEvent,
			StagingID:   stagingEventID,
			SourceLogID: 0,
		})
	}); err != nil {
		return 0, err
	}
	// Shadow flows get the transition as a state-bearing value row —
	// the ADR-0014 deriver's input stream (no-op unless fan-out enabled).
	if ev.Status != nil {
		r.staging.FanoutStateRow(ctx, stagingEqID, r.cfg.StagingEnterpriseID, *ev.Status, ev.TsEvent)
	}
	r.staging.FanoutEventRow(ctx, stagingEqID, r.cfg.StagingEnterpriseID, ev.Status, ev.TsEvent, ev.TsEnd, ev.Duration)
	return stagingEventID, nil
}

// closeCorrection is one shadow row the sweep re-points at prod's
// authoritative close state. Applied IDENTICALLY to both shadow planes
// (F2 + F3) via FanoutEventRow, which is what keeps F2==F3.
type closeCorrection struct {
	StagingEqID int
	TsEvent     time.Time
	Status      *int
	TsEnd       *time.Time
	Duration    *int
}

// planCloseCorrections is the PURE decision core of the close-sweep,
// factored out so the regression tests can pin its behaviour without a DB
// (same pattern as computeOrphans / computeOEEDivergence). Inputs:
//
//   - candidates: divergent shadow rows (STAGING-id space), from
//     FetchShadowEventCloseCandidates.
//   - reverse:    stagingEqID → prodEqID (shadow is keyed on staging ids,
//     but prod is looked up by prod id).
//   - prodClose:  prod's authoritative close state, keyed by the natural
//     (prodEqID, ts_event).
//
// A candidate yields a correction ONLY when prod has an authoritative row
// for it AND that row is CLOSED (ts_end != nil). The two skips are the
// safety guarantees that make the sweep unable to mask a real stranding:
//
//   - equipment not resolvable to prod → skip (can't look prod up).
//   - prod row ABSENT                  → skip; never fabricate a close. If
//     the shadow row is a genuine strand it stays OPEN and visible.
//   - prod row still OPEN              → skip; the shadow open legitimately
//     matches prod — correcting would invent a close prod never made.
//
// F2==F3 is preserved by construction: one correction, applied to both
// planes with the same value.
func planCloseCorrections(
	candidates []db.ShadowEventKey,
	reverse map[int]int,
	prodClose map[db.ProdEventKey]db.ProdEventClose,
) []closeCorrection {
	out := make([]closeCorrection, 0, len(candidates))
	for _, c := range candidates {
		prodEq, ok := reverse[c.IDEquipment]
		if !ok {
			continue
		}
		auth, ok := prodClose[db.ProdEventKey{IDEquipment: prodEq, TsEvent: c.TsEvent}]
		if !ok {
			continue // no prod row — do NOT fabricate a close
		}
		if auth.TsEnd == nil {
			continue // prod still open — nothing to correct
		}
		out = append(out, closeCorrection{
			StagingEqID: c.IDEquipment,
			TsEvent:     c.TsEvent,
			Status:      auth.Status,
			TsEnd:       auth.TsEnd,
			Duration:    auth.Duration,
		})
	}
	return out
}

// buildReverseEquipmentMap inverts prod↔staging by enumerating prod's
// equipment set and forward-translating each via the battle-tested
// translate.Equipment (with all its deterministic-tie-break fixes). A
// hand-rolled inverse-topic path would be a second place for that logic to
// drift; reusing the forward translator is the robust choice. O(machines)
// (~62 for CPACK), run once per sweep.
//
// Collisions (two prod equipment collapsing to one staging equipment) are
// logged and first-wins deterministically (FetchEnterpriseEquipmentIDs
// returns ordered ids). A wrong prodEq only fails the ts_event point-lookup
// (yielding no correction) — it can never produce a WRONG close.
func (r *Reconciler) buildReverseEquipmentMap(ctx context.Context) (map[int]int, error) {
	prodEqIDs, err := r.prodDB.FetchEnterpriseEquipmentIDs(ctx, r.cfg.ProdEnterpriseID)
	if err != nil {
		return nil, err
	}
	reverse := make(map[int]int, len(prodEqIDs))
	for _, prodEq := range prodEqIDs {
		stagingEq, err := r.trans.Equipment(ctx, prodEq)
		if err != nil {
			// Unmapped (no staging packml_register) → its shadow candidates
			// simply won't resolve and stay visible. Not fatal to the sweep.
			continue
		}
		if existing, dup := reverse[stagingEq]; dup {
			if existing != prodEq {
				r.logger.Warn("event close-sweep: staging equipment maps from multiple prod equipment; keeping first",
					slog.Int("staging_eq", stagingEq),
					slog.Int("kept_prod_eq", existing),
					slog.Int("ignored_prod_eq", prodEq))
			}
			continue
		}
		reverse[stagingEq] = prodEq
	}
	return reverse, nil
}

// runEventCloseSweep is one shadow-driven close-reconciliation pass (task
// #63). Bounded by a hard ctx watchdog — the same discipline the old
// FetchRecentlyClosedEvents used, now covering the whole sweep (candidate
// fetch + reverse-map build + prod point-lookups + fan-out).
//
// Flow: shadow candidates (tiny, indexed) → reverse map → prod authority →
// pure planCloseCorrections → FanoutEventRow to BOTH planes (per-plane
// fail-soft inside execFanout, so a bad F3 write can't block F2).
func (r *Reconciler) runEventCloseSweep(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx,
		time.Duration(r.cfg.ReconcileEventsCloseSweepTimeoutSec)*time.Second)
	defer cancel()

	candidates, err := r.staging.FetchShadowEventCloseCandidates(ctx,
		r.cfg.StagingEnterpriseID,
		r.cfg.ReconcileEventsCloseSweepRecentHours,
		r.cfg.ReconcileEventsCloseSweepBatchSize)
	if err != nil {
		return fmt.Errorf("fetch shadow candidates: %w", err)
	}
	if len(candidates) == 0 {
		r.logger.Debug("event close-sweep: no candidates")
		return nil
	}

	reverse, err := r.buildReverseEquipmentMap(ctx)
	if err != nil {
		return fmt.Errorf("build reverse equipment map: %w", err)
	}

	keys := make([]db.ProdEventKey, 0, len(candidates))
	for _, c := range candidates {
		if prodEq, ok := reverse[c.IDEquipment]; ok {
			keys = append(keys, db.ProdEventKey{IDEquipment: prodEq, TsEvent: c.TsEvent})
		}
	}
	prodClose, err := r.prodDB.FetchEventCloseInfo(ctx, r.cfg.ProdEnterpriseID, keys)
	if err != nil {
		return fmt.Errorf("fetch prod close info: %w", err)
	}

	corrections := planCloseCorrections(candidates, reverse, prodClose)
	for _, cc := range corrections {
		// FanoutEventRow writes the identical value to F2 and F3 — the
		// (id_equipment, ts_event) ON CONFLICT DO UPDATE closes/corrects the
		// existing shadow row on each plane, converging F2==F3.
		r.staging.FanoutEventRow(ctx, cc.StagingEqID, r.cfg.StagingEnterpriseID,
			cc.Status, cc.TsEvent, cc.TsEnd, cc.Duration)
	}
	metrics.ReconcilerEventsTotal.WithLabelValues("reclosed").Add(float64(len(corrections)))
	r.logger.Info("event close-sweep pass",
		slog.Int("candidates", len(candidates)),
		slog.Int("resolved_keys", len(keys)),
		slog.Int("prod_authoritative", len(prodClose)),
		slog.Int("corrected", len(corrections)))
	return nil
}
