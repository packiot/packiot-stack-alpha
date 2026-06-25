package replay

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

// ErrSkipReplay is returned by a handler when the row is intentionally not
// replayed because the upstream entity is unmappable by design — e.g. a prod
// production_order that was never mirrored to staging (operator touched it
// before our mirror cursor began), or a junk SparkPlug topic (the LLLLL-
// prefix garbage that an upstream edge-nodered occasionally emits).
//
// Dispatcher recognises this sentinel via errors.Is and records
// outcome=skipped on mirror_worker_user_logs_replayed_total. The row is NOT
// written to mirror_replay_dlq because no amount of retrying will fix the
// underlying mismatch — these failures are structural, not transient.
//
// Only the translator's ErrUnmapped should be promoted to ErrSkipReplay.
// Random failures (network errors, edge-api 5xx, JSON parse errors) MUST
// stay as plain errors so they land in DLQ and get human attention.
var ErrSkipReplay = errors.New("skip replay: upstream entity structurally unmappable on staging")

// parseBigint accepts either a JSON number or a bigint-as-text column —
// the staging/prod queries cast id_production_order::text + ::text on
// id_equipment_event::text to dodge int64-overflow surprises in pgx.
func parseBigint(s string) (int64, error) {
	return strconv.ParseInt(s, 10, 64)
}

// decodeWithNumbers parses JSON preserving number precision (no float64
// rounding). Handlers care about this because some prod payloads encode
// large IDs (id_production_order, id_equipment_event) as JSON numbers
// that would lose digits after the 53-bit mantissa boundary.
func decodeWithNumbers(raw []byte, dest any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	return dec.Decode(dest)
}

// parseFlexFloat parses a json.RawMessage that may contain a number, a
// quoted number, an empty string, or null. Returns (0, nil) for the
// empty / null / missing cases — prod emits these when an operator stops
// a PO without starting a new one (order-changed with empty new-PO fields).
// Returns an error only for genuinely non-numeric input.
func parseFlexFloat(raw json.RawMessage) (float64, error) {
	s := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if s == "" || s == "null" {
		return 0, nil
	}
	return strconv.ParseFloat(s, 64)
}
