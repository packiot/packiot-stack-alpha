// Package translate maps prod entity IDs → staging entity IDs.
//
// Strategy by entity type:
//
//   enterprise   — hardcoded (prod CPACK=1 → staging CPACK=3); no lookup
//   site         — business key 'nm_site'
//   area         — business key 'nm_area'
//   equipment    — business key 'packml_topic' (canonical, post-remap)
//   PO           — mirror_id_map cache first, business key 'id_order' fallback
//   event        — TODO phase 2 — mirror_id_map cache first, interval-overlap fallback (A4b)
//
// Mirrors the TS translate.ts faithfully.
package translate

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

type Translator struct {
	prod    *db.Prod
	staging *db.Staging
	cfg     *config.Config
	logger  *slog.Logger
}

func New(prod *db.Prod, staging *db.Staging, cfg *config.Config, logger *slog.Logger) *Translator {
	return &Translator{prod: prod, staging: staging, cfg: cfg, logger: logger}
}

// ErrUnmapped — translation target absent on staging. Caller writes to
// DLQ rather than retrying forever.
var ErrUnmapped = errors.New("entity unmapped on staging")

// RemapTopic: prod's 'C-PACK/' prefix → staging's 'CPACK/'.
//
// Exported so handlers that need to forward a topic string verbatim (e.g.
// downtime-event-created carries the SparkPlug topic alongside idEquipment
// in its payload) can use the same canonical mapping that Equipment() uses
// to look up packml_register rows.
func RemapTopic(prodTopic string) string {
	return strings.Replace(prodTopic, "C-PACK/", "CPACK/", 1)
}

func (t *Translator) Enterprise(prodID int) (int, error) {
	if prodID != t.cfg.ProdEnterpriseID {
		return 0, fmt.Errorf("unexpected prod enterprise %d, only %d is mirrored",
			prodID, t.cfg.ProdEnterpriseID)
	}
	return t.cfg.StagingEnterpriseID, nil
}

func (t *Translator) Site(ctx context.Context, prodSiteID int) (int, error) {
	var nmSite string
	found, err := t.prod.SelectOne(ctx,
		`SELECT nm_site FROM sites WHERE id_site = $1 AND id_enterprise = $2`,
		[]any{prodSiteID, t.cfg.ProdEnterpriseID}, &nmSite)
	if err != nil {
		return 0, fmt.Errorf("prod site lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod site row for id_site=%d: %w", prodSiteID, ErrUnmapped)
	}
	var stagingID int
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_site FROM sites WHERE nm_site = $1 AND id_enterprise = $2`,
		[]any{nmSite, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging site lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging site with nm_site=%q: %w", nmSite, ErrUnmapped)
	}
	return stagingID, nil
}

func (t *Translator) Area(ctx context.Context, prodAreaID int) (int, error) {
	var nmArea string
	found, err := t.prod.SelectOne(ctx,
		`SELECT nm_area FROM areas WHERE id_area = $1 AND id_enterprise = $2`,
		[]any{prodAreaID, t.cfg.ProdEnterpriseID}, &nmArea)
	if err != nil {
		return 0, fmt.Errorf("prod area lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod area row for id_area=%d: %w", prodAreaID, ErrUnmapped)
	}
	var stagingID int
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_area FROM areas WHERE nm_area = $1 AND id_enterprise = $2`,
		[]any{nmArea, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging area lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging area with nm_area=%q: %w", nmArea, ErrUnmapped)
	}
	return stagingID, nil
}

// Equipment resolves prod equipment_id → staging via packml_topic.
//
// Deterministic tie-break (2026-06-29): an equipment can have several
// packml_register rows — one per metric — and the canonical "this is the
// equipment" topic is the shortest one (e.g. `C-PACK/SC/LINHAS/L4/TEXA`);
// the rest extend it with `/Admin/...` or `/Status/...` segments. The
// original `ORDER BY active DESC NULLS LAST LIMIT 1` was non-deterministic
// when several rows tied on `active=true` — Postgres returned whichever
// physical row it scanned first, an order that can shift with vacuum,
// index rebuild, or pg version. Prod equipment 84 (TEXA) tripped the
// worst case: 4 of its 7 active rows carry a literal `LLLLL` typo
// prefix on the topic, and the implementation-defined tie-break
// happened to pick one of the corrupted ones. After RemapTopic that
// became `LLLLLCPACK/...`, which has no staging match — events for
// TEXA were silently skipped by the events-reconciler (~3 WARN/min
// in production, surfaced via the unmapped-equipment log path).
// Sorting by `length(packml_topic) ASC` selects the canonical short
// topic; `id_packml_register ASC` makes the result fully deterministic
// when two clean topics happen to share a length. Industry rule:
// any `LIMIT 1` whose `ORDER BY` doesn't end in a unique column is a
// latent bug — it works until physical row order shifts.
func (t *Translator) Equipment(ctx context.Context, prodEquipmentID int) (int, error) {
	var prodTopic string
	found, err := t.prod.SelectOne(ctx,
		`SELECT pr.packml_topic FROM packml_register pr
		  WHERE pr.id_equipment = $1 AND pr.id_enterprise = $2
		  ORDER BY pr.active DESC NULLS LAST,
		           length(pr.packml_topic) ASC,
		           pr.id_packml_register ASC
		  LIMIT 1`,
		[]any{prodEquipmentID, t.cfg.ProdEnterpriseID}, &prodTopic)
	if err != nil {
		return 0, fmt.Errorf("prod packml_register lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod packml_register row for id_equipment=%d: %w",
			prodEquipmentID, ErrUnmapped)
	}
	stagingTopic := RemapTopic(prodTopic)
	var stagingID int
	// Staging side: exact-match on packml_topic already returns at most
	// one row per enterprise today, but the same deterministic tail
	// guards against a future migration ever landing two active rows
	// for the same (topic, enterprise).
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_equipment FROM packml_register
		  WHERE packml_topic = $1 AND id_enterprise = $2
		  ORDER BY active DESC NULLS LAST,
		           id_packml_register ASC
		  LIMIT 1`,
		[]any{stagingTopic, t.cfg.StagingEnterpriseID}, &stagingID)
	if err != nil {
		return 0, fmt.Errorf("staging packml_register lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no staging packml_register row for topic=%q (remapped from %q): %w",
			stagingTopic, prodTopic, ErrUnmapped)
	}
	return stagingID, nil
}

// ProductionOrder: cache first, business-key fallback on id_order.
//
// Prod's production_orders table has NO column called nu_production_order.
// The human PO number is id_order (integer, unique per id_enterprise — see
// production_orders_un unique constraint on prod). The TS worker's first
// revision referenced nu_production_order and that string got ported verbatim
// into this Go file. DLQ showed: column "nu_production_order" does not exist
// (SQLSTATE 42703), from this exact code path.
//
// Claimed-staging-PO guard (2026-06-26): the business-key fallback excludes
// staging POs already mapped to a DIFFERENT prod PO via mirror_id_map. On
// prod, a single id_order can be reused across multiple id_production_order
// rows (operator changes the order's qty mid-run → new id_production_order
// with the SAME id_order). The mirror only ever maps the FIRST prod PO that
// the worker observes for that id_order (whichever order-created /
// order-replaced fires first). When a later prod PO with the same id_order
// asks the translator for its staging counterpart, the un-guarded fallback
// returned the already-claimed staging PO — leading to wrong /stop calls
// on the wrong staging PO and 500s in DLQ (session 68: 4 stuck order-changed
// rows). The guard returns ErrUnmapped instead, which the handlers wrap as
// ErrSkipReplay → outcome=skipped, cursor advances, no DLQ.
func (t *Translator) ProductionOrder(ctx context.Context, prodPOID int64) (int64, error) {
	stagingID, found, err := t.staging.LookupMapping(ctx, "production_order", t.cfg.SourceName, prodPOID)
	if err != nil {
		return 0, fmt.Errorf("mapping lookup: %w", err)
	}
	if found {
		return stagingID, nil
	}
	var idOrder int
	found, err = t.prod.SelectOne(ctx,
		`SELECT id_order FROM production_orders
		  WHERE id_production_order = $1 AND id_enterprise = $2`,
		[]any{prodPOID, t.cfg.ProdEnterpriseID}, &idOrder)
	if err != nil {
		return 0, fmt.Errorf("prod PO lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod PO row for id_production_order=%d: %w", prodPOID, ErrUnmapped)
	}
	var sid int64
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_production_order FROM production_orders
		  WHERE id_order = $1 AND id_enterprise = $2
		    AND id_production_order NOT IN (
		      SELECT staging_id FROM mirror_id_map
		       WHERE entity_type = 'production_order'
		         AND source = $3
		    )
		  ORDER BY id_production_order DESC LIMIT 1`,
		[]any{idOrder, t.cfg.StagingEnterpriseID, t.cfg.SourceName}, &sid)
	if err != nil {
		return 0, fmt.Errorf("staging PO lookup: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no unclaimed staging PO with id_order=%d (all candidates already mapped to other prod POs): %w", idOrder, ErrUnmapped)
	}
	return sid, nil
}

// EquipmentEvent: cached mapping → interval-overlap business key.
//
// Phase A4b finding: prod and staging produce STRUCTURALLY DIFFERENT
// equipment_events from the same SparkPlug stream. Prod runs CPAC 5-min
// smoothing + writes operator metadata (cd_machine, cd_category) back into
// the row, so prod events are minute-aligned, fewer, and shorter. Staging
// has the raw PLC transitions — precise-to-the-second, more events,
// longer durations. ts_event proximity therefore can't match — interval
// overlap can.
//
// For prod event [t1, t2] with status S on equipment E:
//
//	pick the staging event with same (E, S) whose interval [s1, s2]
//	has the largest overlap with [t1, t2], requiring at least
//	cfg.EventMinOverlapSec of overlap to count as a match.
//
// Staging events without ts_end (still running) treat ts_end as now().
// First match gets cached in mirror_id_map so subsequent ops on the same
// prod event (event-edited, event-splitted) skip the SELECT.
func (t *Translator) EquipmentEvent(ctx context.Context, prodEventID int64) (int64, error) {
	mapped, found, err := t.staging.LookupMapping(ctx, "equipment_event", t.cfg.SourceName, prodEventID)
	if err != nil {
		return 0, fmt.Errorf("mapping lookup: %w", err)
	}
	if found {
		return mapped, nil
	}

	var (
		prodEqID  int
		prodStart time.Time
		prodEnd   sql.NullTime
		prodStat  int
	)
	found, err = t.prod.SelectOne(ctx,
		`SELECT id_equipment, ts_event, ts_end, status
		   FROM equipment_events
		  WHERE id_equipment_event = $1 AND id_enterprise = $2`,
		[]any{prodEventID, t.cfg.ProdEnterpriseID},
		&prodEqID, &prodStart, &prodEnd, &prodStat)
	if err != nil {
		return 0, fmt.Errorf("prod equipment_event read: %w", err)
	}
	if !found {
		return 0, fmt.Errorf("no prod equipment_event %d: %w", prodEventID, ErrUnmapped)
	}

	stagingEqID, err := t.Equipment(ctx, prodEqID)
	if err != nil {
		return 0, fmt.Errorf("translate equipment for event lookup: %w", err)
	}

	// Effective prod end — if prod event still running, cap at now().
	prodEndEffective := time.Now().UTC()
	if prodEnd.Valid {
		prodEndEffective = prodEnd.Time
	}

	var (
		stagingEventIDStr string
		overlapSec        int
	)
	// The `ts_event >= $3 - $6 sec` lower bound rejects stale open-ended
	// staging events that started long before the prod event. Without it,
	// any open (ts_end IS NULL) staging event from days ago "overlaps"
	// every later prod event via COALESCE(ts_end, now()) — DLQ ids 259,
	// 283 hit exactly this shape (staging event 1-2 days older, still
	// open, picked as the "best overlap" for unrelated prod events).
	found, err = t.staging.SelectOne(ctx,
		`SELECT id_equipment_event::text,
		        extract(epoch FROM (
		          LEAST(COALESCE(ts_end, now()), $4::timestamptz)
		          - GREATEST(ts_event, $3::timestamptz)
		        ))::int AS overlap_seconds
		   FROM equipment_events
		  WHERE id_equipment = $1
		    AND id_enterprise = $2
		    AND status = $5
		    AND ts_event < $4::timestamptz
		    AND ts_event >= $3::timestamptz - ($6::int * interval '1 second')
		    AND (ts_end IS NULL OR ts_end > $3::timestamptz)
		  ORDER BY overlap_seconds DESC
		  LIMIT 1`,
		[]any{stagingEqID, t.cfg.StagingEnterpriseID, prodStart, prodEndEffective, prodStat, t.cfg.EventMaxStartDriftSec},
		&stagingEventIDStr, &overlapSec)
	if err != nil {
		return 0, fmt.Errorf("staging interval-overlap lookup: %w", err)
	}
	if found && overlapSec >= t.cfg.EventMinOverlapSec {
		stagingID, parseErr := strconv.ParseInt(stagingEventIDStr, 10, 64)
		if parseErr != nil {
			return 0, fmt.Errorf("parse staging event id: %w", parseErr)
		}
		t.logger.Debug("equipment_event interval-overlap match",
			slog.Int64("prodEventID", prodEventID),
			slog.Int64("stagingEventID", stagingID),
			slog.Int("overlapSeconds", overlapSec))
		return stagingID, nil
	}

	// Diagnostic: closest same-status staging event by midpoint distance,
	// within ±1h window — tells us whether the structural mismatch is "no
	// event at all in the area" or "events but with insufficient overlap".
	// Different fixes apply to each.
	var (
		closestIDStr        string
		closestOverlapSec   int
		closestDriftSec     int
	)
	closestFound, _ := t.staging.SelectOne(ctx,
		`WITH prod_range AS (
		   SELECT $3::timestamptz AS p_start, $4::timestamptz AS p_end
		 )
		 SELECT id_equipment_event::text,
		        extract(epoch FROM (
		          LEAST(COALESCE(ts_end, now()), p_end)
		          - GREATEST(ts_event, p_start)
		        ))::int AS overlap_seconds,
		        extract(epoch FROM abs(ts_event - p_start))::int AS drift_seconds
		   FROM equipment_events, prod_range
		  WHERE id_equipment = $1
		    AND id_enterprise = $2
		    AND status = $5
		    AND ts_event BETWEEN p_start - interval '1 hour'
		                     AND p_end   + interval '1 hour'
		  ORDER BY drift_seconds ASC
		  LIMIT 1`,
		[]any{stagingEqID, t.cfg.StagingEnterpriseID, prodStart, prodEndEffective, prodStat},
		&closestIDStr, &closestOverlapSec, &closestDriftSec)

	attrs := []any{
		slog.Int64("prodEventID", prodEventID),
		slog.Int("stagingEquipmentID", stagingEqID),
		slog.Time("prodStart", prodStart),
		slog.Time("prodEnd", prodEndEffective),
		slog.Int("prodStatus", prodStat),
		slog.Int("minOverlapSec", t.cfg.EventMinOverlapSec),
		slog.Int("maxStartDriftSec", t.cfg.EventMaxStartDriftSec),
	}
	if found {
		attrs = append(attrs, slog.Int("candidateOverlapSec", overlapSec))
	}
	if closestFound {
		attrs = append(attrs,
			slog.String("closestEventID", closestIDStr),
			slog.Int("closestDriftSec", closestDriftSec),
			slog.Int("closestOverlapSec", closestOverlapSec))
	}
	t.logger.Warn("no equipment_event interval-overlap match (closest same-status candidate noted)", attrs...)
	return 0, fmt.Errorf("no staging equipment_event with >=%ds overlap for prod event %d: %w",
		t.cfg.EventMinOverlapSec, prodEventID, ErrUnmapped)
}

// EquipmentEventBoundaries returns the staging event's ts_event and ts_end.
// Handlers use this after EquipmentEvent translation to align operator-
// supplied payload timestamps to staging's actual boundaries — prod and
// staging detect the same physical event at slightly different times due
// to CPAC 5-min smoothing on prod and raw PLC transitions on staging.
// Without alignment, split.service.ts's strict-equality check
// (originalEvent.ts_event === events[0].startTime) 400s on legitimate splits.
func (t *Translator) EquipmentEventBoundaries(ctx context.Context, stagingEventID int64) (time.Time, sql.NullTime, error) {
	var tsEvent time.Time
	var tsEnd sql.NullTime
	found, err := t.staging.SelectOne(ctx,
		`SELECT ts_event, ts_end FROM equipment_events WHERE id_equipment_event = $1`,
		[]any{stagingEventID}, &tsEvent, &tsEnd)
	if err != nil {
		return time.Time{}, sql.NullTime{}, fmt.Errorf("staging event boundaries: %w", err)
	}
	if !found {
		return time.Time{}, sql.NullTime{}, fmt.Errorf("staging equipment_event %d not found (just-translated race?)", stagingEventID)
	}
	return tsEvent, tsEnd, nil
}
