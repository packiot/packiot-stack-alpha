package replicate

import (
	"bytes"
	"fmt"
	"strconv"
)

// flexInt64 unmarshals a JSON value that may be either a number OR a
// quoted numeric string. Legacy edge-api emits id/quantity fields both
// ways in the SAME category — e.g. order-created carries
// idOrder:"895241" (string) while order-changed carries idOrder:895641
// (number). The in-instance mirror's int64 structs would fail on the
// string form, so the cross-instance payloads use flexInt64 everywhere a
// legacy numeric field is read. Empty/null -> 0.
type flexInt64 int64

func (f *flexInt64) UnmarshalJSON(b []byte) error {
	s := string(bytes.Trim(b, `"`))
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		*f = flexInt64(n)
		return nil
	}
	// Tolerate a decimal string ("56602.0") by truncating.
	if fl, err := strconv.ParseFloat(s, 64); err == nil {
		*f = flexInt64(int64(fl))
		return nil
	}
	return fmt.Errorf("flexInt64: cannot parse %q", s)
}

func (f flexInt64) Int64() int64 { return int64(f) }
func (f flexInt64) Int() int     { return int(f) }
