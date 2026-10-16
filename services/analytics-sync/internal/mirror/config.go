// Package mirror is prod-reflector: it keeps a staging tenant an exact, read-only mirror of the same tenant in
// production (ADR-0064). Production is the single source of truth; every pass converges staging's rows of that
// tenant to production's, table by table, and production always wins.
//
// It is a STATE reflector, not an action replayer (legacy-replicator replays user_logs because the legacy schema
// and ids differ from the new stack). Here the two databases share the schema and the ids (production was built
// from staging, ADR-0064 D3), so copying state is strictly simpler than re-executing actions, and it heals itself:
// a missed pass, an outage or a stray write on staging is undone by the next pass.
package mirror

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is read from the environment. The service is IDLE (no DB connection, no secret read) unless
// PROD_MIRROR_ENTERPRISES is set: that one variable is the go-live switch shared with edge-api, barcode-service
// and stream-engine (ADR-0064 D1).
type Config struct {
	Enterprises []int // PROD_MIRROR_ENTERPRISES — tenants staging mirrors from production

	DryRun bool // PROD_REFLECT_DRY_RUN=true: compute and report the diff, write nothing

	Interval         time.Duration // PROD_REFLECT_INTERVAL_SEC (60): hot-pass cadence
	FullEvery        time.Duration // PROD_REFLECT_FULL_EVERY_HOURS (6): every bucket of every table
	LookbackDays     int           // PROD_REFLECT_LOOKBACK_DAYS (35): hot passes compare time buckets this recent
	MaxDeletes       int           // PROD_REFLECT_MAX_DELETES (2000): per table per pass; above it deletes are skipped
	NameSuffix       string        // PROD_REFLECT_NAME_SUFFIX (" (mirror)"): staging's enterprise name = prod's + suffix
	InvariantEvery   time.Duration // PROD_REFLECT_INVARIANT_EVERY_MIN (15): MR* rows into ops.data_invariant_result
	MaxLag           time.Duration // PROD_REFLECT_MAX_LAG_SEC (600): MR3 fails when the last converged pass is older
	IDBlock          int64         // PROD_ID_BLOCK (1e9): production mints ids >= this; staging must stay below
	StatementTimeout time.Duration // PROD_REFLECT_STATEMENT_TIMEOUT_SEC (120)

	HealthPort      int // HEALTH_PORT (9124)
	HealthMaxAgeSec int // HEALTHCHECK_MAX_AGE_SEC (0 = off)
	LogLevel        string
}

func getenv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func getint(k string, def int) (int, error) {
	v := getenv(k, "")
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %q is not an integer", k, v)
	}
	return n, nil
}

// ParseEnterprises parses a comma-separated id list. A typo fails loudly: it must never silently disable the
// mirror (the same rule as edge-api's OPERATOR_WRITE_BLOCKED_ENTERPRISES).
func ParseEnterprises(raw string) ([]int, error) {
	var out []int
	seen := map[int]bool{}
	for _, part := range strings.Split(raw, ",") {
		p := strings.TrimSpace(part)
		if p == "" {
			continue
		}
		n, err := strconv.Atoi(p)
		if err != nil || n <= 0 {
			return nil, fmt.Errorf("PROD_MIRROR_ENTERPRISES: invalid enterprise id %q", p)
		}
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	return out, nil
}

// Load reads the configuration. Errors are configuration mistakes; the caller exits.
func Load() (*Config, error) {
	ents, err := ParseEnterprises(os.Getenv("PROD_MIRROR_ENTERPRISES"))
	if err != nil {
		return nil, err
	}
	c := &Config{
		Enterprises: ents,
		DryRun:      getenv("PROD_REFLECT_DRY_RUN", "false") == "true",
		NameSuffix:  " (mirror)",
		LogLevel:    getenv("LOG_LEVEL", "info"),
	}
	if v, ok := os.LookupEnv("PROD_REFLECT_NAME_SUFFIX"); ok {
		c.NameSuffix = v // may be "" on purpose (keep prod's name verbatim)
	}
	ints := []struct {
		key string
		def int
		set func(int)
	}{
		{"PROD_REFLECT_INTERVAL_SEC", 60, func(n int) { c.Interval = time.Duration(n) * time.Second }},
		{"PROD_REFLECT_FULL_EVERY_HOURS", 6, func(n int) { c.FullEvery = time.Duration(n) * time.Hour }},
		{"PROD_REFLECT_LOOKBACK_DAYS", 35, func(n int) { c.LookbackDays = n }},
		{"PROD_REFLECT_MAX_DELETES", 2000, func(n int) { c.MaxDeletes = n }},
		{"PROD_REFLECT_INVARIANT_EVERY_MIN", 15, func(n int) { c.InvariantEvery = time.Duration(n) * time.Minute }},
		{"PROD_REFLECT_MAX_LAG_SEC", 600, func(n int) { c.MaxLag = time.Duration(n) * time.Second }},
		{"PROD_REFLECT_STATEMENT_TIMEOUT_SEC", 120, func(n int) { c.StatementTimeout = time.Duration(n) * time.Second }},
		{"HEALTH_PORT", 9124, func(n int) { c.HealthPort = n }},
		{"HEALTHCHECK_MAX_AGE_SEC", 0, func(n int) { c.HealthMaxAgeSec = n }},
	}
	for _, i := range ints {
		n, err := getint(i.key, i.def)
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, fmt.Errorf("%s must be >= 0", i.key)
		}
		i.set(n)
	}
	block, err := strconv.ParseInt(getenv("PROD_ID_BLOCK", "1000000000"), 10, 64)
	if err != nil || block <= 0 {
		return nil, fmt.Errorf("PROD_ID_BLOCK: invalid value")
	}
	c.IDBlock = block
	if c.Interval < 10*time.Second {
		return nil, fmt.Errorf("PROD_REFLECT_INTERVAL_SEC must be >= 10")
	}
	if c.LookbackDays < 1 {
		return nil, fmt.Errorf("PROD_REFLECT_LOOKBACK_DAYS must be >= 1")
	}
	return c, nil
}

// Enabled reports whether the reflector should connect at all.
func (c *Config) Enabled() bool { return len(c.Enterprises) > 0 }
