// line_param30700_seed.go — register-driven Parameter30700 seed for Phase-9.
//
// WHY
// ───
// Line-metered tenants (e.g. CPACK) compute per-line OEE from the line's
// production, which Phase-9 (calc_production_counters/line_aggregation.go)
// aggregates from the line's member machines. Phase-9 keys on Parameter30700 —
// the line's machine COUNT-INDEX CSV (e.g. L5 = "61,62,63,64,65"), read from
// decode State by the line topic.
//
// The real CPACK PLC never publishes /Status/Parameter(30700) on the wire (a
// counts-only stream — confirmed 2026-08-18 debug capture), and the RETIRED
// mirror-worker-go used to synthesize the line rows instead. With that writer
// gone, nothing feeds the lines → line OEE = 0. This seeds Parameter30700
// DIRECTLY from packml_register (the machines under each line + their PLC
// count-indices, in order), so Phase-9 fires without the wire metric — the
// config-as-data replacement for mirror-worker-go's synthetic line writes.
//
// GATED by PHASE9_LINE_AGG_ENABLED (default OFF). The same flag lifts the
// Phase-9 LineAggregated suppression in main's shadow publish loop — the two
// are a pair: the suppression exists to avoid double-counting against a
// competing line writer (mirror-worker-go / an own-stream line count). Enable
// ONLY where no such competing writer exists (staging, mirror-worker-go retired).
package main

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	calc "github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/transforms/calc_production_counters"
)

// phase9LineAgg is read once at startup: env is fixed for the process lifetime
// and the suppression check is per-metric (hot path), so cache it.
var phase9LineAgg = func() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("PHASE9_LINE_AGG_ENABLED"))) {
	case "true", "1", "on", "yes":
		return true
	default:
		return false
	}
}()

// lineParam30700Query returns one row per line that has ≥1 member machine
// (tp_equipment=1) carrying a /<idx>/Unit count topic in the register:
// the full line topic and the ordered count-index CSV. Ordered ascending by
// count-index — Phase-9 takes csv[0] as the line-consumed (infeed) source and
// csv[last] as line-processed (outfeed), matching the profile example
// (cpack-profile.yaml: L5 Parameter30700 = "61,62,...").
const lineParam30700Query = `
	WITH mach AS (
	  SELECT DISTINCT
	    split_part(pr.packml_topic,'/',1) AS ent,
	    split_part(pr.packml_topic,'/',2) AS site,
	    split_part(pr.packml_topic,'/',3) AS area,
	    split_part(pr.packml_topic,'/',4) AS line,
	    ((regexp_match(pr.packml_topic,'/([0-9]+)/Unit$'))[1])::int AS idx
	  FROM packml_register pr
	  JOIN equipments m ON m.id_equipment = pr.id_equipment AND m.tp_equipment = 1
	  WHERE pr.active AND pr.packml_topic ~ '/[0-9]+/Unit$')
	SELECT ent||'/'||site||'/'||area||'/'||line AS line_topic,
	       string_agg(idx::text, ',' ORDER BY idx) AS csv
	FROM mach
	GROUP BY 1`

// lineParam30700MeterQuery returns the explicit [infeed, outfeed] count-indices
// for each LINE (tp_equipment=3) register row that has them set. This is the
// AUTHORITATIVE meter designation, cross-checked against the legacy packiot40
// oracle: the line's gross tracks the INFEED machine and its net the OUTFEED
// (TEXA). Those two are NOT ordered by count-index (e.g. CPACK L6 gross=RMH/94 >
// net=TEXA/92), so the ascending-CSV fallback would swap first/last and meter the
// wrong machines. When these columns are set they win over the member-index CSV.
const lineParam30700MeterQuery = `
	SELECT pr.packml_topic AS line_topic,
	       pr.id_infeedcounter::text  AS inf,
	       pr.id_outfeedcounter::text AS outf
	FROM packml_register pr
	JOIN equipments e ON e.id_equipment = pr.id_equipment AND e.tp_equipment = 3
	WHERE pr.active
	  AND pr.id_infeedcounter  IS NOT NULL
	  AND pr.id_outfeedcounter IS NOT NULL`

// seedLineParam30700 loads each line's Parameter30700 into Calc State, keyed by
// <lineTopic>/Status/Parameter30700 (the key line_aggregation.go builds from
// topicArray). Preference order:
//  1. explicit [infeed, outfeed] meters on the LINE register row (authoritative);
//  2. ascending member count-index CSV (fallback for lines without meters set).
// Phase-9 only reads csv[0] (gross source) and csv[last] (net source), so the
// two-element [infeed, outfeed] form is sufficient and unambiguous.
// Returns the number of lines seeded.
func seedLineParam30700(ctx context.Context, state calc.State) (int, error) {
	dsn := os.Getenv("POSTGRES_URL")
	if dsn == "" {
		return 0, nil
	}
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(cctx, dsn)
	if err != nil {
		return 0, err
	}
	defer pool.Close()

	n := 0
	covered := map[string]bool{}

	// (1) explicit meters win.
	meterRows, err := pool.Query(cctx, lineParam30700MeterQuery)
	if err != nil {
		return 0, err
	}
	for meterRows.Next() {
		var lineTopic, inf, outf string
		if err := meterRows.Scan(&lineTopic, &inf, &outf); err != nil {
			meterRows.Close()
			return n, err
		}
		parts := []string{strings.TrimSpace(inf), strings.TrimSpace(outf)}
		if err := state.SetStrings(lineTopic+"/Status/Parameter30700", parts); err != nil {
			meterRows.Close()
			return n, err
		}
		covered[lineTopic] = true
		n++
	}
	meterRows.Close()
	if err := meterRows.Err(); err != nil {
		return n, err
	}

	// (2) ascending member-index CSV for lines without explicit meters.
	rows, err := pool.Query(cctx, lineParam30700Query)
	if err != nil {
		return n, err
	}
	defer rows.Close()
	for rows.Next() {
		var lineTopic, csv string
		if err := rows.Scan(&lineTopic, &csv); err != nil {
			return n, err
		}
		if covered[lineTopic] {
			continue
		}
		parts := strings.Split(csv, ",")
		for i := range parts {
			parts[i] = strings.TrimSpace(parts[i])
		}
		if err := state.SetStrings(lineTopic+"/Status/Parameter30700", parts); err != nil {
			return n, err
		}
		n++
	}
	return n, rows.Err()
}

// runLineParam30700Seeder seeds once at boot (decode State is process-local, so
// it must be re-seeded every start) then refreshes on an interval so a
// newly-onboarded line's sequence appears without a decoder restart.
// Best-effort: a failed refresh keeps the last good seed.
func runLineParam30700Seeder(ctx context.Context, state calc.State, logger *slog.Logger) {
	seed := func() {
		n, err := seedLineParam30700(ctx, state)
		if err != nil {
			logger.Warn("phase9 line-agg: Parameter30700 seed failed", slog.String("err", err.Error()))
			return
		}
		logger.Info("phase9 line-agg: seeded Parameter30700 from packml_register", slog.Int("lines", n))
	}
	seed()
	go func() {
		t := time.NewTicker(5 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				seed()
			}
		}
	}()
}
