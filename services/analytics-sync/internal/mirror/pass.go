package mirror

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// advisoryKey namespaces the per-enterprise transaction lock: two reflector instances never converge the same
// tenant at once (a rolling recreate overlaps old and new containers).
const advisoryKey = 724064

const upsertChunk = 500

// Reflector converges ONE enterprise. src = production (read-only role, REPEATABLE READ snapshot), dst = staging.
type Reflector struct {
	cfg *Config
	ent int
	src *pgxpool.Pool
	dst *pgxpool.Pool
	m   *Metrics
	log *slog.Logger

	lastFull      time.Time
	lastConverged time.Time
	lastWritten   map[string]map[string]string // table → key → production hash the reflector wrote
	lastDeleted   map[string]map[string]bool   // table → keys the reflector deleted
	reported      map[string]bool              // skip/missing-column notices already logged
	Unclassified  []string
}

// NewReflector builds a reflector for one enterprise.
func NewReflector(cfg *Config, ent int, src, dst *pgxpool.Pool, m *Metrics, log *slog.Logger) *Reflector {
	return &Reflector{cfg: cfg, ent: ent, src: src, dst: dst, m: m, log: log.With(slog.Int("enterprise", ent)),
		lastWritten: map[string]map[string]string{}, lastDeleted: map[string]map[string]bool{}, reported: map[string]bool{}}
}

// PassResult summarises one pass.
type PassResult struct {
	Kind          string
	Converged     bool
	Tables        int // tables compared
	Changed       int // tables with differing buckets
	Upserts       int
	Deletes       int
	Divergent     int
	Guarded       int
	Errors        int
	Unconverged   int // tables still differing after the pass (read back in the same transaction)
	StagingWrites int
	Skipped       bool // another instance holds the lock
}

type pendingDelete struct {
	p    *plan
	keys []string
}

// ErrNoEnterprise: production has no row for the enterprise — refuse to converge (it would delete everything).
var ErrNoEnterprise = errors.New("production has no such enterprise")

// Pass runs one convergence pass. full = every bucket of every table; otherwise hot (time tables: lookback only).
func (r *Reflector) Pass(ctx context.Context, full bool) (*PassResult, error) {
	res := &PassResult{Kind: "hot"}
	if full {
		res.Kind = "full"
	}
	start := time.Now()
	ent := r.ent

	srcTx, err := r.src.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("production snapshot: %w", err)
	}
	defer srcTx.Rollback(ctx) //nolint:errcheck // read-only snapshot
	if _, err := srcTx.Exec(ctx, fmt.Sprintf("SET LOCAL statement_timeout = '%ds'", int(r.cfg.StatementTimeout.Seconds()))); err != nil {
		return nil, err
	}
	var n int
	if err := srcTx.QueryRow(ctx, "SELECT count(*) FROM core.enterprises WHERE id_enterprise = "+itoa(ent)).Scan(&n); err != nil {
		return nil, fmt.Errorf("production enterprise check: %w", err)
	}
	if n != 1 {
		return nil, fmt.Errorf("%w: enterprise %d (rows %d)", ErrNoEnterprise, ent, n)
	}
	srcCat, err := ReadCatalog(ctx, srcTx)
	if err != nil {
		return nil, fmt.Errorf("production %w", err)
	}

	dstTx, err := r.dst.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("staging begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = dstTx.Rollback(ctx)
		}
	}()
	for _, s := range []string{
		fmt.Sprintf("SET LOCAL statement_timeout = '%ds'", int(r.cfg.StatementTimeout.Seconds())),
		"SET LOCAL lock_timeout = '5s'",
	} {
		if _, err := dstTx.Exec(ctx, s); err != nil {
			return nil, err
		}
	}
	var locked bool
	if err := dstTx.QueryRow(ctx, fmt.Sprintf("SELECT pg_try_advisory_xact_lock(%d, %d)", advisoryKey, ent)).Scan(&locked); err != nil {
		return nil, fmt.Errorf("staging lock: %w", err)
	}
	if !locked {
		res.Skipped = true
		return res, nil
	}
	dstCat, err := ReadCatalog(ctx, dstTx)
	if err != nil {
		return nil, fmt.Errorf("staging %w", err)
	}
	r.Unclassified = Unclassified(dstCat)

	var pending []pendingDelete
	servingDays := map[string]bool{}
	type changedT struct {
		p       *plan
		hot     bool
		buckets []string
		src     map[string]Fingerprint
	}
	var changed []changedT
	wrote := map[string]map[string]string{}
	deleted := map[string]map[string]bool{}

	for _, t := range Reflected {
		p, why := buildPlan(t, srcCat, dstCat, r.cfg.LookbackDays, r.cfg.NameSuffix)
		if p == nil {
			if why != "absent on both sides" {
				r.once("skip "+t.Name, "table not reflected", slog.String("table", t.Name), slog.String("why", why))
			}
			continue
		}
		if len(p.missing) > 0 {
			r.once("cols "+t.Name, "columns on one side only are not mirrored", slog.String("table", t.Name),
				slog.String("columns", strings.Join(p.missing, ", ")))
		}
		res.Tables++
		hot := !full && t.Hot
		srcFP, err := fingerprints(ctx, srcTx, p.fingerprintSQL("src", ent, hot))
		if err != nil {
			return nil, fmt.Errorf("production fingerprint %s: %w", t.Name, err)
		}
		sp := "sp_" + strconv.Itoa(res.Tables)
		if _, err := dstTx.Exec(ctx, "SAVEPOINT "+sp); err != nil {
			return nil, err
		}
		dstFP, err := fingerprints(ctx, dstTx, p.fingerprintSQL("dst", ent, hot))
		if err != nil {
			r.tableError(dstTx, sp, t.Name, "staging fingerprint", err, res)
			continue
		}
		buckets := DiffBuckets(srcFP, dstFP)
		if len(buckets) == 0 {
			_, _ = dstTx.Exec(ctx, "RELEASE SAVEPOINT "+sp)
			continue
		}
		res.Changed++
		changed = append(changed, changedT{p: p, hot: hot, buckets: buckets, src: srcFP})
		if t.Serving {
			for _, b := range buckets {
				servingDays[b] = true
			}
		}

		if len(p.key) == 0 {
			if err := r.replaceBuckets(ctx, srcTx, dstTx, p, hot, buckets, dstFP, res); err != nil {
				r.tableError(dstTx, sp, t.Name, "replace buckets", err, res)
				continue
			}
			_, _ = dstTx.Exec(ctx, "RELEASE SAVEPOINT "+sp)
			continue
		}

		srcRows, err := srcRowsOf(ctx, srcTx, p.rowsSQL("src", ent, hot), buckets)
		if err != nil {
			return nil, fmt.Errorf("production rows %s: %w", t.Name, err)
		}
		dstRows, err := dstRowsOf(ctx, dstTx, p.rowsSQL("dst", ent, hot), buckets)
		if err != nil {
			r.tableError(dstTx, sp, t.Name, "staging rows", err, res)
			continue
		}
		ops := DiffRows(srcRows, dstRows, t.Mode)
		if sw := StagingWrites(ops, srcRows, r.lastWritten[t.Name], r.lastDeleted[t.Name]); sw > 0 {
			res.StagingWrites += sw
			r.m.StagingWrites.WithLabelValues(itoa(ent), t.Name).Add(float64(sw))
			r.log.Warn("mirrored rows were changed ON STAGING since the last pass (a write surface the block missed); "+
				"production wins", slog.String("table", t.Name), slog.Int("rows", sw))
		}
		res.Divergent += ops.Divergent
		if ops.Divergent > 0 {
			r.m.Rows.WithLabelValues(itoa(ent), t.Name, "divergent").Add(float64(ops.Divergent))
		}
		if len(ops.Upsert) > 0 {
			if err := r.upsert(ctx, dstTx, p, ops.Upsert, srcRows); err != nil {
				r.tableError(dstTx, sp, t.Name, "upsert", err, res)
				continue
			}
			res.Upserts += len(ops.Upsert)
			r.m.Rows.WithLabelValues(itoa(ent), t.Name, "upsert").Add(float64(len(ops.Upsert)))
			w := map[string]string{}
			for _, k := range ops.Upsert {
				w[k] = srcRows[k].Hash
			}
			wrote[t.Name] = w
		}
		_, _ = dstTx.Exec(ctx, "RELEASE SAVEPOINT "+sp)

		if len(ops.Delete) > 0 {
			var srcTotal, dstTotal int64
			for _, f := range srcFP {
				srcTotal += f.N
			}
			for _, f := range dstFP {
				dstTotal += f.N
			}
			switch {
			case srcTotal == 0 && dstTotal > 10:
				// production returned NOTHING for a table staging has rows in: a missing tenant stamp, a revoked
				// grant or an RLS change looks exactly like this. Never mass-delete on it.
				r.guard(t.Name, "empty_source", len(ops.Delete), res)
			case len(ops.Delete) > r.cfg.MaxDeletes:
				r.guard(t.Name, "max_deletes", len(ops.Delete), res)
			default:
				pending = append(pending, pendingDelete{p: p, keys: ops.Delete})
			}
		}
	}

	// deletes: children first (reverse foreign-key order)
	for i := len(pending) - 1; i >= 0; i-- {
		d := pending[i]
		sp := "spd_" + strconv.Itoa(i)
		if _, err := dstTx.Exec(ctx, "SAVEPOINT "+sp); err != nil {
			return nil, err
		}
		nDel, err := r.deleteKeys(ctx, dstTx, d.p, d.keys)
		if err != nil {
			r.tableError(dstTx, sp, d.p.t.Name, "delete", err, res)
			continue
		}
		_, _ = dstTx.Exec(ctx, "RELEASE SAVEPOINT "+sp)
		res.Deletes += nDel
		r.m.Rows.WithLabelValues(itoa(ent), d.p.t.Name, "delete").Add(float64(nDel))
		dm := map[string]bool{}
		for _, k := range d.keys {
			dm[k] = true
		}
		deleted[d.p.t.Name] = dm
	}

	// serving.downtime_events_resolved is built from the events: re-resolve the changed days for this tenant (the
	// function's DELETE and INSERT both pass the table's FORCE RLS, so other tenants are untouched).
	if from, to, ok := dayRange(servingDays); ok {
		if _, err := dstTx.Exec(ctx, "SAVEPOINT sp_serving"); err != nil {
			return nil, err
		}
		if _, err := dstTx.Exec(ctx, "SELECT serving.refresh_downtime_events_resolved($1::timestamptz, $2::timestamptz)",
			from.Format(time.RFC3339), to.Format(time.RFC3339)); err != nil {
			r.tableError(dstTx, "sp_serving", "serving.downtime_events_resolved", "refresh", err, res)
		} else {
			_, _ = dstTx.Exec(ctx, "RELEASE SAVEPOINT sp_serving")
		}
	}

	// read back what was changed, in the same transaction: a statement that "succeeded" without converging
	// (e.g. DML that silently matched 0 rows on a compressed chunk) shows up here, not in a customer report.
	for _, c := range changed {
		after, err := fingerprints(ctx, dstTx, c.p.fingerprintSQL("dst", ent, c.hot))
		if err != nil {
			return nil, fmt.Errorf("read back %s: %w", c.p.t.Name, err)
		}
		if c.p.t.Mode == AppendOnly {
			continue // divergence is reported, not converged
		}
		for _, b := range c.buckets {
			if after[b] != c.src[b] {
				res.Unconverged++
				r.log.Warn("table not converged after the pass", slog.String("table", c.p.t.Name), slog.String("bucket", b))
				break
			}
		}
	}

	if r.cfg.DryRun {
		_ = dstTx.Rollback(ctx)
		committed = true
	} else {
		if err := dstTx.Commit(ctx); err != nil {
			return nil, fmt.Errorf("staging commit: %w", err)
		}
		committed = true
		r.remember(wrote, deleted)
	}
	res.Converged = res.Errors == 0 && res.Guarded == 0 && res.Unconverged == 0 && !r.cfg.DryRun
	r.m.PassSeconds.WithLabelValues(itoa(ent), res.Kind).Set(time.Since(start).Seconds())
	return res, nil
}

func (r *Reflector) once(key, msg string, attrs ...any) {
	if r.reported[key] {
		return
	}
	r.reported[key] = true
	r.log.Info(msg, attrs...)
}

func (r *Reflector) tableError(tx pgx.Tx, sp, table, step string, err error, res *PassResult) {
	_, _ = tx.Exec(context.Background(), "ROLLBACK TO SAVEPOINT "+sp)
	res.Errors++
	r.m.TableErrors.WithLabelValues(itoa(r.ent), table).Inc()
	r.log.Error("table not converged this pass (rolled back to its savepoint; the pass continues)",
		slog.String("table", table), slog.String("step", step), slog.String("err", err.Error()))
}

func (r *Reflector) guard(table, reason string, n int, res *PassResult) {
	res.Guarded++
	r.m.Guarded.WithLabelValues(itoa(r.ent), table, reason).Inc()
	r.log.Error("deletes refused by a guard — staging keeps the rows; investigate before raising PROD_REFLECT_MAX_DELETES",
		slog.String("table", table), slog.String("reason", reason), slog.Int("rows", n))
}

// remember keeps what this pass wrote/deleted (bounded) for the staging-write detector.
func (r *Reflector) remember(wrote map[string]map[string]string, deleted map[string]map[string]bool) {
	const capRows = 200000
	for t, w := range wrote {
		m := r.lastWritten[t]
		if m == nil || len(m) > capRows {
			m = map[string]string{}
		}
		for k, h := range w {
			m[k] = h
		}
		r.lastWritten[t] = m
	}
	for t, d := range deleted {
		m := r.lastDeleted[t]
		if m == nil || len(m) > capRows {
			m = map[string]bool{}
		}
		for k := range d {
			m[k] = true
		}
		r.lastDeleted[t] = m
	}
}

func fingerprints(ctx context.Context, q Querier, sql string) (map[string]Fingerprint, error) {
	rows, err := q.Query(ctx, sql)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]Fingerprint{}
	for rows.Next() {
		var b, h string
		var n int64
		if err := rows.Scan(&b, &n, &h); err != nil {
			return nil, err
		}
		out[b] = Fingerprint{N: n, MD5: h}
	}
	return out, rows.Err()
}

func srcRowsOf(ctx context.Context, q Querier, sql string, buckets []string) (map[string]SrcRow, error) {
	rows, err := q.Query(ctx, sql, buckets)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]SrcRow{}
	for rows.Next() {
		var k, h, row string
		if err := rows.Scan(&k, &h, &row); err != nil {
			return nil, err
		}
		out[k] = SrcRow{Hash: h, Row: row}
	}
	return out, rows.Err()
}

func dstRowsOf(ctx context.Context, q Querier, sql string, buckets []string) (map[string]string, error) {
	rows, err := q.Query(ctx, sql, buckets)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, h string
		if err := rows.Scan(&k, &h); err != nil {
			return nil, err
		}
		out[k] = h
	}
	return out, rows.Err()
}

func jsonArray(rows []string) string { return "[" + strings.Join(rows, ",") + "]" }

func (r *Reflector) upsert(ctx context.Context, tx pgx.Tx, p *plan, keys []string, src map[string]SrcRow) error {
	for i := 0; i < len(keys); i += upsertChunk {
		j := min(i+upsertChunk, len(keys))
		batch := make([]string, 0, j-i)
		for _, k := range keys[i:j] {
			batch = append(batch, src[k].Row)
		}
		if _, err := tx.Exec(ctx, p.upsertSQL(), jsonArray(batch)); err != nil {
			return err
		}
	}
	if len(p.selfRef) == 0 {
		return nil
	}
	for i := 0; i < len(keys); i += upsertChunk {
		j := min(i+upsertChunk, len(keys))
		batch := make([]string, 0, j-i)
		for _, k := range keys[i:j] {
			batch = append(batch, src[k].Row)
		}
		if _, err := tx.Exec(ctx, p.selfRefSQL(), jsonArray(batch)); err != nil {
			return fmt.Errorf("self references: %w", err)
		}
	}
	return nil
}

// keyValues decodes a key (a jsonb array) into literal parameters. Numbers stay strings (json.Number): a bigint
// such as 9000002449267960 must not round-trip through float64.
func keyValues(k string) ([]any, error) {
	dec := json.NewDecoder(strings.NewReader(k))
	dec.UseNumber()
	var vals []any
	if err := dec.Decode(&vals); err != nil {
		return nil, fmt.Errorf("key %s: %w", k, err)
	}
	out := make([]any, len(vals))
	for i, v := range vals {
		switch x := v.(type) {
		case json.Number:
			out[i] = x.String()
		case string:
			out[i] = x
		case bool:
			out[i] = strconv.FormatBool(x)
		case nil:
			return nil, fmt.Errorf("key %s: NULL key column", k)
		default:
			b, _ := json.Marshal(x)
			out[i] = string(b)
		}
	}
	return out, nil
}

func (r *Reflector) deleteKeys(ctx context.Context, tx pgx.Tx, p *plan, keys []string) (int, error) {
	sql := p.deleteSQL(r.ent)
	n := 0
	for _, k := range keys {
		args, err := keyValues(k)
		if err != nil {
			return n, err
		}
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return n, err
		}
		n += int(tag.RowsAffected())
	}
	return n, nil
}

// replaceBuckets converges a table without a primary key: each differing bucket is emptied and refilled.
func (r *Reflector) replaceBuckets(ctx context.Context, srcTx, dstTx pgx.Tx, p *plan, hot bool, buckets []string,
	dstFP map[string]Fingerprint, res *PassResult) error {
	var dstRows int64
	for _, b := range buckets {
		dstRows += dstFP[b].N
	}
	if dstRows > int64(r.cfg.MaxDeletes) {
		r.guard(p.t.Name, "max_deletes", int(dstRows), res)
		return nil
	}
	rows, err := srcTx.Query(ctx, p.srcBucketRowsSQL(r.ent, hot), buckets)
	if err != nil {
		return fmt.Errorf("production rows: %w", err)
	}
	byBucket := map[string][]string{}
	for rows.Next() {
		var b, row string
		if err := rows.Scan(&b, &row); err != nil {
			rows.Close()
			return err
		}
		byBucket[b] = append(byBucket[b], row)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, b := range buckets {
		tag, err := dstTx.Exec(ctx, p.deleteBucketSQL(r.ent, hot), b)
		if err != nil {
			return err
		}
		res.Deletes += int(tag.RowsAffected())
		src := byBucket[b]
		for i := 0; i < len(src); i += upsertChunk {
			j := min(i+upsertChunk, len(src))
			if _, err := dstTx.Exec(ctx, p.upsertSQL(), jsonArray(src[i:j])); err != nil {
				return err
			}
		}
		res.Upserts += len(src)
		r.m.Rows.WithLabelValues(itoa(r.ent), p.t.Name, "upsert").Add(float64(len(src)))
	}
	return nil
}

// dayRange turns 'YYYY-MM-DD' buckets into [first day, last day + 1).
func dayRange(days map[string]bool) (time.Time, time.Time, bool) {
	var ds []time.Time
	for d := range days {
		t, err := time.Parse("2006-01-02", d)
		if err == nil {
			ds = append(ds, t)
		}
	}
	if len(ds) == 0 {
		return time.Time{}, time.Time{}, false
	}
	sort.Slice(ds, func(i, j int) bool { return ds[i].Before(ds[j]) })
	return ds[0], ds[len(ds)-1].AddDate(0, 0, 1), true
}
