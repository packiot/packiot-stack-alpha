// openapi.go — serves the hand-written OpenAPI 3.1 description of this API.
//
// The spec lives next to the code as openapi.json and is embedded into the
// binary, so the document always ships with the build that implements it.
// openapi_test.go fails if a route is added here without being described there
// (or vice versa). The service serves the JSON only; the Swagger UI is a
// separate, SSO-gated portal that fetches this route in-network.
package adapter

import (
	_ "embed"
	"net/http"
)

//go:embed openapi.json
var openAPISpec []byte

// handleOpenAPI serves GET /openapi.json. Unauthenticated by design: the
// document contains no tenant data, and whether it is reachable from the
// internet is an nginx decision, not this service's.
func handleOpenAPI(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(openAPISpec)
}
