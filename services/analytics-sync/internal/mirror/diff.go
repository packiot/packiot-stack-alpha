package mirror

import "sort"

// Fingerprint is one bucket's row count and content hash.
type Fingerprint struct {
	N   int64
	MD5 string
}

// DiffBuckets returns the buckets whose fingerprints differ (present on one side only, or different), sorted.
func DiffBuckets(src, dst map[string]Fingerprint) []string {
	var out []string
	for b, s := range src {
		if d, ok := dst[b]; !ok || d != s {
			out = append(out, b)
		}
	}
	for b := range dst {
		if _, ok := src[b]; !ok {
			out = append(out, b)
		}
	}
	sort.Strings(out)
	return out
}

// SrcRow is one production row: its key, its compared hash and the row to write (jsonb text).
type SrcRow struct {
	Hash string
	Row  string
}

// Ops is what converges one table's compared buckets.
type Ops struct {
	Upsert    []string // keys to insert or update (production rows)
	Delete    []string // keys staging has and production does not
	Divergent int      // AppendOnly: staging rows that differ or are extra (never touched)
}

// DiffRows compares keyed rows. For AppendOnly only missing keys are written.
func DiffRows(src map[string]SrcRow, dst map[string]string, mode Mode) Ops {
	var o Ops
	for k, s := range src {
		h, ok := dst[k]
		switch {
		case !ok:
			o.Upsert = append(o.Upsert, k)
		case h != s.Hash:
			if mode == AppendOnly {
				o.Divergent++
			} else {
				o.Upsert = append(o.Upsert, k)
			}
		}
	}
	for k := range dst {
		if _, ok := src[k]; !ok {
			if mode == AppendOnly {
				o.Divergent++
			} else {
				o.Delete = append(o.Delete, k)
			}
		}
	}
	sort.Strings(o.Upsert)
	sort.Strings(o.Delete)
	return o
}

// StagingWrites counts the rows staging changed behind the reflector's back since the previous pass: a key the
// reflector wrote with production hash H, production still has H, yet staging differs again — something on
// staging wrote a mirrored row (a write surface the block missed). Also a key the reflector deleted that is back
// on staging while production still lacks it. This is the conflict detector of ADR-0064 §4.
func StagingWrites(ops Ops, src map[string]SrcRow, lastWritten map[string]string, lastDeleted map[string]bool) int {
	n := 0
	for _, k := range ops.Upsert {
		if h, ok := lastWritten[k]; ok && h == src[k].Hash {
			n++
		}
	}
	for _, k := range ops.Delete {
		if lastDeleted[k] {
			n++
		}
	}
	return n
}
