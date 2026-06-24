package replay

import (
	"bytes"
	"encoding/json"
	"strconv"
)

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
