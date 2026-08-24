// Package replicate is the cross-instance twin replicator: it replays
// CPACK operator actions from the LEGACY production DB (packiot40, ent 1)
// into the staging new-stack analytics plane (packiot_analytics, ent 3),
// so staging mirrors what factory operators actually do on the floor.
//
// It is a SIBLING of the analytics-sync (shadow-mirror) replay engine and
// reuses the same philosophy — poll user_logs on a cursor, dispatch by
// category, re-apply the effect idempotently by NATURAL KEY — but adds the
// one new problem the in-instance mirror never had: an id-mapping layer at
// the boundary (enterprise 1->3, every legacy equipment -> its staging twin
// resolved by packml base-topic, PO by (id_enterprise,id_order)). See
// resolver.go. The source DB is SELECT-only; every write goes to staging.
package replicate

import (
	"os"
	"strconv"
	"time"
)

type Config struct {
	// SOURCE — legacy prod DB packiot40 (SELECT-only). Natural-key
	// resolution reads (production_orders, equipment_events, packml_register)
	// from here; NEVER written.
	LegacyHost     string
	LegacyPort     int
	LegacyUser     string
	LegacyPassword string
	LegacyDBName   string

	// DEST — staging analytics plane packiot_analytics. All writes land here;
	// the cursor lives here too (source is read-only).
	DestHost     string
	DestPort     int
	DestUser     string
	DestPassword string
	DestDBName   string

	// Enterprise id-map. Only SrcEnterprise is polled; its rows map onto
	// DstEnterprise. CPACK = 1 -> 3 by default; kept configurable so future
	// tenants reuse the same binary.
	SrcEnterprise int
	DstEnterprise int

	// Backfill window. Cold start seeds the cursor just before the first
	// legacy row with ts_log >= (now - SinceDays), so historical dashboards
	// aren't blank; then the loop continues into live. SinceOverride (an
	// RFC3339 timestamp or YYYY-MM-DD) wins over SinceDays when set. A
	// pre-existing cursor is always respected — this only affects cold start.
	SinceDays     int
	SinceOverride string

	// ReplicateBaseEvents controls whether downtime-event-created replays the
	// raw PLC equipment_events rows into staging. The in-instance mirror
	// DEFERS these (the shadow flow regenerates them from the same PLC
	// stream) — but the twin's tee does NOT faithfully carry every line
	// (CPACK lines died 2026-08-13 upstream), so without this the base rows
	// for most lines are missing and event-justified/edited no-op. Default
	// true. ON CONFLICT (id_equipment, ts_event) DO NOTHING never clobbers a
	// row the tee did produce.
	ReplicateBaseEvents bool

	// CursorSource is the mirror_replay_cursor.source key in the DEST DB.
	// Distinct from the in-instance mirror ("shadow-mirror") so the two
	// cursors never collide.
	CursorSource string

	// Loop tuning.
	PollIntervalMs int
	BatchSize      int

	// Ops.
	Enabled    bool
	HealthPort int
	LogLevel   string

	// HealthMaxAgeSec bounds /healthz liveness: if the loop has not completed a
	// successful poll within this many seconds, /healthz returns 503 so the
	// docker healthcheck can flag a wedged loop. 0 (default) disables the check
	// — /healthz stays a plain 200. See internal/health.Checker.
	HealthMaxAgeSec int
}

func Load() *Config {
	return &Config{
		LegacyHost:     getenv("LEGACY_DB_HOST", "18.220.223.110"),
		LegacyPort:     getenvInt("LEGACY_DB_PORT", 5432),
		LegacyUser:     getenv("LEGACY_DB_USER", "awslambda"),
		LegacyPassword: getenv("LEGACY_DB_PASSWORD", ""),
		LegacyDBName:   getenv("LEGACY_DB_NAME", "packiot40"),

		DestHost:     getenv("DEST_DB_HOST", "10.10.10.89"),
		DestPort:     getenvInt("DEST_DB_PORT", 5432),
		DestUser:     getenv("DEST_DB_USER", "postgres"),
		DestPassword: getenv("DEST_DB_PASSWORD", ""),
		DestDBName:   getenv("DEST_DB_NAME", "packiot_analytics"),

		SrcEnterprise: getenvInt("SRC_ENTERPRISE", 1),
		DstEnterprise: getenvInt("DST_ENTERPRISE", 3),

		SinceDays:     getenvInt("BACKFILL_SINCE_DAYS", 60),
		SinceOverride: getenv("BACKFILL_SINCE", ""),

		ReplicateBaseEvents: getenv("REPLICATE_BASE_EVENTS", "true") == "true",

		CursorSource: getenv("CURSOR_SOURCE", "legacy-cpack"),

		PollIntervalMs: getenvInt("POLL_INTERVAL_MS", 3000),
		BatchSize:      getenvInt("BATCH_SIZE", 200),

		Enabled:         getenv("REPLICATE_ENABLED", "false") == "true",
		HealthPort:      getenvInt("HEALTH_PORT", 9104),
		LogLevel:        getenv("LOG_LEVEL", "info"),
		HealthMaxAgeSec: getenvInt("HEALTHCHECK_MAX_AGE_SEC", 0),
	}
}

// SinceStart resolves the cold-start backfill window lower bound.
func (c *Config) SinceStart(now time.Time) time.Time {
	if c.SinceOverride != "" {
		if t, err := time.Parse(time.RFC3339, c.SinceOverride); err == nil {
			return t
		}
		if t, err := time.Parse("2006-01-02", c.SinceOverride); err == nil {
			return t
		}
	}
	return now.AddDate(0, 0, -c.SinceDays)
}

func getenv(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func getenvInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
