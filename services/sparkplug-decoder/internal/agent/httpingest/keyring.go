package httpingest

// Per-tenant ingest keys (2026-10-14, "shared ingest door").
//
// Before: ONE X-Ingest-Key admitted every tenant on the shared front door and
// the router trusted the group the request named, so a key holder inside the
// security-group allowlist could post as another tenant. Now each key is bound
// to the group(s) it may publish for: the tenant is still routed by the
// declared group, but the KEY must be authorised for that group (403 if not).
//
// The ring stores only SHA-256 hashes of the keys, never the keys. Keys are
// 256-bit random values (openssl rand -hex 32), so an unsalted fast hash is the
// right tool here: there is no low-entropy password to brute-force, and the
// hash map is safe to keep in Secrets Manager or even in plain config. (bcrypt /
// argon2 exist for human passwords; they would only add latency per request.)

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// KeyRing maps hashed ingest keys to the groups each key may publish for.
// Build it with ParseKeyRing; a nil *KeyRing is an empty ring.
type KeyRing struct {
	entries []keyEntry
}

type keyEntry struct {
	hash   [sha256.Size]byte
	groups map[string]struct{} // upper-cased SparkPlug groups
	label  string              // sorted groups joined by "," — log-safe key identity
}

// ParseKeyRing parses the key map JSON: an object whose keys are lowercase or
// uppercase hex SHA-256 digests of an ingest key and whose values are the list
// of SparkPlug groups that key may publish for, e.g.
//
//	{"9f86d081...": ["INCOPLAST"], "2c26b46b...": ["CPACK"]}
//
// Groups are case-insensitive (normalised to upper case). Every digest must be
// 64 hex characters and every entry must name at least one group; anything
// else is an error, so a typo fails start-up instead of silently locking a
// client out.
func ParseKeyRing(raw []byte) (*KeyRing, error) {
	var m map[string][]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("ingest key map: want a JSON object {\"<sha256-hex>\": [\"GROUP\", ...]}: %w", err)
	}
	ring := &KeyRing{}
	digests := make([]string, 0, len(m))
	for d := range m {
		digests = append(digests, d)
	}
	sort.Strings(digests) // deterministic entry order (and error messages)
	for i, d := range digests {
		b, err := hex.DecodeString(strings.TrimSpace(d))
		if err != nil || len(b) != sha256.Size {
			// Never echo the entry: if someone pasted a raw key here by mistake,
			// the error message must not print it.
			return nil, fmt.Errorf("ingest key map: entry %d is not a 64-character hex SHA-256 digest (store the hash of the key, not the key)", i+1)
		}
		groups := map[string]struct{}{}
		var names []string
		for _, g := range m[d] {
			g = strings.ToUpper(strings.TrimSpace(g))
			if g == "" {
				continue
			}
			if _, dup := groups[g]; !dup {
				groups[g] = struct{}{}
				names = append(names, g)
			}
		}
		if len(groups) == 0 {
			return nil, fmt.Errorf("ingest key map: entry %d binds no group", i+1)
		}
		sort.Strings(names)
		var e keyEntry
		copy(e.hash[:], b)
		e.groups = groups
		e.label = strings.Join(names, ",")
		ring.entries = append(ring.entries, e)
	}
	return ring, nil
}

// HashKey returns the hex SHA-256 digest of an ingest key — the form stored in
// the key map. Used by the runbook's documented `sha256sum` and by tests.
func HashKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

// Len is the number of keys in the ring.
func (k *KeyRing) Len() int {
	if k == nil {
		return 0
	}
	return len(k.entries)
}

// Groups returns every group any key is bound to (sorted, upper case).
func (k *KeyRing) Groups() []string {
	if k == nil {
		return nil
	}
	seen := map[string]struct{}{}
	var out []string
	for _, e := range k.entries {
		for g := range e.groups {
			if _, ok := seen[g]; !ok {
				seen[g] = struct{}{}
				out = append(out, g)
			}
		}
	}
	sort.Strings(out)
	return out
}

// lookup finds the entry for a presented key. It hashes the key and compares
// the digest against EVERY entry with subtle.ConstantTimeCompare, without an
// early exit, so the response time does not depend on which entry (if any)
// matched. An empty key never matches.
func (k *KeyRing) lookup(presented string) (*keyEntry, bool) {
	if k == nil || presented == "" {
		return nil, false
	}
	sum := sha256.Sum256([]byte(presented))
	var hit *keyEntry
	for i := range k.entries {
		if subtle.ConstantTimeCompare(sum[:], k.entries[i].hash[:]) == 1 {
			hit = &k.entries[i]
		}
	}
	return hit, hit != nil
}

// principal is who a request authenticated as.
type principal struct {
	legacy bool      // the shared legacy key (admits any group, deprecated)
	entry  *keyEntry // per-tenant key; nil when legacy
}

// allows reports whether the principal may publish for group (case-insensitive).
func (p principal) allows(group string) bool {
	if p.legacy {
		return true
	}
	_, ok := p.entry.groups[strings.ToUpper(strings.TrimSpace(group))]
	return ok
}

// keyLabel is the log-safe identity of the key: the groups it is bound to, or
// "legacy". Never key material, not even a hash prefix.
func (p principal) keyLabel() string {
	if p.legacy {
		return "legacy"
	}
	return p.entry.label
}
