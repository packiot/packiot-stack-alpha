package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/secrets"
)

type Staging struct {
	pool   *pgxpool.Pool
	logger *slog.Logger

	// ADR-0012 3-flow parity fan-out (see InsertEquipmentValueDelta).
	valueFanout bool
	shadowPool  *pgxpool.Pool // packiot_shadow (Flow 3); nil = not attached
}

func NewStaging(ctx context.Context, creds *secrets.DBCreds, logger *slog.Logger) (*Staging, error) {
	pc, err := pgxpool.ParseConfig(creds.URL("mirror-worker-go"))
	if err != nil {
		return nil, fmt.Errorf("parse staging url: %w", err)
	}
	pc.MaxConns = 5
	pc.MinConns = 1

	// pgbouncer in front of staging postgres runs in TRANSACTION pooling
	// mode — pgx's cached prepared statements break under that (SQLSTATE
	// 42P05). Same fix as oeecloud-worker.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create staging pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("staging ping: %w", err)
	}
	logger.Info("staging pool ready", slog.String("url", creds.Redacted("mirror-worker-go")))
	return &Staging{pool: p, logger: logger}, nil
}

func (s *Staging) Close() {
	s.pool.Close()
	if s.shadowPool != nil {
		s.shadowPool.Close()
	}
}

// EnableValueFanout turns on ADR-0012 3-flow fan-out: every
// InsertEquipmentValueDelta row is also written to packiot.shadow_go_port
// (same pool) and, when AttachShadowPool succeeded, packiot_shadow.public.
func (s *Staging) EnableValueFanout() { s.valueFanout = true }

// AttachShadowPool connects the ADR-0012 shadow DB (packiot_shadow) so
// value fan-out reaches Flow 3. Separate pool because pgbouncer's static
// database list doesn't include packiot_shadow — callers pass a
// direct-to-postgres host via SHADOW_DB_HOST (same bypass shadow-mirror
// uses).
func (s *Staging) AttachShadowPool(ctx context.Context, creds *secrets.DBCreds, host, dbName string) error {
	sc := *creds
	sc.Database = dbName
	if host != "" {
		sc.Host = host
	}
	pc, err := pgxpool.ParseConfig(sc.URL("mirror-worker-go-shadow"))
	if err != nil {
		return fmt.Errorf("parse shadow url: %w", err)
	}
	pc.MaxConns = 2
	pc.MinConns = 1
	// Simple protocol even though this pool bypasses pgbouncer — keeps
	// behavior uniform with the main pool.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return fmt.Errorf("create shadow pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return fmt.Errorf("shadow ping: %w", err)
	}
	s.shadowPool = p
	s.logger.Info("shadow pool ready", slog.String("db", dbName))
	return nil
}

// WithTx runs fn inside a staging transaction. Commits on nil error,
// rolls back on any error. Same shape as TS mirror-worker's withStagingTx.
func (s *Staging) WithTx(ctx context.Context, fn func(pgx.Tx) error) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

// SelectOne is for ad-hoc reads outside a transaction.
func (s *Staging) SelectOne(ctx context.Context, sql string, args []any, dest ...any) (bool, error) {
	err := s.pool.QueryRow(ctx, sql, args...).Scan(dest...)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// ──── Cursor + mapping helpers ─────────────────────────────────────────

// FetchAPIToken reads enterprises.api_key for the staging mirror enterprise.
// Called once at startup; rotation requires a worker restart.
func (s *Staging) FetchAPIToken(ctx context.Context, enterpriseID int) (string, error) {
	var token string
	found, err := s.SelectOne(ctx,
		`SELECT api_key FROM enterprises WHERE id_enterprise = $1`,
		[]any{enterpriseID}, &token)
	if err != nil {
		return "", err
	}
	if !found || token == "" {
		return "", fmt.Errorf("enterprises.api_key missing for id_enterprise=%d on staging — seed it first", enterpriseID)
	}
	return token, nil
}

func (s *Staging) ReadCursor(ctx context.Context, source string) (int64, error) {
	var cursor int64
	found, err := s.SelectOne(ctx,
		`SELECT last_log_id FROM mirror_replay_cursor WHERE source = $1`,
		[]any{source}, &cursor)
	if err != nil {
		return 0, err
	}
	if !found {
		return 0, fmt.Errorf("cursor row for source %q missing — seed it before starting", source)
	}
	return cursor, nil
}

// AdvanceCursor moves the cursor forward — uses < so out-of-order calls
// can't move it backward. Runs inside the per-row transaction passed by
// the caller (tx, not pool — atomic with mapping inserts / DLQ writes).
func AdvanceCursor(ctx context.Context, tx pgx.Tx, source string, toID int64) error {
	_, err := tx.Exec(ctx,
		`UPDATE mirror_replay_cursor
		    SET last_log_id = $1, last_run_at = now()
		  WHERE source = $2
		    AND last_log_id < $1`,
		toID, source)
	return err
}

type MapInsert struct {
	EntityType  string
	Source      string
	ProdID      int64
	StagingID   int64
	SourceLogID int64
}

// InsertMapping is idempotent via ON CONFLICT DO NOTHING. Runs in caller's tx.
func InsertMapping(ctx context.Context, tx pgx.Tx, m MapInsert) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO mirror_id_map
		       (entity_type, source, prod_id, staging_id, source_log_id)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (entity_type, source, prod_id) DO NOTHING`,
		m.EntityType, m.Source, m.ProdID, m.StagingID, m.SourceLogID)
	return err
}

func (s *Staging) LookupMapping(ctx context.Context, entityType, source string, prodID int64) (int64, bool, error) {
	var stagingID int64
	found, err := s.SelectOne(ctx,
		`SELECT staging_id FROM mirror_id_map
		  WHERE entity_type = $1 AND source = $2 AND prod_id = $3`,
		[]any{entityType, source, prodID}, &stagingID)
	return stagingID, found, err
}

func (s *Staging) IsAlreadyReplayed(ctx context.Context, source string, sourceLogID int64) (bool, error) {
	var exists bool
	_, err := s.SelectOne(ctx,
		`SELECT EXISTS(
		   SELECT 1 FROM mirror_id_map
		    WHERE source = $1 AND source_log_id = $2
		 )`,
		[]any{source, sourceLogID}, &exists)
	return exists, err
}

// CountIDMap returns the row count of mirror_id_map for this source.
// Powers the id_map_cache_size gauge — a growth signal + sanity check
// that the worker is actually producing mappings.
//
// COUNT(*) is O(n); today the table has ~2k rows for cpack-prod-go,
// well under 1ms. If it grows to 100k+, switch to pg_class.reltuples
// for an approximate count.
func (s *Staging) CountIDMap(ctx context.Context, source string) (int64, error) {
	var n int64
	_, err := s.SelectOne(ctx,
		`SELECT COUNT(*) FROM mirror_id_map WHERE source = $1`,
		[]any{source}, &n)
	return n, err
}

// DistinctDLQSourceLogIDs returns the unique set of prod source_log_ids
// currently in mirror_replay_dlq for this worker's source. Used by the
// comparator's dlq_anomaly_total metric (ADR-0008 phase 2a.4) to detect
// DLQ entries whose underlying prod user_log has disappeared (rare, but
// real: prod data cleanup, or a bug that stamped wrong IDs).
//
// Returns an empty slice (not error) when the DLQ is empty — caller
// treats that as the healthy steady state, 0 anomalies.
func (s *Staging) DistinctDLQSourceLogIDs(ctx context.Context, source string) ([]int64, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT DISTINCT source_log_id FROM mirror_replay_dlq WHERE source = $1`,
		source,
	)
	if err != nil {
		return nil, fmt.Errorf("query distinct dlq source_log_ids: %w", err)
	}
	defer rows.Close()
	out := make([]int64, 0)
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// MaxRecentEventTs returns max(ts_event) on staging equipment_events
// scoped to enterprise + the last hour. Same time-window discipline as
// the prod-side query (avoid scanning the full hypertable). Used by the
// comparator's events_lag_seconds metric (ADR-0008 phase 2a.2).
func (s *Staging) MaxRecentEventTs(ctx context.Context, enterpriseID int) (time.Time, error) {
	var ts sql.NullTime
	err := s.pool.QueryRow(ctx,
		`SELECT max(ts_event)
		   FROM equipment_events
		  WHERE id_enterprise = $1
		    AND ts_event > now() - interval '1 hour'`,
		enterpriseID,
	).Scan(&ts)
	if err != nil {
		return time.Time{}, fmt.Errorf("max recent staging ts_event: %w", err)
	}
	if !ts.Valid {
		return time.Time{}, nil
	}
	return ts.Time, nil
}

// CountActivePOs returns the number of staging production_orders currently
// in status=2 (running) for the given enterprise. Used by the comparator
// for the active_pos_diff fidelity metric (ADR-0008 phase 2a). Lighter
// than ActivePOIDOrders — no row scan, one round-trip, COUNT(*).
func (s *Staging) CountActivePOs(ctx context.Context, enterpriseID int) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx,
		`SELECT count(*) FROM production_orders
		  WHERE id_enterprise = $1 AND status = 2`,
		enterpriseID,
	).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("count active staging POs: %w", err)
	}
	return n, nil
}

// ActivePOIDOrders returns the set of id_order values for staging POs
// currently in status=2 (running). Used by the reconciler to diff against
// prod's active set without pulling every column.
//
// Returning a map[int64]int64 (id_order → id_production_order) instead
// of a set so the caller can also check whether a finished mirror of the
// same id_order exists at a different staging PO id — useful for future
// log lines but not strictly needed by the diff itself.
func (s *Staging) ActivePOIDOrders(ctx context.Context, enterpriseID int) (map[int64]int64, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id_order, id_production_order
		   FROM production_orders
		  WHERE id_enterprise = $1 AND status = 2`,
		enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query active staging POs: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]int64)
	for rows.Next() {
		var idOrder, idPO int64
		if err := rows.Scan(&idOrder, &idPO); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out[idOrder] = idPO
	}
	return out, rows.Err()
}

// ReconcileActivePOIDOrders returns the RECONCILE-ORIGIN staging POs
// currently in status=2, as id_order → id_production_order. This is the
// finisher's candidate universe (task #48) — deliberately NARROWER than
// ActivePOIDOrders, which also counts simulator- and operator-created POs the
// finisher must never touch.
//
// "Reconcile-origin" is identified by either of the reconciler's two
// signatures (union so a PO with a lost mapping insert is still covered — both
// ensureOnePO and reviveExistingStagingPO swallow mapping-insert errors):
//   - a mirror_id_map row for THIS source with source_log_id = 0 (the
//     reconciler stamps 0 to mark "not from a user_log"); OR
//   - nm_production_order LIKE 'CPACK-reconcile-%' (the reconciler's naming).
//
// Both are reconcile-specific and both exclude simulator / hand-made POs
// (which never get a mirror_id_map row nor that name), so the finisher's blast
// radius is bounded to POs this reconciler itself created. user_logs-replayed
// mirror POs (source_log_id != 0) are intentionally OUT of scope for v1.
func (s *Staging) ReconcileActivePOIDOrders(ctx context.Context, source string, enterpriseID int) (map[int64]int64, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT po.id_order, po.id_production_order
		   FROM production_orders po
		  WHERE po.id_enterprise = $2
		    AND po.status = 2
		    AND (
		      po.nm_production_order LIKE 'CPACK-reconcile-%'
		      OR EXISTS (
		        SELECT 1 FROM mirror_id_map m
		         WHERE m.entity_type = 'production_order'
		           AND m.source = $1
		           AND m.staging_id = po.id_production_order
		           AND m.source_log_id = 0
		      )
		    )`,
		source, enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query reconcile-origin active staging POs: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]int64)
	for rows.Next() {
		var idOrder, idPO int64
		if err := rows.Scan(&idOrder, &idPO); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out[idOrder] = idPO
	}
	return out, rows.Err()
}

// FinishOrphanPO closes an orphaned reconcile PO on staging: it seals the open
// runtime segment at closeTs and flips the header to status=3 (finished), in
// one transaction. Returns whether it actually finished a row (false = already
// finished by a prior pass → idempotent no-op).
//
// This is the DIRECT-DB equivalent of what StopProductionOrderDAO.stop does
// (close production_orders_runtime where upper(runtime_timerange) IS NULL,
// then set production_orders.status/ts_end + recalc_needed). We do NOT route
// through edge-api /api/production-orders/stop on purpose: that path runs the
// PoStalenessGate, whose BEYOND_HORIZON gate (48h) would REJECT a close at a
// stale last-activity ts — and stale is exactly the orphan case. The finisher
// is a reconciliation/repair write, not an operator action, so it bypasses the
// operator-facing gate by design.
//
// Idempotency is structural, not advisory:
//   - the segment UPDATE only matches OPEN segments (upper IS NULL);
//   - the header UPDATE only matches status=2.
//
// A second pass therefore touches zero rows. GREATEST(closeTs, lower(...))
// guards the empty/inverted-range error class: if closeTs somehow precedes the
// segment start, we clamp to lower so tstzrange never sees upper < lower.
// recalc_needed=true lets staging's per-minute cron recompute the now-closed
// PO's final OEE, same as a real stop.
func (s *Staging) FinishOrphanPO(ctx context.Context, stagingPOID int64, closeTs time.Time) (bool, error) {
	var finished bool
	err := s.WithTx(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`UPDATE production_orders_runtime
			    SET runtime_timerange = tstzrange(
			          lower(runtime_timerange),
			          GREATEST($2::timestamptz, lower(runtime_timerange))),
			        recalc_needed = true
			  WHERE id_production_order = $1
			    AND upper(runtime_timerange) IS NULL`,
			stagingPOID, closeTs); err != nil {
			return fmt.Errorf("close runtime segment: %w", err)
		}
		ct, err := tx.Exec(ctx,
			`UPDATE production_orders
			    SET status = 3, ts_end = $2, recalc_needed = true
			  WHERE id_production_order = $1
			    AND status = 2`,
			stagingPOID, closeTs)
		if err != nil {
			return fmt.Errorf("finish production_order: %w", err)
		}
		finished = ct.RowsAffected() > 0
		return nil
	})
	return finished, err
}

// LookupStagingPOByIDOrder returns the most recent staging PO matching
// (enterprise, id_order). Called by the reconciler after POSTing
// /api/production-orders/create to capture the new id_production_order
// the way the order-created handler does.
func (s *Staging) LookupStagingPOByIDOrder(ctx context.Context, enterpriseID int, idOrder int64) (int64, bool, error) {
	var stagingPOID int64
	found, err := s.SelectOne(ctx,
		`SELECT id_production_order FROM production_orders
		  WHERE id_enterprise = $1 AND id_order = $2
		  ORDER BY id_production_order DESC LIMIT 1`,
		[]any{enterpriseID, idOrder}, &stagingPOID)
	return stagingPOID, found, err
}

// MappedActivePO is a per-PO view the value-sync uses: the mapping +
// the staging PO's current equipment + the latest staging runtime
// counters. One SELECT-with-JOIN replaces N round-trips while the
// reconciler walks mirror_id_map.
type MappedActivePO struct {
	ProdPOID               int64
	StagingPOID            int64
	StagingEquipment       int
	StagingSite            int
	StagingArea            int
	StagingNetProduction   *float64
	StagingGrossProduction *float64
}

// FetchMappedActiveCPACKPOs returns every mirror_id_map row for active
// staging CPACK POs joined with their equipment + current runtime
// counters. Used by the value-sync to compute deltas vs prod.
//
// Filters by source so a future second mirror source (e.g., azpack-prod)
// won't accidentally accumulate inserts here.
func (s *Staging) FetchMappedActiveCPACKPOs(ctx context.Context, source string, enterpriseID int) ([]MappedActivePO, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT m.prod_id, m.staging_id,
		        po.id_equipment, po.id_site, po.id_area,
		        por.net_production, por.gross_production
		   FROM mirror_id_map m
		   JOIN production_orders po
		     ON po.id_production_order = m.staging_id
		   LEFT JOIN production_orders_runtime por
		     ON por.id_production_order = m.staging_id
		  WHERE m.entity_type = 'production_order'
		    AND m.source = $1
		    AND po.id_enterprise = $2
		    AND po.status = 2`,
		source, enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query mapped active POs: %w", err)
	}
	defer rows.Close()
	var out []MappedActivePO
	for rows.Next() {
		var r MappedActivePO
		if err := rows.Scan(&r.ProdPOID, &r.StagingPOID,
			&r.StagingEquipment, &r.StagingSite, &r.StagingArea,
			&r.StagingNetProduction, &r.StagingGrossProduction); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// InsertEquipmentValueDelta writes one synthetic equipment_values row
// carrying a net/gross production increment. The per-minute pg_cron
// (piot_proc_refresh_runtime) sums equipment_values per equipment +
// active-PO window into production_orders_runtime, so this row makes the
// cron compute prod-anchored values WITHOUT us racing it.
//
// Single writer per CPACK equipment is guaranteed by the simulator's
// SIM_SKIP_ENTERPRISE_IDS=3 default (added in the same change set).
// If the simulator skip is misconfigured the cron will sum both sources
// and counters will run hot — log + a follow-up alarm should flag that.
//
// id_shift gets populated by the piot_set_shift_before_insert trigger.
// Other operational columns (state, mode, speed, id_order, id_production_
// order) intentionally left NULL — this row is a counter delta, not a
// PLC snapshot.
//
// ADR-0012 3-flow fan-out: when EnableValueFanout was called, the same
// row also goes to packiot.shadow_go_port (Flow 2) and — if
// AttachShadowPool succeeded — packiot_shadow.public (Flow 3). The
// timestamp is computed ONCE in Go: (ts_value, id_equipment) is the
// parity join key across flows, and a per-statement now() would give
// each flow a different key. Shadow failures never fail the Flow 1
// write — a caller retry would re-insert the delta and double-count
// production — they surface via mirror_worker_value_fanout_total +
// warn logs instead (loss-with-alert, ADR-0011 rule 5).
func (s *Staging) InsertEquipmentValueDelta(
	ctx context.Context,
	stagingEqID, stagingSiteID, stagingAreaID, enterpriseID int,
	netDelta, grossDelta float64,
	stagingPOID int64,
) error {
	ts := time.Now().UTC()
	if _, err := s.pool.Exec(ctx, fmt.Sprintf(sqlInsertValueDelta, "public"),
		stagingEqID, ts, enterpriseID, stagingSiteID, stagingAreaID, netDelta, grossDelta, stagingPOID,
	); err != nil {
		return err // Flow 1 is the source of truth — caller handles
	}
	if !s.valueFanout {
		return nil
	}
	s.fanoutValueDelta(ctx, s.pool, "shadow_go_port", "shadow_go_port",
		ts, stagingEqID, stagingSiteID, stagingAreaID, enterpriseID, netDelta, grossDelta, stagingPOID)
	if s.shadowPool != nil {
		s.fanoutValueDelta(ctx, s.shadowPool, "public", "packiot_shadow",
			ts, stagingEqID, stagingSiteID, stagingAreaID, enterpriseID, netDelta, grossDelta, stagingPOID)
	}
	return nil
}

// tp_equipment matters: prod's CAgg layer filters
// WHERE tp_equipment IS NOT NULL — a delta row without it is invisible
// to every aggregate (found via the ADR-0015 query API returning [];
// staging CPACK rows were excluded from the whole agg layer).
const sqlInsertValueDelta = `INSERT INTO %s.equipment_values
	       (id_equipment, ts_value, id_enterprise, id_site, id_area,
	        net_production_incr, gross_production_incr, tp_equipment, ts_value_production, id_shift, id_shift_hour, id_production_order)
	 SELECT $1, $2, $3, $4, $5, $6, $7, e.tp_equipment,
	        (SELECT d.ts_value_production FROM piot_get_day_begin_by_equipment($1, $2) d LIMIT 1),
	        (SELECT s.id_shift FROM piot_get_shift_hour_begin_by_equipment($1, $2) s LIMIT 1),
	        (SELECT s.id_shift_hour FROM piot_get_shift_hour_begin_by_equipment($1, $2) s LIMIT 1), $8
	   FROM public.equipments e WHERE e.id_equipment = $1`

// execFanout is the single fail-open executor every fan-out write
// shares: success/missing-table(42P01)/failure land in the fan-out
// metric under destination+"-"+kind; failures warn and never propagate
// (loss-with-alert, ADR-0011 rule 5).
func (s *Staging) execFanout(ctx context.Context, pool *pgxpool.Pool, destination, kind, sql string, args ...any) {
	_, err := pool.Exec(ctx, sql, args...)
	if err == nil {
		metrics.ValueFanoutTotal.WithLabelValues(destination+kind, "ok").Inc()
		return
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
		metrics.ValueFanoutTotal.WithLabelValues(destination+kind, "missing_table").Inc()
		s.logger.Warn("fan-out: target table missing — fail-open",
			slog.String("destination", destination), slog.String("kind", kind))
		return
	}
	metrics.ValueFanoutTotal.WithLabelValues(destination+kind, "failed").Inc()
	s.logger.Warn("fan-out failed", slog.String("destination", destination),
		slog.String("kind", kind), slog.String("err", err.Error()))
}

// FanoutStateRow mirrors one prod state transition (from the events
// reconciler) as a state-bearing equipment_values row into the SHADOW
// flows only. Flow 1 must NOT get it: its equipment_events are already
// mirrored 1:1, and a state row would make its trigger pipeline mint a
// duplicate. The shadow flows have no trigger pipeline — their events
// come from the ADR-0014 deriver, which needs exactly this stream.
// Closed-loop bake: prod events -> state stream -> deriver -> derived
// events, expected to reproduce the mirrored events. Fail-open like
// every fan-out write.
func (s *Staging) FanoutStateRow(ctx context.Context, stagingEqID, enterpriseID, status int, ts time.Time) {
	if !s.valueFanout {
		return
	}
	s.execFanout(ctx, s.pool, "shadow_go_port", "-state",
		fmt.Sprintf(sqlInsertStateRow, "shadow_go_port"), stagingEqID, ts, enterpriseID, status)
	if s.shadowPool != nil {
		s.execFanout(ctx, s.shadowPool, "packiot_shadow", "-state",
			fmt.Sprintf(sqlInsertStateRow, "public"), stagingEqID, ts, enterpriseID, status)
	}
}

// FanoutEventRow mirrors one prod equipment_event into the SHADOW
// flows. Rationale (live finding, 2026-07-03): prod C-PACK equipments
// are status_type=0 — their events are PIPELINE-created (CPAC 30758=4
// algorithm), NOT derived by piot_review_* (which serves status_type=4
// only). Until the ADR-0010 10.4 port exists, the reconciler fan-out
// IS the staging stand-in for that pipeline path; the ADR-0014 deriver
// covers the status_type=4 class when such a tenant appears.
func (s *Staging) FanoutEventRow(ctx context.Context, stagingEqID, enterpriseID int, status *int, ts time.Time, tsEnd *time.Time, duration *int) {
	if !s.valueFanout {
		return
	}
	s.execFanout(ctx, s.pool, "shadow_go_port", "-event",
		fmt.Sprintf(sqlInsertShadowEvent, "shadow_go_port"), stagingEqID, ts, tsEnd, status, enterpriseID, duration)
	if s.shadowPool != nil {
		s.execFanout(ctx, s.shadowPool, "packiot_shadow", "-event",
			fmt.Sprintf(sqlInsertShadowEvent, "public"), stagingEqID, ts, tsEnd, status, enterpriseID, duration)
	}
}

const sqlInsertShadowEvent = `INSERT INTO %s.equipment_events
	       (id_equipment, ts_event, ts_end, status, id_enterprise, duration)
	 VALUES ($1, $2, $3, $4, $5, $6)
	 ON CONFLICT (id_equipment, ts_event) DO UPDATE
	    SET ts_end = EXCLUDED.ts_end, status = EXCLUDED.status, duration = EXCLUDED.duration`

// Same (ts_value, id_equipment) key as every equipment_values write; if
// a counter-delta row already occupies the second, enrich it with state
// instead of losing the transition.
const sqlInsertStateRow = `INSERT INTO %s.equipment_values
	       (id_equipment, ts_value, id_enterprise, id_site, id_area, state, tp_equipment, ts_value_production, id_shift, id_shift_hour)
	 SELECT $1, $2, $3, e.id_site, e.id_area, $4, e.tp_equipment,
	        (SELECT d.ts_value_production FROM piot_get_day_begin_by_equipment($1, $2) d LIMIT 1),
	        (SELECT s.id_shift FROM piot_get_shift_hour_begin_by_equipment($1, $2) s LIMIT 1),
	        (SELECT s.id_shift_hour FROM piot_get_shift_hour_begin_by_equipment($1, $2) s LIMIT 1)
	   FROM public.equipments e WHERE e.id_equipment = $1
	 ON CONFLICT (ts_value, id_equipment) DO UPDATE SET state = EXCLUDED.state`

// fanoutValueDelta writes one shadow copy of the delta row. Never
// returns an error — outcomes land in the fan-out metric + logs.
// 42P01 (table missing) is fail-open like shadow-mirror: deploy-order
// independence between this service and the schema migrations.
func (s *Staging) fanoutValueDelta(
	ctx context.Context, pool *pgxpool.Pool, schema, destination string,
	ts time.Time,
	stagingEqID, stagingSiteID, stagingAreaID, enterpriseID int,
	netDelta, grossDelta float64, stagingPOID int64,
) {
	s.execFanout(ctx, pool, destination, "",
		fmt.Sprintf(sqlInsertValueDelta, schema),
		stagingEqID, ts, enterpriseID, stagingSiteID, stagingAreaID, netDelta, grossDelta, stagingPOID)
}

// EnsureEventCursor seeds a mirror_replay_cursor row for the events
// reconciler if one doesn't exist yet. Returns the current cursor value.
// Uses ON CONFLICT DO NOTHING so it's safe to call on every boot.
//
// The events reconciler uses its OWN cursor source (e.g. cpack-prod-go-events)
// distinct from the user_logs cursor (cpack-prod-go). Two replay streams,
// two cursors — same table, same shape.
func (s *Staging) EnsureEventCursor(ctx context.Context, source string) (int64, error) {
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO mirror_replay_cursor (source, last_log_id, last_run_at)
		 VALUES ($1, 0, now())
		 ON CONFLICT (source) DO NOTHING`,
		source); err != nil {
		return 0, fmt.Errorf("seed event cursor: %w", err)
	}
	return s.ReadCursor(ctx, source)
}

// AdvanceCursorPool advances a cursor row outside any tx. Used by the
// events reconciler which doesn't run inside the per-row tx the user_logs
// dispatcher does (events are inserted with their mapping in one tx per
// row; the cursor advances at the end of the batch).
func (s *Staging) AdvanceCursorPool(ctx context.Context, source string, toID int64) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE mirror_replay_cursor
		    SET last_log_id = $1, last_run_at = now()
		  WHERE source = $2
		    AND last_log_id < $1`,
		toID, source)
	return err
}

// InsertEquipmentEventArgs is the parameter bundle for InsertEquipmentEvent.
// Using a struct (vs 18 positional args) so callers + tests can't transpose
// fields silently when adding columns later.
type InsertEquipmentEventArgs struct {
	IDEquipment         int
	IDEnterprise        int
	TsEvent             time.Time
	TsEnd               *time.Time
	Status              *int
	TxtDowntimeNotes    *string
	Idle                *string
	Fault               *int
	CdMachine           *string
	CdCategory          *string
	CdSubcategory       *string
	ChangeOver          *bool
	PlannedDowntime     *bool
	Duration            *int
	DescCategory        *string
	DescSubcategory     *string
	CdCategoryClient    *int
	CdSubcategoryClient *int
	IgnoreCost          *bool
}

// InsertEquipmentEvent INSERTs an equipment_events row carrying prod's
// metadata into staging. Returns the staging-side id_equipment_event
// (sequence-assigned). Always sets forced_creation_system=true so the
// piot_trig_equipment_events_update_prev trigger takes the bypass branch:
// close prior open events without dedup-rejecting our INSERT.
//
// Runs in caller's tx so the mirror_id_map INSERT lands atomically with
// the equipment_events row — no partial state if either fails.
func InsertEquipmentEvent(ctx context.Context, tx pgx.Tx, a InsertEquipmentEventArgs) (int64, error) {
	var stagingID int64
	err := tx.QueryRow(ctx,
		`INSERT INTO equipment_events
		       (id_equipment, ts_event, ts_end, status,
		        txt_downtime_notes, idle, fault,
		        cd_machine, cd_category, cd_subcategory,
		        change_over, planned_downtime, duration,
		        desc_category, desc_subcategory,
		        cd_category_client, cd_subcategory_client,
		        ignore_cost, id_enterprise, forced_creation_system)
		 VALUES ($1, $2, $3, $4,
		         $5, $6, $7,
		         $8, $9, $10,
		         $11, $12, $13,
		         $14, $15,
		         $16, $17,
		         $18, $19, true)
		 RETURNING id_equipment_event`,
		a.IDEquipment, a.TsEvent, a.TsEnd, a.Status,
		a.TxtDowntimeNotes, a.Idle, a.Fault,
		a.CdMachine, a.CdCategory, a.CdSubcategory,
		a.ChangeOver, a.PlannedDowntime, a.Duration,
		a.DescCategory, a.DescSubcategory,
		a.CdCategoryClient, a.CdSubcategoryClient,
		a.IgnoreCost, a.IDEnterprise,
	).Scan(&stagingID)
	if err != nil {
		return 0, fmt.Errorf("insert equipment_event: %w", err)
	}
	return stagingID, nil
}

// DLQRetryRow is the slim projection the retry loop needs. Same shape
// as mirror_replay_dlq columns the retrier touches; full payload + error
// stay in the table and never get round-tripped in memory.
type DLQRetryRow struct {
	ID            int64
	SourceLogID   int64
	Category      string
	RetryAttempts int
}

// FetchRetriableDLQ returns DLQ rows due for retry: under the attempt cap
// AND past their backoff window. Backoff = (1 << retry_attempts) minutes
// applied to last_retry_at; rows with last_retry_at IS NULL are
// immediately eligible (i.e. the row was just DLQ'd, no retry attempted
// yet).
//
// Ordered by id so a partial-progress batch makes forward progress —
// same idea as the existence reconciler's stable sort.
func (s *Staging) FetchRetriableDLQ(ctx context.Context, source string, maxAttempts, limit int) ([]DLQRetryRow, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, source_log_id, category, retry_attempts
		   FROM mirror_replay_dlq
		  WHERE source = $1
		    AND retry_attempts < $2
		    AND (last_retry_at IS NULL
		         OR last_retry_at + (interval '1 minute' * (1 << retry_attempts)) < now())
		  ORDER BY id
		  LIMIT $3`,
		source, maxAttempts, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query retriable DLQ rows: %w", err)
	}
	defer rows.Close()
	var out []DLQRetryRow
	for rows.Next() {
		var r DLQRetryRow
		if err := rows.Scan(&r.ID, &r.SourceLogID, &r.Category, &r.RetryAttempts); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// DeleteDLQRow removes one DLQ row by id. Called by the retry loop when
// a re-replay succeeds — DLQ should reflect the CURRENT state of stuck
// rows, not the historical state. Run in caller's tx so it's atomic
// with whatever the successful replay wrote.
func DeleteDLQRow(ctx context.Context, tx pgx.Tx, id int64) error {
	_, err := tx.Exec(ctx, `DELETE FROM mirror_replay_dlq WHERE id = $1`, id)
	return err
}

// MarkDLQRetried bumps retry_attempts + sets last_retry_at on a row that
// failed re-replay. Outside any tx because the failed replay's tx will
// have rolled back — we want this UPDATE to land regardless.
func (s *Staging) MarkDLQRetried(ctx context.Context, id int64) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE mirror_replay_dlq
		    SET retry_attempts = retry_attempts + 1,
		        last_retry_at  = now()
		  WHERE id = $1`,
		id)
	return err
}

// CountDLQ returns the count of DLQ rows for this source. Powers the
// mirror_worker_dlq_depth gauge — at-a-glance "how many bad rows are
// stuck right now" indicator on the Grafana mirror dashboard.
func (s *Staging) CountDLQ(ctx context.Context, source string) (int64, error) {
	var n int64
	_, err := s.SelectOne(ctx,
		`SELECT COUNT(*) FROM mirror_replay_dlq WHERE source = $1`,
		[]any{source}, &n)
	return n, err
}

// ReanimateMappableEquipmentEventDLQ resets retry_attempts=0 +
// last_retry_at=NULL on DLQ rows that:
//
//   - belong to this worker's source,
//   - sit at or above the retry cap (so the DLQRetrier loop no longer
//     touches them),
//   - and carry a payload whose `idEquipmentEvent` is NOW present in
//     mirror_id_map (the events reconciler caught up to that prod ID
//     while the entry was waiting in the DLQ).
//
// After the reset, the row is immediately eligible for the existing
// DLQRetrier loop (retry_attempts < cap AND last_retry_at IS NULL),
// which will re-dispatch through the original handler. The handler
// translates via translate.EquipmentEvent → mirror_id_map cache hit →
// succeeds, DLQ row deleted in the same tx.
//
// Idempotent: a repeat run only matches rows still past the cap, so
// already-reanimated rows aren't double-touched. Scoped to the four
// equipment_event-shaped categories — order-* categories carry
// `idProductionOrder` instead and would need a sibling reanimator.
//
// Returns the IDs of the rows reanimated, ordered by id, capped at
// `limit` rows per pass so a backlog of thousands can't dominate a
// single tick.
func (s *Staging) ReanimateMappableEquipmentEventDLQ(ctx context.Context, source string, maxAttempts, limit int) ([]int64, error) {
	rows, err := s.pool.Query(ctx,
		`UPDATE mirror_replay_dlq d
		    SET retry_attempts = 0,
		        last_retry_at  = NULL
		  WHERE d.id IN (
		    SELECT id FROM mirror_replay_dlq
		     WHERE source = $1
		       AND retry_attempts >= $2
		       AND category IN ('event-justified', 'event-edited',
		                        'event-splitted', 'downtime-event-created')
		       AND EXISTS (
		         SELECT 1 FROM mirror_id_map m
		          WHERE m.entity_type = 'equipment_event'
		            AND m.source = mirror_replay_dlq.source
		            AND m.prod_id = (mirror_replay_dlq.payload->>'idEquipmentEvent')::bigint
		       )
		     ORDER BY id
		     LIMIT $3
		  )
		  RETURNING id`,
		source, maxAttempts, limit)
	if err != nil {
		return nil, fmt.Errorf("reanimate mappable DLQ: %w", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan reanimated id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// WriteDLQ appends an unreplayable row for human inspection. Runs in
// caller's tx so we don't lose visibility into a bad row that crashed
// before the outer commit.
//
// retryAttempts seeds the row's retry_attempts column:
//   - 0            — the normal transient-failure case: the row is
//     immediately eligible for the DLQRetrier's first retry pass.
//   - >= the cap   — a TERMINAL failure (e.g. an edge-api PR #148 gate
//     reject): the row is written PRE-RETIRED so FetchRetriableDLQ
//     (retry_attempts < cap) never selects it. It stays in the tray for
//     human review but is never re-driven.
func WriteDLQ(ctx context.Context, tx pgx.Tx,
	source string, sourceLogID int64, category string, subcategory *string,
	payload []byte, errMsg string, retryAttempts int,
) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO mirror_replay_dlq
		       (source, source_log_id, category, subcategory, payload, error, retry_attempts)
		 VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)`,
		source, sourceLogID, category, subcategory, string(payload), errMsg, retryAttempts)
	return err
}

// RetireDLQRow bumps a DLQ row's retry_attempts to (at least) the cap so
// FetchRetriableDLQ (retry_attempts < cap) never selects it again — the
// row stays in the tray for human review but the DLQRetrier stops
// re-driving it. Used for a TERMINAL failure discovered DURING a retry
// pass: a row DLQ'd under the old masked-500 regime that now, post
// edge-api PR #148, comes back as a clean 409 gate reject. GREATEST()
// guards against ever lowering an already-higher counter. Runs outside any
// tx (the failed replay's tx rolled back), same as MarkDLQRetried.
func (s *Staging) RetireDLQRow(ctx context.Context, id int64, retiredAttempts int) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE mirror_replay_dlq
		    SET retry_attempts = GREATEST(retry_attempts, $2),
		        last_retry_at  = now()
		  WHERE id = $1`,
		id, retiredAttempts)
	return err
}

// SumInjectedPOValues returns the cumulative (net, gross) increments
// attributed to a staging PO across F1 equipment_values. Value-sync
// measures convergence against ITS OWN injections (+ any other
// attributed rows) instead of the staging PO's downstream-processed
// value — the latter goes 0-forever when injected rows land outside
// the PO's runtime windows, turning the delta into an unbounded
// re-injector (the 139M/shift slow-oscillator: 546 ticks × 254k).
func (s *Staging) SumInjectedPOValues(ctx context.Context, stagingPOID int64) (net, gross float64, err error) {
	err = s.pool.QueryRow(ctx, `
		SELECT COALESCE(sum(net_production_incr), 0), COALESCE(sum(gross_production_incr), 0)
		  FROM public.equipment_values
		 WHERE id_production_order = $1`, stagingPOID).Scan(&net, &gross)
	return net, gross, err
}
