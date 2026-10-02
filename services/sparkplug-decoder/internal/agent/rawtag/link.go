package rawtag

import "encoding/json"

// Link is the optional per-endpoint CONNECTION report a connectivity plane may
// attach to a /v1/tags envelope (2026-10-01, PLC link health):
//
//	{ group, endpoint, scan_ts, tags: [...], link: { ok, err, ms } }
//
// ok=true  — this scan connected to the PLC and read it (tags may still be
//
//	empty if every value was unchanged or skipped).
//
// ok=false — the connect or the read failed; err carries the reason. Such an
//
//	envelope normally has tags: [] — before this field the reader posted
//	NOTHING on a failure, so the cloud saw the same silence as a stopped line.
//
// The field is additive: Decode ignores it (encoding/json drops unknown keys)
// and an older agent accepts the envelope unchanged.
type Link struct {
	Endpoint  string
	ScanTS    int64 // unix-millis of the scan (the reader's own clock; replays keep it)
	OK        bool
	Err       string
	LatencyMs int
}

type linkEnvelope struct {
	Endpoint string `json:"endpoint"`
	ScanTS   int64  `json:"scan_ts"`
	Link     *struct {
		OK  bool   `json:"ok"`
		Err string `json:"err"`
		Ms  int    `json:"ms"`
	} `json:"link"`
}

// maxLinkErr caps the stored error text (a PLC stack trace must not bloat a
// per-minute row).
const maxLinkErr = 300

// DecodeLink returns the envelope's link report, or ok=false when the body has
// none (or no endpoint / scan_ts to key it by).
func DecodeLink(body []byte) (Link, bool) {
	var env linkEnvelope
	if err := json.Unmarshal(body, &env); err != nil || env.Link == nil {
		return Link{}, false
	}
	if env.Endpoint == "" || env.ScanTS <= 0 {
		return Link{}, false
	}
	e := env.Link.Err
	if len(e) > maxLinkErr {
		e = e[:maxLinkErr]
	}
	return Link{Endpoint: env.Endpoint, ScanTS: env.ScanTS, OK: env.Link.OK, Err: e, LatencyMs: env.Link.Ms}, true
}
