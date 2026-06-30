// recognizers.go — local copies of the "edge-api error message is actually
// idempotent-success" predicates used by the user_logs replay handlers
// (see services/mirror-worker-go/internal/replay/httputil.go).
//
// Why duplicate vs import: the replay package's classifier wraps matches
// as `replay.ErrSkipReplay`, which is the dispatcher's sentinel — wrong
// semantics for the reconciler. The reconciler needs to RECOVER from the
// already-exists / already-running shapes (look up the existing PO, start
// it, write a mapping), not skip the row. Same message literals, different
// downstream behaviour.
//
// Bodies match the exact NestJS exception strings in:
//   - edge-api/src/usecases/production-orders/create-production-order/.../service.ts
//       throw new BadRequestException('Production order already exists');
//   - edge-api/src/usecases/production-orders/setup-production-order/.../service.ts
//       throw new BadRequestException('Production order already exists!');
//   - edge-api/src/usecases/production-orders/start-production-order/.../service.ts
//       throw new BadRequestException('Production order already running');
//
// Match is on the exact `message` field of the JSON envelope; punctuation
// kept as-is (the create vs setup endpoints disagree on the trailing "!").

package reconcile

import (
	"bytes"
	"encoding/json"
)

// alreadyExistsMessages — exact edge-api message literals for the
// /api/production-orders/{create,setup,create-and-start} "PO already
// exists" rejection. Both punctuation variants are kept as separate
// entries because edge-api isn't consistent and we match literally.
var alreadyExistsMessages = map[string]struct{}{
	"Production order already exists":  {},
	"Production order already exists!": {},
}

// alreadyRunningMessages — exact edge-api message literal for the
// /api/production-orders/start "PO already running" rejection. Surfaced
// when the reconciler's revive path calls /start on a staging PO that
// turns out to be already in status=2 (race against another writer or
// against an in-flight user_logs replay).
var alreadyRunningMessages = map[string]struct{}{
	"Production order already running": {},
}

// edgeAPIError matches the JSON body emitted by edge-api's global
// HttpExceptionFilter: { statusCode, message, error? }. Only the message
// field matters for the recognizer decision. Duplicate of the replay
// package's identical struct — kept local to avoid a cross-package import
// for one trivial type.
type edgeAPIError struct {
	Message string `json:"message"`
}

// isAlreadyExists returns true when the response body's `message` field
// matches the edge-api "PO already exists" literal. Falls back to a
// trimmed-bytes comparison if the body isn't JSON (some edge-api error
// paths emit plain text instead of the envelope).
func isAlreadyExists(body []byte) bool {
	return isClassifiedMessage(body, alreadyExistsMessages)
}

// isAlreadyRunning returns true for the "PO already running" rejection
// shape. Same JSON-or-plain-text body handling as isAlreadyExists.
func isAlreadyRunning(body []byte) bool {
	return isClassifiedMessage(body, alreadyRunningMessages)
}

func isClassifiedMessage(body []byte, set map[string]struct{}) bool {
	var parsed edgeAPIError
	if json.Unmarshal(body, &parsed) == nil && parsed.Message != "" {
		_, ok := set[parsed.Message]
		return ok
	}
	// Plain-text body — trim trailing newline(s) and treat the whole
	// body as the candidate. Bounded so a 50KB HTML error page can't
	// accidentally collide.
	const maxPlainTextMsgLen = 256
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || len(trimmed) > maxPlainTextMsgLen {
		return false
	}
	_, ok := set[string(trimmed)]
	return ok
}
