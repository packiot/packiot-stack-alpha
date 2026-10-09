package writers

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// seedLookback bounds the seed lookup: a stream silent for longer than this
// starts fresh (fail-open), and the scan stays on a few chunks.
const seedLookback = 30 * 24 * time.Hour

// PGTotalizerSeeder returns a TotalizerSeeder that reads the last stored
// totalizer from <schema>.equipment_values on the pool pick(schema) returns.
// One indexed lookup per stream per process lifetime; 2 s timeout; any error
// is logged and fails open (the clamp behaves as before for that stream).
func PGTotalizerSeeder(pick func(schema string) *pgxpool.Pool, logger *slog.Logger) TotalizerSeeder {
	return func(ctx context.Context, schema string, idEquipment int, kind sparkplug.MetricKind, tsMs int64) (float64, bool) {
		col := totalizerColumn(kind)
		pool := pick(schema)
		if col == "" || pool == nil {
			return 0, false
		}
		ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		ts := time.UnixMilli(tsMs).UTC()
		var abs float64
		err := pool.QueryRow(ctx, fmt.Sprintf(`
			SELECT %[2]s FROM %[1]s.equipment_values
			 WHERE id_equipment = $1 AND ts_value < $2 AND ts_value >= $3 AND %[2]s IS NOT NULL
			 ORDER BY ts_value DESC LIMIT 1`, schema, seedExpr(schema, col)),
			idEquipment, ts, ts.Add(-seedLookback)).Scan(&abs)
		if err != nil {
			if !errors.Is(err, pgx.ErrNoRows) && logger != nil {
				logger.Warn("increment clamp totalizer seed lookup failed (fail-open)",
					slog.Int("id_equipment", idEquipment), slog.String("kind", kind.String()), slog.String("err", err.Error()))
			}
			return 0, false
		}
		return abs, true
	}
}

// totalizerColumn maps a production-counter kind to its absolute column.
func totalizerColumn(kind sparkplug.MetricKind) string {
	switch kind {
	case sparkplug.KindProdProcessedCount:
		return "net_production_val"
	case sparkplug.KindProdConsumedCount:
		return "gross_production_val"
	case sparkplug.KindProdDefectiveCount:
		return "scrap_val"
	}
	return ""
}

// seedExpr is the stored totalizer the seed reads. Where the exact float8 *_total exists
// (writesTotals) it wins, falling back to the float4 *_val for rows written before the
// dual-write: a float4 seed above 2^24 is off by up to ±16 on today's largest totalizers,
// and that error became the first increment after every restart. The public route has
// only *_val.
func seedExpr(schema, valCol string) string {
	if !writesTotals(schema) {
		return valCol
	}
	return fmt.Sprintf("COALESCE(%s, %s)", strings.TrimSuffix(valCol, "_val")+"_total", valCol)
}
