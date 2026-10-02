// recompute-render — renders the per-day history-recompute SQL template from the
// CURRENT engine code (rollup.RenderHistoryRecompute). No database access.
//
// The rollup configuration comes from the same env vars the worker reads
// (internal/config). Pass the running worker's values with -env-file, a
// KEY=VALUE dump; only the rollup keys below are applied, everything else in
// the file (secrets included) is ignored:
//
//	docker exec stream-engine env | grep -E '^(EVENTS_EXCLUDED|COUNTERS_ONLY|OEE_|AVAILABILITY_EXCLUSIONS|CHANGEOVER_AVAIL|ROLLUP_MACHINE_LEVEL)' > worker.env
//	go run ./cmd/recompute-render -env-file worker.env -rev "$(git rev-parse --short HEAD)" -out recompute_tpl.sql
//
// The worker unions profile-authored line-lead enterprises / per-line overrides
// from client_descriptors at boot; pass them with -line-lead-* (see
// docs/runbooks/history-recompute.md for the read-only query).
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/oeeprofile"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
)

// rollupEnvPrefixes are the only env keys -env-file may set.
var rollupEnvPrefixes = []string{
	"EVENTS_EXCLUDED_", "COUNTERS_ONLY_", "OEE_", "AVAILABILITY_EXCLUSIONS_",
	"CHANGEOVER_AVAILABILITY_", "ROLLUP_MACHINE_LEVEL_",
}

func applyEnvFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.HasPrefix(line, "#") {
			continue
		}
		for _, p := range rollupEnvPrefixes {
			if strings.HasPrefix(k, p) {
				if err := os.Setenv(k, strings.Trim(v, `"'`)); err != nil {
					return err
				}
				break
			}
		}
	}
	return sc.Err()
}

func main() {
	envFile := flag.String("env-file", "", "KEY=VALUE dump of the worker env (only rollup keys are applied)")
	dest := flag.String("dest", "staging", "staging (packiot_analytics medallion) | public (single-flow)")
	horizon := flag.Int("horizon-days", 75, "oldest row age the repair may touch")
	extraLL := flag.String("line-lead-enterprises", "", "CSV unioned onto COUNTERS_ONLY_LINE_LEAD_ENTERPRISES (profile-authored)")
	optIn := flag.String("line-lead-opt-in", "", "CSV of per-line opt-in line ids (oee_profile.lines)")
	optOut := flag.String("line-lead-opt-out", "", "CSV of per-line opt-out line ids (oee_profile.lines)")
	rev := flag.String("rev", "", "source revision stamped into the header (git rev-parse --short HEAD)")
	out := flag.String("out", "", "output file (default stdout)")
	flag.Parse()

	if *envFile != "" {
		if err := applyEnvFile(*envFile); err != nil {
			fail("env-file: %v", err)
		}
	}
	cfg, err := config.Load()
	if err != nil {
		fail("config: %v", err)
	}
	// flows.Standard picks the dest by whether an analytics pool exists; the pool
	// itself is never dialled here.
	var dests []flows.Dest
	switch *dest {
	case "staging":
		dests = flows.Standard(nil, new(pgxpool.Pool))
	case "public":
		dests = flows.Standard(nil, nil)
	default:
		fail("unknown -dest %q", *dest)
	}
	d := dests[0]
	d.Pool = nil

	h := rollup.HistoryRecompute{
		Dest: d,
		CA: rollup.CountersAvail{
			Enabled:                cfg.CountersOnlyAvailEnabled,
			Equipments:             config.CSVInts(cfg.CountersOnlyAvailEquipments),
			IdleTimeoutSec:         cfg.CountersOnlyAvailIdleTimeoutSec,
			LineLeadEnabled:        cfg.CountersOnlyLineLeadEnabled,
			LineLeadEnterprises:    oeeprofile.UnionInts(config.CSVInts(cfg.CountersOnlyLineLeadEnterprises), config.CSVInts(*extraLL)),
			LineLeadOptIn:          config.CSVInts(*optIn),
			LineLeadOptOut:         config.CSVInts(*optOut),
			AvailFloorEnabled:      cfg.OeeAvailFloorEnabled,
			OeeCanonicalAPQ:        cfg.OeeCanonicalAPQEnabled,
			AvailabilityExclusions: cfg.AvailabilityExclusionsEnabled,
		},
		ChangeoverAvailability:  cfg.ChangeoverAvailabilityEnabled,
		ExclAreas:               config.CSVInts(cfg.EventsExcludedAreas),
		ExclEnterprises:         config.CSVInts(cfg.EventsExcludedEnterprises),
		MachineLevelEnterprises: config.CSVInts(cfg.RollupMachineLevelEnterprises),
		HorizonDays:             *horizon,
	}
	sql, err := rollup.RenderHistoryRecompute(h)
	if err != nil {
		fail("render: %v", err)
	}
	if *rev != "" {
		sql = "-- source revision: " + *rev + "\n" + sql
	}
	if *out == "" {
		fmt.Print(sql)
		return
	}
	if err := os.WriteFile(*out, []byte(sql), 0o644); err != nil {
		fail("write: %v", err)
	}
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "recompute-render: "+format+"\n", a...)
	os.Exit(1)
}
