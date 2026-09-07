// parse.go — recognizing a count-bearing tag and splitting it into the DQ
// evidence a capture observation records (ADR-0045 Phase-2b §2.4b).
//
// A count metric embeds an arbitrary PLC channel index in a `.../<IDX>/Unit`
// leaf (e.g. "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"). That
// index is the one PLC fact ADR-0045 says must be OBSERVED, not typed — so the
// observe posture records, per equipment topic, which index actually arrived.
//
// The split is DECLARATIVE, driven by the tenant profile's count-metric leaf
// TEMPLATES (the "{idx}" leaves in metric_templates, e.g.
// "/Admin/ProdConsumedCount/{idx}/Unit"). Reusing the declared templates — the
// same shapes the register loader synthesizes from — means capture recognizes
// exactly the tenant's count families and splits topic-from-leaf precisely,
// without hardcoding "/Admin" or a counter name. A tag matching no template is
// not a count tag → not recorded (the strict-allowlist discipline, applied to
// evidence rather than the data plane).
package capture

import (
	"strconv"
	"strings"
)

// IdxPlaceholder is the token a count-leaf template uses for the channel index.
// Kept local (mirrors tenantprofile.IdxPlaceholder) so this package stays a leaf
// with no agent-internal imports.
const IdxPlaceholder = "{idx}"

// Observation is one parsed count sighting: an equipment topic emitted a count
// index under a specific count-leaf family. It is the row shape the recorder
// buffers and the sink upserts (minus the accounting columns the DB owns).
type Observation struct {
	// Topic is the equipment topic — the full SparkPlug name with the matched
	// count leaf stripped (e.g. "CPACK/SC/LINHAS/L5/BREYER"). This is what a
	// descriptor entry's Topic is compared against during the confirm step.
	Topic string
	// CountIndex is the integer the PLC embedded in `.../<CountIndex>/Unit`.
	CountIndex int
	// MetricSuffix is the count-leaf TEMPLATE the tag matched (with "{idx}"
	// intact, e.g. "/Admin/ProdConsumedCount/{idx}/Unit") — records which count
	// family the index belongs to without the volatile index value.
	MetricSuffix string
}

// ParseObservation reports whether fullName is a count-bearing metric under one
// of the supplied count-leaf templates, and if so returns the split observation.
//
// Templates are the profile's count leaves (only those containing "{idx}" are
// count leaves; index-free leaves like "/Status/MachSpeed" are ignored). The
// first matching template wins; templates should be disjoint in practice (one
// count family per counter name). Pure + total — no IO, fully unit-testable.
func ParseObservation(fullName string, templates []string) (Observation, bool) {
	for _, tmpl := range templates {
		before, after, found := strings.Cut(tmpl, IdxPlaceholder)
		if !found {
			continue // not a count leaf (no {idx}) — skip
		}
		// The leaf sits at the TAIL: fullName must end with `after` (e.g.
		// "/Unit"), and `before` (e.g. "/Admin/ProdConsumedCount/") must appear
		// with a run of digits between it and `after`.
		if !strings.HasSuffix(fullName, after) {
			continue
		}
		head := fullName[:len(fullName)-len(after)] // ".../ProdConsumedCount/61"
		i := strings.LastIndex(head, before)
		if i < 0 {
			continue
		}
		digits := head[i+len(before):]
		if !isAllDigits(digits) {
			continue
		}
		idx, err := strconv.Atoi(digits)
		if err != nil {
			continue // overflow / unparseable — not a valid channel index
		}
		return Observation{
			Topic:        fullName[:i], // everything before the count leaf = equipment topic
			CountIndex:   idx,
			MetricSuffix: tmpl,
		}, true
	}
	return Observation{}, false
}

// CountLeafTemplates filters a set of metric-leaf templates down to the count
// leaves (those carrying the "{idx}" placeholder). The caller passes the union
// of the profile's member + line templates.
func CountLeafTemplates(leaves []string) []string {
	out := make([]string, 0, len(leaves))
	for _, l := range leaves {
		if strings.Contains(l, IdxPlaceholder) {
			out = append(out, l)
		}
	}
	return out
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
