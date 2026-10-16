package main

// coverage.go — T2 of docs/plans/unified-hot-cold-serving-grain-tiered-retention.md:
// HONEST WINDOWS. Every named dataset reads some set of analytics relations; each
// relation has a declared lifetime in ops.retention_policy (T0). A request whose
// window starts before the most restrictive of those lifetimes gets a SHORT answer
// from the DB — silently, before this file. Now the response says so.
//
// SELF-MAINTAINING, no hand-kept mapping: at boot and every coverageRefresh the index
// loads (1) the bounded relations from ops.retention_policy and (2) the definitions
// of the serving.* functions the datasets call, and resolves each dataset's minimum
// keep by matching relation names in its SQL + the called functions' bodies (two
// levels deep). Change the catalog → the headers follow. Unbounded relations (keep
// NULL, e.g. gold.equipment_oee_shift) never produce a floor.
//
// WIRE CONTRACT (headers, NOT body — /v1/query returns a bare JSON array that front4
// parses; a body envelope would break every caller):
//   X-Data-Hot-Floor: <RFC3339>   earliest instant this dataset can fully answer
//   X-Data-Truncated: true        the requested window starts before that floor
//   Warning: 299 read-api "..."   RFC 7234 free-text explanation (human/debug)
// Access-Control-Expose-Headers lists them so browser JS (front4) can read them.
//
// FAIL-OPEN: if the catalog can't be read (role lacks grant, table absent), the
// index stays empty and read-api behaves exactly as before (no headers). Coverage
// is metadata; it must never fail a query.

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const coverageRefresh = 10 * time.Minute

// relKeep is one bounded relation from ops.retention_policy.
type relKeep struct {
	relation string // schema-qualified, e.g. silver.equipment_categorical_1hour
	keep     time.Duration
}

type datasetCoverage struct {
	keep     time.Duration // most restrictive keep among the relations it reads
	relation string        // the relation that imposes it (for the Warning text)
}

type coverageIndex struct {
	mu    sync.RWMutex
	byDS  map[string]datasetCoverage
	byRel map[string]time.Duration // relation name (unqualified) → keep, for the composer
}

var covIdx = &coverageIndex{byDS: map[string]datasetCoverage{}, byRel: map[string]time.Duration{}}

var servingCallRe = regexp.MustCompile(`(?i)\bserving\.([a-z_][a-z0-9_]*)\s*\(`)

// resolveCoverage is the PURE core (unit-tested): given the bounded relations, the
// serving function bodies, and each dataset's SQL, return each dataset's most
// restrictive keep. Functions are expanded two levels (a serving fn calling another).
func resolveCoverage(rels []relKeep, fnDefs map[string]string, dsSQL map[string]string) map[string]datasetCoverage {
	type relRe struct {
		rk relKeep
		re *regexp.Regexp
	}
	var matchers []relRe
	for _, rk := range rels {
		name := rk.relation
		if i := strings.LastIndex(name, "."); i >= 0 {
			name = name[i+1:]
		}
		matchers = append(matchers, relRe{rk, regexp.MustCompile(`(?i)\b` + regexp.QuoteMeta(name) + `\b`)})
	}
	expand := func(sql string) string {
		var b strings.Builder
		b.WriteString(sql)
		seen := map[string]bool{}
		frontier := []string{sql}
		for depth := 0; depth < 2; depth++ {
			var next []string
			for _, text := range frontier {
				for _, m := range servingCallRe.FindAllStringSubmatch(text, -1) {
					fn := strings.ToLower(m[1])
					if seen[fn] {
						continue
					}
					seen[fn] = true
					if def, ok := fnDefs[fn]; ok {
						b.WriteString("\n")
						b.WriteString(def)
						next = append(next, def)
					}
				}
			}
			frontier = next
		}
		return b.String()
	}
	out := map[string]datasetCoverage{}
	for ds, sql := range dsSQL {
		text := expand(sql)
		var best datasetCoverage
		for _, m := range matchers {
			if m.re.MatchString(text) && (best.keep == 0 || m.rk.keep < best.keep) {
				best = datasetCoverage{keep: m.rk.keep, relation: m.rk.relation}
			}
		}
		if best.keep > 0 {
			out[ds] = best
		}
	}
	return out
}

// load refreshes the index from the DB. Errors are logged and leave the previous
// index in place (fail-open).
func (c *coverageIndex) load(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	rows, err := pool.Query(ctx, `SELECT relation, extract(epoch FROM keep)::float8
	                                FROM ops.retention_policy WHERE keep IS NOT NULL`)
	if err != nil {
		logger.Warn("coverage: retention catalog unreadable — no coverage headers", slog.String("err", err.Error()))
		return
	}
	var rels []relKeep
	byRel := map[string]time.Duration{}
	for rows.Next() {
		var rel string
		var secs float64
		if err := rows.Scan(&rel, &secs); err != nil {
			rows.Close()
			logger.Warn("coverage: scan retention row", slog.String("err", err.Error()))
			return
		}
		d := time.Duration(secs * float64(time.Second))
		rels = append(rels, relKeep{rel, d})
		name := rel
		if i := strings.LastIndex(name, "."); i >= 0 {
			name = name[i+1:]
		}
		byRel[name] = d
	}
	rows.Close()

	fnDefs := map[string]string{}
	frows, err := pool.Query(ctx, `SELECT p.proname, pg_get_functiondef(p.oid)
	                                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	                                WHERE n.nspname = 'serving' AND p.prokind = 'f'`)
	if err != nil {
		logger.Warn("coverage: serving fn defs unreadable", slog.String("err", err.Error()))
		return
	}
	for frows.Next() {
		var name, def string
		if err := frows.Scan(&name, &def); err == nil {
			fnDefs[strings.ToLower(name)] += "\n" + def // overloads concatenate
		}
	}
	frows.Close()

	dsSQL := map[string]string{}
	for name, ds := range datasets {
		dsSQL[name] = ds.sql + "\n" + ds.sqlAnalytics
	}
	byDS := resolveCoverage(rels, fnDefs, dsSQL)

	c.mu.Lock()
	c.byDS, c.byRel = byDS, byRel
	c.mu.Unlock()
	logger.Info("coverage: index loaded", slog.Int("bounded_relations", len(rels)), slog.Int("bounded_datasets", len(byDS)))
}

// run loads once and then refreshes periodically until ctx ends.
func (c *coverageIndex) run(ctx context.Context, pool *pgxpool.Pool, logger *slog.Logger) {
	c.load(ctx, pool, logger)
	t := time.NewTicker(coverageRefresh)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c.load(ctx, pool, logger)
		}
	}
}

func (c *coverageIndex) dataset(name string) (datasetCoverage, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	v, ok := c.byDS[name]
	return v, ok
}

// relationKeep returns the keep for an unqualified relation name (composer grains).
func (c *coverageIndex) relationKeep(name string) (time.Duration, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	v, ok := c.byRel[name]
	return v, ok
}

// setCoverageHeaders writes the coverage contract for a dataset response. now is
// injected for tests. No-op when the dataset has no bounded source.
func setCoverageHeaders(h http.Header, cov datasetCoverage, from time.Time, now time.Time) {
	floor := now.Add(-cov.keep).UTC()
	h.Set("Access-Control-Expose-Headers", "X-Data-Hot-Floor, X-Data-Truncated, Warning")
	h.Set("X-Data-Hot-Floor", floor.Format(time.RFC3339))
	if !from.IsZero() && from.Before(floor) {
		h.Set("X-Data-Truncated", "true")
		h.Set("Warning", fmt.Sprintf(`299 read-api "window starts before %s: %s keeps %s; older rows are not in this dataset (deep history: /v1/historian/*)"`,
			floor.Format(time.RFC3339), cov.relation, humanDuration(cov.keep)))
	}
}

func humanDuration(d time.Duration) string {
	days := int(d.Hours() / 24)
	if days >= 365 {
		return fmt.Sprintf("~%.1f years", float64(days)/365)
	}
	return fmt.Sprintf("%d days", days)
}
