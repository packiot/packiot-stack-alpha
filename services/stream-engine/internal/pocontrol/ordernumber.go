package pocontrol

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// OrderNumber is the client's production-order number (ADR-0062 D1): TEXT,
// kept exactly as given — only surrounding whitespace is trimmed, never
// re-formatted. "08396260" stays "08396260", 834.058 stays "834.058".
//
// It decodes from EITHER a JSON string ("ORD-1", "08396260") or a JSON number
// (123, 834.058 — the literal text is kept via json.Number, so no float
// rounding and no int truncation). null / absent / "" / "   " decode to the
// empty OrderNumber, which callers treat as "not supplied" (IsZero); the
// decoder does NOT fail on those so a sibling field never loses its value.
// Any other JSON kind (bool, object, array) is an error.
//
// It is never parsed as an integer for meaning: the DB trigger assigns the
// deprecated integer id_order from the text (t-adr0062-p1-po-number-expand).
type OrderNumber string

// UnmarshalJSON implements json.Unmarshaler.
func (o *OrderNumber) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	switch {
	case len(b) == 0 || bytes.Equal(b, []byte("null")):
		*o = ""
		return nil
	case b[0] == '"':
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return fmt.Errorf("order number: %w", err)
		}
		*o = OrderNumber(strings.TrimSpace(s))
		return nil
	case b[0] == '-' || (b[0] >= '0' && b[0] <= '9'):
		var n json.Number
		if err := json.Unmarshal(b, &n); err != nil {
			return fmt.Errorf("order number: %w", err)
		}
		*o = OrderNumber(strings.TrimSpace(n.String()))
		return nil
	default:
		return fmt.Errorf("order number: want a string or a number, got %s", b)
	}
}

// MarshalJSON always emits the number as a JSON string (ADR-0062: text).
func (o OrderNumber) MarshalJSON() ([]byte, error) { return json.Marshal(string(o)) }

// IsZero reports whether no order number was supplied.
func (o OrderNumber) IsZero() bool { return o == "" }

// String returns the number text.
func (o OrderNumber) String() string { return string(o) }
