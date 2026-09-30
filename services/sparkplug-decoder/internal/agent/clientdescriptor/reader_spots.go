package clientdescriptor

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// AuthoringError marks a generate-time failure caused by what the descriptor's
// AUTHOR wrote (a customization id colliding with a generated node, a typo'd or
// wrong-direction spot link) — as opposed to a generator fault. Validate() cannot
// see these (they need the rendered reader's reserved ids), so they surface at
// Generate; callers use IsAuthoringError to answer 4xx, not 5xx.
type AuthoringError struct{ Err error }

func (e *AuthoringError) Error() string { return e.Err.Error() }
func (e *AuthoringError) Unwrap() error { return e.Err }

// IsAuthoringError reports whether err (possibly wrapped) is an AuthoringError.
func IsAuthoringError(err error) bool {
	var a *AuthoringError
	return errors.As(err, &a)
}

// Reader SPOTS — the named attach points the generated reader tab exposes to the
// customizations (ADR-0058 Tier 2). Before spots, a pasted Node-RED flow landed on
// the customizations tab as an island: it could not see a PLC read or add a tag,
// because nothing on the generated reader tab wired to it (and hand-wiring on the
// box is lost on regeneration). A spot is a Node-RED `link` node with a
// DETERMINISTIC id (<tenant>_spot_<key>), so a customization can reference it by
// id in its descriptor and the reference survives every regeneration.
//
// Two kinds, chosen so a customization can never break the core pipeline:
//   - TAP (`link out`): a fan-out COPY of a message at one stage of the reader.
//     The core path keeps its own wire; a customization subscribes with a `link
//     in` whose "links" names the spot. A slow/broken customization cannot stall
//     or alter the POST to the agent.
//   - ENTRY (`link in`, only "publish"): feeds the normalize function, so a
//     customization can publish EXTRA tags ({ "<full canonical topic>": number })
//     through the same keyed, authenticated POST the PLC reads use — no second
//     ingest path, no key in the customization.
//
// Keep ReaderSpots in sync with customize/src/lib/node-red-spots.ts (the UI's
// spot picker); TestReaderSpotsContract pins the ids + kinds.

// SpotKind distinguishes a fan-out tap from the publish entry.
type SpotKind string

const (
	SpotTap   SpotKind = "tap"
	SpotEntry SpotKind = "entry"
)

// ReaderSpot documents one attach point (key → id suffix, kind, what flows there).
type ReaderSpot struct {
	Key   string
	Kind  SpotKind
	Label string
}

// ReaderSpots is the ordered, stable spot catalogue.
var ReaderSpots = []ReaderSpot{
	{Key: "reads", Kind: SpotTap, Label: "PLC reads (raw, before normalize)"},
	{Key: "tags", Kind: SpotTap, Label: "Normalized raw tags (the envelope POSTed to the agent)"},
	{Key: "ingest_result", Kind: SpotTap, Label: "Agent ingest response (every POST)"},
	{Key: "ingest_error", Kind: SpotTap, Label: "Agent ingest errors (non-2xx)"},
	{Key: "publish", Kind: SpotEntry, Label: "Publish extra tags → normalize → agent"},
}

// SpotID is the deterministic node id of a spot for a tenant prefix.
func SpotID(prefix, key string) string { return prefix + "_spot_" + key }

// appendReaderSpots adds the spot link nodes to the reader tab and wires the
// taps off the existing pipeline stages. The core wires are only ever EXTENDED
// (a tap is an extra target on an output), never replaced.
func appendReaderSpots(nodes []map[string]any, p, tabID, fnID, httpID, switchID string, midY int) []map[string]any {
	reads, tags := SpotID(p, "reads"), SpotID(p, "tags")
	result, ingestErr, publish := SpotID(p, "ingest_result"), SpotID(p, "ingest_error"), SpotID(p, "publish")
	scrub := tags + "_scrub"

	for _, n := range nodes {
		if n["z"] != tabID {
			continue
		}
		id, _ := n["id"].(string)
		switch {
		case id == fnID:
			// Never hand normalize's output to a customization directly: it carries
			// msg.headers["X-Ingest-Key"] + msg.url for the agent POST, and a
			// customization `http request` would forward that key to whatever URL
			// it calls (caught in the runtime proof, not by a unit test).
			addTapWire(n, 0, scrub)
		case id == httpID:
			addTapWire(n, 0, result)
		case id == switchID:
			addTapWire(n, 1, ingestErr)
		case feedsNode(n, 0, fnID):
			// every PLC source (s7 in / modbus-read / opcua client) → raw reads tap
			addTapWire(n, 0, reads)
		}
	}

	tap := func(key string, x, y int) map[string]any {
		return map[string]any{
			"id": SpotID(p, key), "type": "link out", "z": tabID,
			"name": "spot: " + key, "mode": "link", "links": []any{},
			"x": x, "y": y,
		}
	}
	return append(nodes,
		map[string]any{
			"id": scrub, "type": "change", "z": tabID,
			"name": "strip ingest key/url", "rules": []any{
				map[string]any{"t": "delete", "p": "headers", "pt": "msg"},
				map[string]any{"t": "delete", "p": "url", "pt": "msg"},
			},
			"x": 1120, "y": midY - 120, "wires": []any{[]any{tags}},
		},
		tap("reads", 640, 40),
		tap("tags", 1120, midY-80),
		tap("ingest_result", 1320, midY-80),
		tap("ingest_error", 1720, midY+40),
		map[string]any{
			"id": publish, "type": "link in", "z": tabID,
			"name": "spot: publish", "links": []any{},
			"x": 700, "y": midY + 80, "wires": []any{[]any{fnID}},
		},
	)
}

// feedsNode reports whether output `out` of n is wired to target.
func feedsNode(n map[string]any, out int, target string) bool {
	wires, _ := n["wires"].([]any)
	if out >= len(wires) {
		return false
	}
	targets, _ := wires[out].([]any)
	for _, t := range targets {
		if t == target {
			return true
		}
	}
	return false
}

// addTapWire appends target to output `out` of n (growing the wires as needed).
func addTapWire(n map[string]any, out int, target string) {
	wires, _ := n["wires"].([]any)
	for len(wires) <= out {
		wires = append(wires, []any{})
	}
	targets, _ := wires[out].([]any)
	wires[out] = append(targets, target)
	n["wires"] = wires
}

// spotRef is one emitted spot node plus the links it accumulates.
type spotRef struct {
	kind  SpotKind
	node  map[string]any
	links []any
}

// readerSpotIndex maps spot id → its emitted node, for subscription back-fill.
func readerSpotIndex(nodes []map[string]any, p string) map[string]*spotRef {
	kinds := map[string]SpotKind{}
	for _, s := range ReaderSpots {
		kinds[SpotID(p, s.Key)] = s.Kind
	}
	out := map[string]*spotRef{}
	for _, n := range nodes {
		id, _ := n["id"].(string)
		if k, ok := kinds[id]; ok {
			out[id] = &spotRef{kind: k, node: n, links: []any{}}
		}
	}
	return out
}

// subscribeSpots back-fills a customization link node onto the spots it names.
// A `link in` may subscribe to TAP spots; a `link out` may target the PUBLISH
// entry. Any other reference into the spot namespace is a fail-closed error — a
// typo'd spot id would otherwise be a silently dead wire on the box.
func subscribeSpots(spots map[string]*spotRef, node map[string]any, i int, p string) error {
	typ, _ := node["type"].(string)
	if typ != "link in" && typ != "link out" {
		return nil
	}
	id, _ := node["id"].(string)
	refs, _ := node["links"].([]any)
	for _, r := range refs {
		rid, _ := r.(string)
		if !strings.HasPrefix(rid, p+"_spot_") {
			continue // a link between two customization nodes — not ours to check
		}
		s, ok := spots[rid]
		switch {
		case !ok:
			return fmt.Errorf("customizations[%d] (id %q): links to unknown reader spot %q — valid spots here: %s",
				i, id, rid, presentSpots(spots))
		case typ == "link in" && s.kind != SpotTap:
			return fmt.Errorf("customizations[%d] (id %q): a `link in` can only subscribe to a tap spot, not %q", i, id, rid)
		case typ == "link out" && s.kind != SpotEntry:
			return fmt.Errorf("customizations[%d] (id %q): a `link out` can only send to the publish spot, not %q", i, id, rid)
		}
		s.links = append(s.links, id)
	}
	return nil
}

func presentSpots(spots map[string]*spotRef) string {
	ids := make([]string, 0, len(spots))
	for id := range spots {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return strings.Join(ids, ", ")
}
