package adapter

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
)

// Idempotency-Key forwarding. The problem it solves: the edge-api client has a
// 10 s timeout, so a slow edge-api can COMMIT a write and still have the gateway
// answer 503. The tee retries, and without a key edge-api runs the write a
// second time (duplicate downtime, duplicate PO). edge-api already honours an
// `Idempotency-Key` header on every POST (global IdempotencyInterceptor, rows in
// idempotency_keys, 24 h window): a repeat of a key that already SUCCEEDED gets
// the stored status back and the write is not run again. Failed attempts are not
// stored, so a retry after a real failure runs normally.
//
// Where the key comes from, in order:
//
//  1. The caller's own `Idempotency-Key` header. Works for every action and is
//     the only correct choice for repeatable actions, because the caller knows
//     whether a request is a retry or a new action.
//  2. Otherwise, for the time-anchored CREATE-style actions only (downtime
//     create, PO create-and-start, PO stop, PO setup), a key derived from the
//     tenant + edge-api path + the exact edge-api body. Those bodies carry the
//     event timestamp, so two requests with the same body are the same action.
//  3. Otherwise no key, the same behaviour as before. Downtime edit, PO replace,
//     change-status (a toggle), change-time and split can be legitimately
//     repeated with an identical body within 24 h (A→B→A). A derived key would
//     answer the second A from the cache and silently skip the write, so they
//     only get a key when the caller sends one.
//
// The forwarded key is always a namespaced SHA-256 ("opgw-<hex>"): edge-api's
// key space is shared with other callers (mirror-worker replay), and the hash
// binds the key to this tenant and endpoint, so the same client key on two
// different actions never collides.
//
// Not covered: a retry that arrives while the first attempt is STILL running in
// edge-api runs again (edge-api has no in-flight lock), and a reused key with a
// different body replays the first result (edge-api stores no body fingerprint).

// idempotencyHeader is the header read from the caller and sent to edge-api.
const idempotencyHeader = "Idempotency-Key"

// maxClientIdempotencyKeyLen bounds the caller's key (it is hashed, so the
// bound only stops abuse).
const maxClientIdempotencyKeyLen = 255

// derivedKeyPaths are the edge-api endpoints whose body is time-anchored, so an
// identical body means the same action. Any path NOT listed here only gets a key
// from the caller.
var derivedKeyPaths = map[string]bool{
	"/api/downtimes/create-manual-event":      true,
	"/api/production-orders/create-and-start": true,
	"/api/production-orders/stop":             true,
	"/api/production-orders/setup":            true,
}

// errBadIdempotencyKey is returned for a caller key that is too long or holds
// anything but visible ASCII.
var errBadIdempotencyKey = fmt.Errorf("invalid %s header: 1-%d visible ASCII characters", idempotencyHeader, maxClientIdempotencyKeyLen)

// idempotencyKeyFor returns the key to send to edge-api for this call ("" = none).
func idempotencyKeyFor(r *http.Request, call *edgeCall) (string, error) {
	if values := r.Header.Values(idempotencyHeader); len(values) > 0 {
		clientKey := values[0]
		if len(values) > 1 || !validClientKey(clientKey) {
			return "", errBadIdempotencyKey
		}
		return hashKey(call.idEnterprise, call.path, "client", []byte(clientKey)), nil
	}
	if !derivedKeyPaths[call.path] {
		return "", nil
	}
	body, err := json.Marshal(call.body)
	if err != nil {
		return "", fmt.Errorf("marshal edge body for idempotency key: %w", err)
	}
	return hashKey(call.idEnterprise, call.path, "body", body), nil
}

func validClientKey(k string) bool {
	if k == "" || len(k) > maxClientIdempotencyKeyLen {
		return false
	}
	for i := 0; i < len(k); i++ {
		if k[i] < 0x21 || k[i] > 0x7e {
			return false
		}
	}
	return true
}

// hashKey builds "opgw-" + hex(sha256(enterprise, path, source, material)). The
// NUL separators keep the fields from running into each other.
func hashKey(idEnterprise int, path, source string, material []byte) string {
	h := sha256.New()
	fmt.Fprintf(h, "operator-gateway\x00%d\x00%s\x00%s\x00", idEnterprise, path, source)
	h.Write(material)
	return "opgw-" + hex.EncodeToString(h.Sum(nil))
}
