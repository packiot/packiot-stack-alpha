package mirror

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Invariant is one ops.data_invariant_result row (t-data-invariants; alerts through DataInvariantCritical/Warn).
type Invariant struct {
	CheckID   string
	Dimension string
	Layer     string
	Severity  string
	Observed  float64
	Expected  string
	OK        bool
	Detail    string
}

// group of reflected tables an invariant compares in full.
func configTables() []Table {
	var out []Table
	for _, t := range Reflected {
		s, _, _ := strings.Cut(t.Name, ".")
		if s == "core" || s == "config" || s == "identity" {
			if t.Name == "core.production_orders" || t.Name == "core.po_number_corrections" {
				continue
			}
			out = append(out, t)
		}
	}
	return out
}

func poTables() []Table {
	var out []Table
	for _, t := range Reflected {
		switch t.Name {
		case "core.production_orders", "core.po_number_corrections", "gold.production_orders_runtime", "gold.po_box_counter":
			out = append(out, t)
		}
	}
	return out
}

// Invariants computes MR1–MR5 for the reflector's enterprise:
//
//	MR1_prod_mirror_config  (critical) tenant configuration (hierarchy, reasons, shifts, products, targets, users)
//	                                   equal to production — observed = tables that differ
//	MR2_prod_mirror_pos     (critical) production orders + runtime + box counters equal — observed = tables that differ
//	MR3_prod_mirror_lag     (critical) seconds since the last pass that left staging equal to production ≤ MaxLag
//	MR4_prod_id_block       (critical) every id staging mints stays below PROD_ID_BLOCK and every production sequence
//	                                   of a reflected table is at/above it (no id can collide) — observed = violations
//	MR5_prod_mirror_unclassified (warn) tenant-keyed tables neither reflected nor local — observed = count
func (r *Reflector) Invariants(ctx context.Context) ([]Invariant, error) {
	srcTx, err := r.src.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer srcTx.Rollback(ctx) //nolint:errcheck
	dstTx, err := r.dst.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer dstTx.Rollback(ctx) //nolint:errcheck
	srcCat, err := ReadCatalog(ctx, srcTx)
	if err != nil {
		return nil, err
	}
	dstCat, err := ReadCatalog(ctx, dstTx)
	if err != nil {
		return nil, err
	}
	compare := func(ts []Table) (int, []string, error) {
		var diff []string
		for _, t := range ts {
			p, _ := buildPlan(t, srcCat, dstCat, r.cfg.LookbackDays, r.cfg.NameSuffix)
			if p == nil {
				continue
			}
			s, err := fingerprints(ctx, srcTx, p.fingerprintSQL("src", r.ent, false))
			if err != nil {
				return 0, nil, fmt.Errorf("%s: %w", t.Name, err)
			}
			d, err := fingerprints(ctx, dstTx, p.fingerprintSQL("dst", r.ent, false))
			if err != nil {
				return 0, nil, fmt.Errorf("%s: %w", t.Name, err)
			}
			if len(DiffBuckets(s, d)) > 0 {
				diff = append(diff, t.Name)
			}
		}
		return len(diff), diff, nil
	}
	var out []Invariant
	nCfg, cfgDiff, err := compare(configTables())
	if err != nil {
		return nil, err
	}
	out = append(out, Invariant{CheckID: "MR1_prod_mirror_config", Dimension: "consistency", Layer: "core",
		Severity: "critical", Observed: float64(nCfg), Expected: "0 tables differ", OK: nCfg == 0,
		Detail: "staging mirrors production (ADR-0064); differing: " + strings.Join(cfgDiff, ", ")})
	nPO, poDiff, err := compare(poTables())
	if err != nil {
		return nil, err
	}
	out = append(out, Invariant{CheckID: "MR2_prod_mirror_pos", Dimension: "consistency", Layer: "core",
		Severity: "critical", Observed: float64(nPO), Expected: "0 tables differ", OK: nPO == 0,
		Detail: "production orders/runtime/box counters vs production; differing: " + strings.Join(poDiff, ", ")})

	lag := time.Since(r.lastConverged)
	if r.lastConverged.IsZero() {
		lag = 365 * 24 * time.Hour
	}
	out = append(out, Invariant{CheckID: "MR3_prod_mirror_lag", Dimension: "timeliness", Layer: "core",
		Severity: "critical", Observed: lag.Round(time.Second).Seconds(),
		Expected: fmt.Sprintf("<= %d s", int(r.cfg.MaxLag.Seconds())), OK: lag <= r.cfg.MaxLag,
		Detail: "seconds since the last pass that left staging equal to production"})

	viol, detail, err := r.idBlock(ctx, srcTx, dstTx)
	if err != nil {
		return nil, err
	}
	out = append(out, Invariant{CheckID: "MR4_prod_id_block", Dimension: "uniqueness", Layer: "core",
		Severity: "critical", Observed: float64(viol), Expected: "0", OK: viol == 0, Detail: detail})

	out = append(out, Invariant{CheckID: "MR5_prod_mirror_unclassified", Dimension: "completeness", Layer: "core",
		Severity: "warn", Observed: float64(len(r.Unclassified)), Expected: "0", OK: len(r.Unclassified) == 0,
		Detail: "tenant-keyed tables neither reflected nor local (services/analytics-sync/internal/mirror/spec.go): " +
			strings.Join(r.Unclassified, ", ")})
	return out, nil
}

// sequences owned by reflected tables, with their last value (NULL = never used, or no privilege).
const seqSQL = `
SELECT s.schemaname || '.' || s.sequencename, s.last_value
  FROM pg_sequences s
  JOIN pg_namespace sn ON sn.nspname = s.schemaname
  JOIN pg_class sc ON sc.relnamespace = sn.oid AND sc.relname = s.sequencename
  JOIN pg_depend d ON d.objid = sc.oid AND d.deptype IN ('a', 'i')
  JOIN pg_class tc ON tc.oid = d.refobjid
  JOIN pg_namespace tn ON tn.oid = tc.relnamespace
 WHERE tn.nspname || '.' || tc.relname = ANY($1::text[])`

func reflectedNames() []string {
	out := make([]string, len(Reflected))
	for i, t := range Reflected {
		out[i] = t.Name
	}
	return out
}

// idBlock: staging sequences must be below the block (staging-native ids never reach production's range) and
// production sequences at/above it (production never mints an id staging could also mint).
func (r *Reflector) idBlock(ctx context.Context, srcTx, dstTx pgx.Tx) (int, string, error) {
	block := r.cfg.IDBlock
	var bad []string
	read := func(tx pgx.Tx, side string, below bool) error {
		rows, err := tx.Query(ctx, seqSQL, reflectedNames())
		if err != nil {
			return fmt.Errorf("%s sequences: %w", side, err)
		}
		defer rows.Close()
		for rows.Next() {
			var name string
			var last *int64
			if err := rows.Scan(&name, &last); err != nil {
				return err
			}
			switch {
			case below && last != nil && *last >= block:
				bad = append(bad, fmt.Sprintf("staging %s=%d", name, *last))
			case !below && (last == nil || *last < block):
				v := "unset"
				if last != nil {
					v = fmt.Sprint(*last)
				}
				bad = append(bad, fmt.Sprintf("production %s=%s", name, v))
			}
		}
		return rows.Err()
	}
	if err := read(dstTx, "staging", true); err != nil {
		return 0, "", err
	}
	if err := read(srcTx, "production", false); err != nil {
		return 0, "", err
	}
	return len(bad), fmt.Sprintf("PROD_ID_BLOCK=%d; violations: %s", block, strings.Join(bad, ", ")), nil
}

// RecordInvariants writes the rows (source prod-reflector). Never in dry-run: staging is not converged then.
func (r *Reflector) RecordInvariants(ctx context.Context, inv []Invariant) error {
	if r.cfg.DryRun {
		for _, i := range inv {
			r.log.Info("invariant (dry run, not recorded)", slog.String("check", i.CheckID), slog.Bool("ok", i.OK),
				slog.Float64("observed", i.Observed), slog.String("detail", i.Detail))
		}
		return nil
	}
	b := &pgx.Batch{}
	for _, i := range inv {
		b.Queue(`INSERT INTO ops.data_invariant_result
		           (run_at, check_id, dimension, layer, severity, id_enterprise, observed, expected, ok, detail, source)
		         VALUES (now(), $1, $2, $3, $4, $5, $6, $7, $8, $9, 'prod-reflector')`,
			i.CheckID, i.Dimension, i.Layer, i.Severity, r.ent, i.Observed, i.Expected, i.OK, truncate(i.Detail, 2000))
	}
	return r.dst.SendBatch(ctx, b).Close()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
