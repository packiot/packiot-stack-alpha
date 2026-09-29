package replicate

// MANUAL downtime-event reconciler — legacy equipment_events_man → analytics
// silver.equipment_events_man, for the PackIOT parallel run.
//
// WHY A RECONCILE PASS (and not only the user_logs replay):
//
//   - The replay's manual-event-created/-edited handlers wrote the pre-#261
//     name `public.equipment_events_man`. t261e (2026-09-13) dropped that shim
//     view; failOpenIfMissing swallows 42P01, so every manual event after
//     2026-09-12 13:48 was silently dropped (the shim-drop hard-proof watched
//     pg_stat_statements for a window in which no manual event happened to be
//     replayed — ~1/day traffic hid the last reader).
//   - Even when it worked, the replay could not mirror a moved ts_event (the
//     edit handler keys on the CURRENT legacy ts), a DELETE (no audit
//     category), or a legacy duplicate — so replay-only mirroring drifts.
//
// WHAT IT DOES, each tick, for SrcEnterprise → DstEnterprise, window
// ts_event >= now - ReconcileManualLookbackDays:
//
//  1. Fetch legacy rows (SELECT-only), map id_equipment through the resolver
//     (packml base topic), and DEDUPE by (dst id_equipment, ts_event) — the
//     analytics UNIQUE key; legacy has none — keeping the latest last_update,
//     then the highest legacy id (deterministic).
//  2. Fetch analytics rows for DstEnterprise in the window, LEFT JOINed to the
//     provenance table ops.legacy_manual_event_link.
//  3. Plan (pure, unit-tested — planManual):
//     - winner key present      → UPDATE all mirrored columns if any differ;
//                                 link the row (adoption) if not yet linked
//     - winner key absent, but a LINKED row carries the same legacy id
//       (operator edited the start time) → MOVE that row in place
//     - otherwise               → INSERT (+ link, same statement)
//     - LINKED row not consumed → DELETE, unless its legacy id still exists
//       outside the window (moved out of the lookback — keep, never guess)
//     - UNLINKED row not at a winner key → never touched (new-stack authored)
//  4. Apply in ONE dest transaction; then refresh serving.downtime_events_resolved
//     for every UTC day touched (the 2-minute job only re-derives the last 3
//     days, so an edit/backfill older than that would otherwise never surface).
//
// PROVENANCE: ops.legacy_manual_event_link(id_equipment_event → legacy id). A
// row is owned by this pass only if linked; only owned rows are ever deleted.
// Rows are linked when this pass inserts them or when an existing analytics
// row sits exactly on a legacy (id_equipment, ts_event) key (it IS that legacy
// event — the unique key allows only one row there). Pre-existing legacy-origin
// orphans (earlier replay artefacts) are seeded by the migration
// db/migrations/t-replicate-manual-events with legacy id NULL.
import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ManualReconcileMetrics is the counter surface. *metrics.Metrics satisfies it.
type ManualReconcileMetrics interface {
	AddManualEvents(action string, n int)
}

type noopManualMetrics struct{}

func (noopManualMetrics) AddManualEvents(string, int) {}

// manualFields are every mirrored column except the identity (analytics
// IDENTITY), id_equipment (mapped) and id_enterprise (DstEnterprise). ts_event
// is part of the key and handled separately.
type manualFields struct {
	Status              sql.NullInt64
	TsEnd               sql.NullTime
	Duration            sql.NullInt64
	TxtDowntimeNotes    sql.NullString
	Idle                sql.NullString
	IdleProcessed       sql.NullBool
	Forced              sql.NullBool
	Fault               sql.NullInt64
	FaultProcessed      sql.NullBool
	CdMachine           sql.NullString
	CdCategory          sql.NullString
	CdSubcategory       sql.NullString
	ChangeOver          sql.NullBool
	PlannedDowntime     sql.NullBool
	DescCategory        sql.NullString
	DescSubcategory     sql.NullString
	CdCategoryClient    sql.NullInt64
	CdSubcategoryClient sql.NullInt64
	LastUpdate          sql.NullTime
	IgnoreCost          sql.NullBool
}

func eqNullTime(a, b sql.NullTime) bool {
	if a.Valid != b.Valid {
		return false
	}
	return !a.Valid || a.Time.Equal(b.Time)
}

// equal compares with IS NOT DISTINCT FROM semantics (NULL == NULL). Times by
// instant, so a legacy +00 vs analytics session-TZ rendering never differs.
func (a manualFields) equal(b manualFields) bool {
	return a.Status == b.Status && eqNullTime(a.TsEnd, b.TsEnd) && a.Duration == b.Duration &&
		a.TxtDowntimeNotes == b.TxtDowntimeNotes && a.Idle == b.Idle &&
		a.IdleProcessed == b.IdleProcessed && a.Forced == b.Forced && a.Fault == b.Fault &&
		a.FaultProcessed == b.FaultProcessed && a.CdMachine == b.CdMachine &&
		a.CdCategory == b.CdCategory && a.CdSubcategory == b.CdSubcategory &&
		a.ChangeOver == b.ChangeOver && a.PlannedDowntime == b.PlannedDowntime &&
		a.DescCategory == b.DescCategory && a.DescSubcategory == b.DescSubcategory &&
		a.CdCategoryClient == b.CdCategoryClient && a.CdSubcategoryClient == b.CdSubcategoryClient &&
		eqNullTime(a.LastUpdate, b.LastUpdate) && a.IgnoreCost == b.IgnoreCost
}

// legacyManual is one legacy row. LegacyEquip is the legacy id; DstEquip is
// filled by resolveLegacyManual.
type legacyManual struct {
	LegacyID    int64
	LegacyEquip int
	DstEquip    int
	TsEvent     time.Time
	F           manualFields
}

// destManual is one analytics row plus its provenance link (if any).
type destManual struct {
	ID           int64
	IDEquipment  int
	TsEvent      time.Time
	F            manualFields
	Linked       bool
	LinkLegacyID sql.NullInt64 // NULL for a seeded orphan (legacy id unknown)
}

type manualKey struct {
	eq int
	ts int64 // UnixMicro — timestamptz resolution
}

func keyOf(eq int, ts time.Time) manualKey { return manualKey{eq: eq, ts: ts.UnixMicro()} }

// resolveLegacyManual maps legacy equipment ids to the destination twin.
// Rows whose equipment has no twin are dropped and counted (topology drift,
// same posture as the PO reconciler).
func resolveLegacyManual(rows []legacyManual, resolve func(int) (StagingEquip, bool)) (out []legacyManual, unresolved int) {
	out = make([]legacyManual, 0, len(rows))
	for _, r := range rows {
		eq, ok := resolve(r.LegacyEquip)
		if !ok {
			unresolved++
			continue
		}
		r.DstEquip = eq.IDEquipment
		out = append(out, r)
	}
	return out, unresolved
}

// dedupeLegacyManual collapses legacy rows that collide on the analytics key
// (dst id_equipment, ts_event) — legacy has no unique key there, and operators
// double-submit (e.g. two rows 1 s apart). Winner: latest last_update (NULL
// oldest), then highest legacy id. Returns winners sorted by key and the set
// of every legacy id seen (winners + losers), used by the delete-safety rule.
func dedupeLegacyManual(rows []legacyManual) (winners []legacyManual, seen map[int64]bool) {
	seen = make(map[int64]bool, len(rows))
	best := make(map[manualKey]legacyManual, len(rows))
	for _, r := range rows {
		seen[r.LegacyID] = true
		k := keyOf(r.DstEquip, r.TsEvent)
		cur, ok := best[k]
		if !ok || legacyBeats(r, cur) {
			best[k] = r
		}
	}
	winners = make([]legacyManual, 0, len(best))
	for _, r := range best {
		winners = append(winners, r)
	}
	sort.Slice(winners, func(i, j int) bool {
		a, b := winners[i], winners[j]
		if a.DstEquip != b.DstEquip {
			return a.DstEquip < b.DstEquip
		}
		return a.TsEvent.Before(b.TsEvent)
	})
	return winners, seen
}

func legacyBeats(a, b legacyManual) bool {
	al, bl := a.F.LastUpdate, b.F.LastUpdate
	switch {
	case al.Valid && !bl.Valid:
		return true
	case !al.Valid && bl.Valid:
		return false
	case al.Valid && bl.Valid && !al.Time.Equal(bl.Time):
		return al.Time.After(bl.Time)
	}
	return a.LegacyID > b.LegacyID
}

type manualUpdate struct {
	ID    int64
	OldTs time.Time
	W     legacyManual
	Move  bool // ts_event changes (legacy start-time edit)
}

type manualLink struct {
	ID       int64
	LegacyID int64
}

type manualPlan struct {
	Inserts       []legacyManual
	Updates       []manualUpdate
	Links         []manualLink
	Deletes       []destManual
	Kept          int // linked rows kept because the legacy row lives outside the window
	Foreign       int // unlinked rows not on a legacy key — never touched
	DeleteGuard   string
	PlannedDelete int // deletes planned before any guard
}

func (p manualPlan) empty() bool {
	return len(p.Inserts) == 0 && len(p.Updates) == 0 && len(p.Links) == 0 && len(p.Deletes) == 0
}

// planManual is the pure core: winners (deduped legacy), seenLegacy (every
// legacy id fetched in the window, winners + duplicate losers), dest (analytics
// rows in the window + linked rows whose legacy id is a winner), and
// aliveOutside (linked legacy ids NOT in the window that still exist in legacy).
// maxDeletes <= 0 disables the cap.
func planManual(winners []legacyManual, seenLegacy map[int64]bool, dest []destManual, aliveOutside map[int64]bool, maxDeletes int) manualPlan {
	var p manualPlan
	byKey := make(map[manualKey]*destManual, len(dest))
	byLegacy := make(map[int64][]*destManual)
	for i := range dest {
		d := &dest[i]
		byKey[keyOf(d.IDEquipment, d.TsEvent)] = d
		if d.Linked && d.LinkLegacyID.Valid {
			byLegacy[d.LinkLegacyID.Int64] = append(byLegacy[d.LinkLegacyID.Int64], d)
		}
	}
	winnerKeys := make(map[manualKey]bool, len(winners))
	for _, w := range winners {
		winnerKeys[keyOf(w.DstEquip, w.TsEvent)] = true
	}
	consumed := make(map[int64]bool, len(dest))

	for _, w := range winners {
		k := keyOf(w.DstEquip, w.TsEvent)
		if d, ok := byKey[k]; ok {
			consumed[d.ID] = true
			if !d.F.equal(w.F) {
				p.Updates = append(p.Updates, manualUpdate{ID: d.ID, OldTs: d.TsEvent, W: w})
			}
			if !d.Linked || !d.LinkLegacyID.Valid || d.LinkLegacyID.Int64 != w.LegacyID {
				p.Links = append(p.Links, manualLink{ID: d.ID, LegacyID: w.LegacyID})
			}
			continue
		}
		// Start time edited in legacy: move the row we own in place (keeps the
		// analytics id stable) — only if it is not itself sitting on a winner key.
		var mover *destManual
		for _, d := range byLegacy[w.LegacyID] {
			if !consumed[d.ID] && !winnerKeys[keyOf(d.IDEquipment, d.TsEvent)] {
				mover = d
				break
			}
		}
		if mover != nil {
			consumed[mover.ID] = true
			p.Updates = append(p.Updates, manualUpdate{ID: mover.ID, OldTs: mover.TsEvent, W: w, Move: true})
			continue
		}
		p.Inserts = append(p.Inserts, w)
	}

	for i := range dest {
		d := &dest[i]
		if consumed[d.ID] {
			continue
		}
		if !d.Linked {
			p.Foreign++
			continue
		}
		if d.LinkLegacyID.Valid && !seenLegacy[d.LinkLegacyID.Int64] && aliveOutside[d.LinkLegacyID.Int64] {
			// The legacy row still exists but outside the lookback — don't guess.
			p.Kept++
			continue
		}
		p.Deletes = append(p.Deletes, *d)
	}
	p.PlannedDelete = len(p.Deletes)
	switch {
	case len(p.Deletes) > 0 && len(winners) == 0:
		// Legacy returned nothing for the window while we own rows in it —
		// an outage/config drift looks exactly like "everything deleted".
		p.DeleteGuard = "legacy window empty"
		p.Deletes = nil
	case maxDeletes > 0 && len(p.Deletes) > maxDeletes:
		p.DeleteGuard = fmt.Sprintf("%d deletes > max %d", len(p.Deletes), maxDeletes)
		p.Deletes = nil
	}
	return p
}

// ─── SQL (all schema-qualified; the #261 lesson) ───

const manualLinkSchemaDDL = `CREATE SCHEMA IF NOT EXISTS ops`

// Provenance table. Same DDL as db/migrations/t-replicate-manual-events/01-up.sql.
// No FK to silver.equipment_events_man on purpose: a FK would make TRUNCATE /
// sandbox re-clone of the silver table fail; dangling links are pruned instead.
const manualLinkDDL = `CREATE TABLE IF NOT EXISTS ops.legacy_manual_event_link (
	id_equipment_event        integer     PRIMARY KEY,
	dst_enterprise            integer     NOT NULL,
	legacy_id_equipment_event bigint,
	linked_at                 timestamptz NOT NULL DEFAULT now()
)`

const manualLinkIndexDDL = `CREATE INDEX IF NOT EXISTS legacy_manual_event_link_ent_legacy_idx
	ON ops.legacy_manual_event_link (dst_enterprise, legacy_id_equipment_event)`

// EnsureManualLink creates the provenance table if absent (idempotent).
func EnsureManualLink(ctx context.Context, dst *pgxpool.Pool) error {
	for _, q := range []string{manualLinkSchemaDDL, manualLinkDDL, manualLinkIndexDDL} {
		if _, err := dst.Exec(ctx, q); err != nil {
			return err
		}
	}
	return nil
}

const manualCols = `status, ts_end, duration, txt_downtime_notes, idle, idle_processed,
	forced_creation_system, fault, fault_processed, cd_machine, cd_category, cd_subcategory,
	change_over, planned_downtime, desc_category, desc_subcategory,
	cd_category_client, cd_subcategory_client, last_update, ignore_cost`

const sqlManualLegacyFetch = `SELECT id_equipment_event, id_equipment, ts_event, ` + manualCols + `
	  FROM equipment_events_man
	 WHERE id_enterprise = $1 AND ts_event >= $2 AND id_equipment IS NOT NULL AND ts_event IS NOT NULL`

const sqlManualLegacyAlive = `SELECT id_equipment_event FROM equipment_events_man WHERE id_equipment_event = ANY($1)`

// Window rows + any linked row whose legacy id is fetched in the window (a
// start time edited INTO the window from before it).
const sqlManualDestFetch = `SELECT a.id_equipment_event, a.id_equipment, a.ts_event, ` + manualColsA + `,
	       l.id_equipment_event IS NOT NULL, l.legacy_id_equipment_event
	  FROM silver.equipment_events_man a
	  LEFT JOIN ops.legacy_manual_event_link l
	         ON l.id_equipment_event = a.id_equipment_event AND l.dst_enterprise = $1
	 WHERE a.id_enterprise = $1
	   AND (a.ts_event >= $2 OR l.legacy_id_equipment_event = ANY($3))`

const manualColsA = `a.status, a.ts_end, a.duration, a.txt_downtime_notes, a.idle, a.idle_processed,
	a.forced_creation_system, a.fault, a.fault_processed, a.cd_machine, a.cd_category, a.cd_subcategory,
	a.change_over, a.planned_downtime, a.desc_category, a.desc_subcategory,
	a.cd_category_client, a.cd_subcategory_client, a.last_update, a.ignore_cost`

const sqlManualPruneLinks = `DELETE FROM ops.legacy_manual_event_link l
	 WHERE l.dst_enterprise = $1
	   AND NOT EXISTS (SELECT 1 FROM silver.equipment_events_man a WHERE a.id_equipment_event = l.id_equipment_event)`

// Delete re-checks ownership in SQL (belt and braces over the planner).
const sqlManualDelete = `WITH d AS (
	DELETE FROM silver.equipment_events_man a
	 USING ops.legacy_manual_event_link l
	 WHERE a.id_equipment_event = $1 AND a.id_enterprise = $2
	   AND l.id_equipment_event = a.id_equipment_event AND l.dst_enterprise = $2
	RETURNING a.id_equipment_event)
	DELETE FROM ops.legacy_manual_event_link x USING d WHERE x.id_equipment_event = d.id_equipment_event`

// $1..$20 = manualFields order; $21 id_equipment; $22 ts_event; $23 row id.
const sqlManualUpdate = `UPDATE silver.equipment_events_man SET
	status = $1, ts_end = $2, duration = $3, txt_downtime_notes = $4, idle = $5, idle_processed = $6,
	forced_creation_system = $7, fault = $8, fault_processed = $9, cd_machine = $10, cd_category = $11,
	cd_subcategory = $12, change_over = $13, planned_downtime = $14, desc_category = $15,
	desc_subcategory = $16, cd_category_client = $17, cd_subcategory_client = $18, last_update = $19,
	ignore_cost = $20, id_equipment = $21, ts_event = $22
	WHERE id_equipment_event = $23`

// Insert + link in ONE statement. id_equipment_event is omitted (analytics
// IDENTITY — never copy the legacy serial). A concurrent writer on the same key
// makes the INSERT a no-op and the link is skipped; the next tick adopts it.
// $1..$20 fields; $21 id_equipment; $22 ts_event; $23 id_enterprise; $24 legacy id.
const sqlManualInsert = `WITH ins AS (
	INSERT INTO silver.equipment_events_man (` + manualCols + `, id_equipment, ts_event, id_enterprise)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23)
	ON CONFLICT (id_equipment, ts_event) DO NOTHING
	RETURNING id_equipment_event)
	INSERT INTO ops.legacy_manual_event_link (id_equipment_event, dst_enterprise, legacy_id_equipment_event)
	SELECT id_equipment_event, $23::integer, $24::bigint FROM ins`

const sqlManualLink = `INSERT INTO ops.legacy_manual_event_link (id_equipment_event, dst_enterprise, legacy_id_equipment_event)
	VALUES ($1, $2, $3)
	ON CONFLICT (id_equipment_event) DO UPDATE
	   SET dst_enterprise = EXCLUDED.dst_enterprise,
	       legacy_id_equipment_event = EXCLUDED.legacy_id_equipment_event, linked_at = now()`

const sqlManualRefreshServing = `SELECT serving.refresh_downtime_events_resolved($1, $2)`

func fieldArgs(f manualFields) []any {
	return []any{f.Status, f.TsEnd, f.Duration, f.TxtDowntimeNotes, f.Idle, f.IdleProcessed,
		f.Forced, f.Fault, f.FaultProcessed, f.CdMachine, f.CdCategory, f.CdSubcategory,
		f.ChangeOver, f.PlannedDowntime, f.DescCategory, f.DescSubcategory,
		f.CdCategoryClient, f.CdSubcategoryClient, f.LastUpdate, f.IgnoreCost}
}

func fieldDest(f *manualFields) []any {
	return []any{&f.Status, &f.TsEnd, &f.Duration, &f.TxtDowntimeNotes, &f.Idle, &f.IdleProcessed,
		&f.Forced, &f.Fault, &f.FaultProcessed, &f.CdMachine, &f.CdCategory, &f.CdSubcategory,
		&f.ChangeOver, &f.PlannedDowntime, &f.DescCategory, &f.DescSubcategory,
		&f.CdCategoryClient, &f.CdSubcategoryClient, &f.LastUpdate, &f.IgnoreCost}
}

// manualStmt is one planned write, rendered so the same list can be executed
// against a pgx.Tx or printed for a rolled-back proof.
type manualStmt struct {
	SQL  string
	Args []any
	Kind string // delete|update|move|insert|link|prune
}

// statements renders a plan in apply order: prune dangling links, deletes
// (free keys first), updates/moves, inserts, links.
func (p manualPlan) statements(dstEnt int) []manualStmt {
	out := []manualStmt{{SQL: sqlManualPruneLinks, Args: []any{dstEnt}, Kind: "prune"}}
	for _, d := range p.Deletes {
		out = append(out, manualStmt{SQL: sqlManualDelete, Args: []any{d.ID, dstEnt}, Kind: "delete"})
	}
	for _, u := range p.Updates {
		args := append(fieldArgs(u.W.F), u.W.DstEquip, u.W.TsEvent, u.ID)
		kind := "update"
		if u.Move {
			kind = "move"
		}
		out = append(out, manualStmt{SQL: sqlManualUpdate, Args: args, Kind: kind})
	}
	for _, w := range p.Inserts {
		args := append(fieldArgs(w.F), w.DstEquip, w.TsEvent, dstEnt, w.LegacyID)
		out = append(out, manualStmt{SQL: sqlManualInsert, Args: args, Kind: "insert"})
	}
	for _, l := range p.Links {
		out = append(out, manualStmt{SQL: sqlManualLink, Args: []any{l.ID, dstEnt, l.LegacyID}, Kind: "link"})
	}
	return out
}

// touchedDays returns the UTC day starts whose serving rows must be re-derived:
// old and new ts_event of every write.
func (p manualPlan) touchedDays() []time.Time {
	set := map[time.Time]bool{}
	add := func(t time.Time) { set[t.UTC().Truncate(24*time.Hour)] = true }
	for _, d := range p.Deletes {
		add(d.TsEvent)
	}
	for _, u := range p.Updates {
		add(u.OldTs)
		add(u.W.TsEvent)
	}
	for _, w := range p.Inserts {
		add(w.TsEvent)
	}
	days := make([]time.Time, 0, len(set))
	for d := range set {
		days = append(days, d)
	}
	sort.Slice(days, func(i, j int) bool { return days[i].Before(days[j]) })
	return days
}

// dayRanges merges sorted day starts into contiguous [from, to) ranges.
func dayRanges(days []time.Time) [][2]time.Time {
	var out [][2]time.Time
	for _, d := range days {
		end := d.Add(24 * time.Hour)
		if n := len(out); n > 0 && !out[n-1][1].Before(d) {
			if end.After(out[n-1][1]) {
				out[n-1][1] = end
			}
			continue
		}
		out = append(out, [2]time.Time{d, end})
	}
	return out
}

// ─── runner ───

type ManualReconciler struct {
	legacy *pgxpool.Pool
	dest   *pgxpool.Pool
	r      *Resolver
	cfg    *Config
	m      ManualReconcileMetrics
	logger *slog.Logger
}

func NewManualReconciler(legacy, dest *pgxpool.Pool, r *Resolver, cfg *Config, m ManualReconcileMetrics, logger *slog.Logger) *ManualReconciler {
	if m == nil {
		m = noopManualMetrics{}
	}
	return &ManualReconciler{legacy: legacy, dest: dest, r: r, cfg: cfg, m: m, logger: logger}
}

// RunForever runs one pass at startup then every interval (same posture as
// the PO reconciler: a failed pass is logged and retried next tick).
func (mr *ManualReconciler) RunForever(ctx context.Context) error {
	if !mr.cfg.ReconcileManualEnabled {
		mr.logger.Info("manual-event reconciler disabled (RECONCILE_MANUAL_EVENTS_ENABLED=false)")
		<-ctx.Done()
		return ctx.Err()
	}
	if err := EnsureManualLink(ctx, mr.dest); err != nil {
		// Without the provenance table nothing can be linked or safely deleted.
		mr.logger.Error("manual-event reconciler: ensure ops.legacy_manual_event_link failed — pass disabled",
			slog.String("err", err.Error()))
		<-ctx.Done()
		return ctx.Err()
	}
	mr.logger.Info("manual-event reconciler started",
		slog.Int("interval_sec", mr.cfg.ReconcileManualIntervalSec),
		slog.Int("lookback_days", mr.cfg.ReconcileManualLookbackDays),
		slog.Int("max_deletes", mr.cfg.ReconcileManualMaxDeletes),
		slog.Bool("refresh_serving", mr.cfg.ReconcileManualRefreshServing),
		slog.Int("src_enterprise", mr.cfg.SrcEnterprise),
		slog.Int("dst_enterprise", mr.cfg.DstEnterprise))
	mr.runOnce(ctx)
	t := time.NewTicker(time.Duration(mr.cfg.ReconcileManualIntervalSec) * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			mr.runOnce(ctx)
		}
	}
}

func (mr *ManualReconciler) runOnce(ctx context.Context) {
	since := time.Now().AddDate(0, 0, -mr.cfg.ReconcileManualLookbackDays)
	if err := mr.pass(ctx, since); err != nil {
		mr.logger.Warn("manual-event reconcile pass failed", slog.String("err", err.Error()))
	}
}

func (mr *ManualReconciler) pass(ctx context.Context, since time.Time) error {
	raw, err := fetchLegacyManual(ctx, mr.legacy, mr.cfg.SrcEnterprise, since)
	if err != nil {
		return fmt.Errorf("legacy fetch: %w", err)
	}
	resolved, unresolved := resolveLegacyManual(raw, mr.r.ResolveEquipment)
	winners, seen := dedupeLegacyManual(resolved)
	winnerIDs := make([]int64, 0, len(winners))
	for _, w := range winners {
		winnerIDs = append(winnerIDs, w.LegacyID)
	}
	dest, err := fetchDestManual(ctx, mr.dest, mr.cfg.DstEnterprise, since, winnerIDs)
	if err != nil {
		return fmt.Errorf("dest fetch: %w", err)
	}
	// Linked legacy ids we did not see in the window: do they still exist?
	var probe []int64
	for _, d := range dest {
		if d.Linked && d.LinkLegacyID.Valid && !seen[d.LinkLegacyID.Int64] {
			probe = append(probe, d.LinkLegacyID.Int64)
		}
	}
	alive, err := fetchLegacyAlive(ctx, mr.legacy, probe)
	if err != nil {
		return fmt.Errorf("legacy alive probe: %w", err)
	}

	plan := planManual(winners, seen, dest, alive, mr.cfg.ReconcileManualMaxDeletes)
	if plan.DeleteGuard != "" {
		mr.m.AddManualEvents("delete_guarded", plan.PlannedDelete)
		mr.logger.Warn("manual-event reconcile: deletes SKIPPED by guard",
			slog.String("reason", plan.DeleteGuard), slog.Int("planned_deletes", plan.PlannedDelete))
	}
	counts := map[string]int{}
	if !plan.empty() {
		tx, err := mr.dest.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin: %w", err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck — no-op after Commit
		for _, s := range plan.statements(mr.cfg.DstEnterprise) {
			ct, err := tx.Exec(ctx, s.SQL, s.Args...)
			if err != nil {
				return fmt.Errorf("%s: %w", s.Kind, err)
			}
			counts[s.Kind] += int(ct.RowsAffected())
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("commit: %w", err)
		}
		for _, k := range []string{"insert", "update", "move", "delete", "link"} {
			mr.m.AddManualEvents(k, counts[k])
		}
	}
	mr.m.AddManualEvents("unresolved", unresolved)

	refreshed := 0
	if mr.cfg.ReconcileManualRefreshServing && !plan.empty() {
		for _, rg := range dayRanges(plan.touchedDays()) {
			if _, err := mr.dest.Exec(ctx, sqlManualRefreshServing, rg[0], rg[1]); err != nil {
				var pgErr *pgconn.PgError
				if errors.As(err, &pgErr) && (pgErr.Code == "42883" || pgErr.Code == "3F000") {
					mr.logger.Warn("manual-event reconcile: serving refresh function missing — skipped")
					break
				}
				mr.logger.Warn("manual-event reconcile: serving refresh failed",
					slog.Time("from", rg[0]), slog.Time("to", rg[1]), slog.String("err", err.Error()))
				continue
			}
			refreshed++
		}
	}

	mr.logger.Info("manual-event reconcile pass done",
		slog.Time("since", since),
		slog.Int("legacy_rows", len(raw)),
		slog.Int("unresolved", unresolved),
		slog.Int("legacy_duplicates_collapsed", len(resolved)-len(winners)),
		slog.Int("dest_rows", len(dest)),
		slog.Int("inserted", counts["insert"]),
		slog.Int("updated", counts["update"]),
		slog.Int("moved", counts["move"]),
		slog.Int("deleted", counts["delete"]),
		slog.Int("linked", counts["link"]),
		slog.Int("links_pruned", counts["prune"]),
		slog.Int("kept_legacy_outside_window", plan.Kept),
		slog.Int("foreign_untouched", plan.Foreign),
		slog.Int("serving_ranges_refreshed", refreshed))
	return nil
}

func fetchLegacyManual(ctx context.Context, legacy *pgxpool.Pool, srcEnt int, since time.Time) ([]legacyManual, error) {
	rows, err := legacy.Query(ctx, sqlManualLegacyFetch, srcEnt, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []legacyManual
	for rows.Next() {
		var r legacyManual
		dst := append([]any{&r.LegacyID, &r.LegacyEquip, &r.TsEvent}, fieldDest(&r.F)...)
		if err := rows.Scan(dst...); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func fetchDestManual(ctx context.Context, dest *pgxpool.Pool, dstEnt int, since time.Time, legacyIDs []int64) ([]destManual, error) {
	rows, err := dest.Query(ctx, sqlManualDestFetch, dstEnt, since, legacyIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []destManual
	for rows.Next() {
		var d destManual
		var id int32
		var eq sql.NullInt32
		dst := append([]any{&id, &eq, &d.TsEvent}, fieldDest(&d.F)...)
		dst = append(dst, &d.Linked, &d.LinkLegacyID)
		if err := rows.Scan(dst...); err != nil {
			return nil, err
		}
		d.ID = int64(id)
		d.IDEquipment = int(eq.Int32)
		out = append(out, d)
	}
	return out, rows.Err()
}

func fetchLegacyAlive(ctx context.Context, legacy *pgxpool.Pool, ids []int64) (map[int64]bool, error) {
	alive := map[int64]bool{}
	if len(ids) == 0 {
		return alive, nil
	}
	rows, err := legacy.Query(ctx, sqlManualLegacyAlive, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		alive[id] = true
	}
	return alive, rows.Err()
}
