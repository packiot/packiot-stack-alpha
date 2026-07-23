// ─────────────────────────────────────────────────────────────────────────────
// CPACK → sparkplug-agent raw-tag tee — Node-RED `function` node body
// ADR-0042 P1 (Mode-A "direct-to-ingest"). Copy-paste this into a `function`
// node placed on a SECOND wire off CPACK's PLC-read / raw-tag node (the point
// where each tag's topic + value are available). The existing publish path
// stays wired and untouched — this is a TEE, not a redirect.
//
// ⚠️ THIS IS A DIFFERENT ENDPOINT than the ADR-0032 cpack-tee-function.js.
//    • ADR-0032 tee  → ingest-shim /ingest/sparkplug  → oeecloud-worker LEGACY
//      decode (SparkPlug-JSON envelope, full metric names).
//    • THIS tee (P1) → sparkplug-agent /v1/tags → REAL SparkPlug B → mosquitto
//      → edge-transformer FULL prod Calc → F3 (raw-tag envelope, SUFFIX names).
//    The P1 path is the one that runs CPACK's real data through the REAL Calc,
//    closing the "real data bypasses the Calc" gap. Install ONE of the two.
//
// What it does:
//   1. Reads the ingest key from the Node-RED environment (NEVER hardcoded).
//   2. Strips the tenant prefix "CPACK/SC/LINHAS" off each tag topic to get the
//      SUFFIX the agent's raw_tag_map keys on (packml_topic + suffix = full).
//   3. Builds the rawtag envelope { group, endpoint, scan_ts, tags:[...] } the
//      agent's POST /v1/tags accepts, and sets the X-Ingest-Key header.
//
// KEY HANDLING (do NOT paste the secret into this flow):
//   Set the key as a Node-RED environment variable named CPACK_AGENT_INGEST_KEY
//   (settings.js env, an OS env var on the Node-RED process, or the node's own
//   Environment Variables tab). The USER receives the value out-of-band; it is
//   the AGENT_INGEST_API_KEY the staging agent is started with.
//
// INPUT SHAPE this node expects (adapt block 2 to your flow):
//   Either msg.payload is an array of { topic, value, quality?, ts? } readings,
//   OR a single { topic, value } reading. `topic` is the FULL SparkPlug metric
//   name your PLC read already produces, e.g.:
//       CPACK/SC/LINHAS/L8/Status/StateCurrent
//       CPACK/SC/LINHAS/L8/Status/MachSpeed
//       CPACK/SC/LINHAS/L8/Admin/ProdProcessedCount/51/Unit
//       CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit
// ─────────────────────────────────────────────────────────────────────────────

// 1. Resolve the ingest key from the environment (never from the flow file).
const key = env.get("CPACK_AGENT_INGEST_KEY");
if (!key) {
    node.error("CPACK_AGENT_INGEST_KEY env var is not set — refusing to POST without an ingest key", msg);
    return null; // drop; fix the env, do not leak an unauthenticated request
}

const PREFIX = "CPACK/SC/LINHAS"; // agent packml_topic — stripped to form suffixes

// 2. Normalize the input to an array of readings. Adapt this to whatever your
//    PLC-read node emits. Each reading needs a full-topic `topic` + a `value`.
let readings = msg.payload;
if (!Array.isArray(readings)) {
    readings = [{ topic: msg.topic, value: (msg.payload && msg.payload.value !== undefined) ? msg.payload.value : msg.payload }];
}

// 3. Build the rawtag envelope: strip the prefix → suffix; carry value/quality.
const tags = [];
for (const r of readings) {
    if (!r || typeof r.topic !== "string" || r.value === undefined || r.value === null) continue;
    if (!r.topic.startsWith(PREFIX)) continue;      // not a CPACK/SC/LINHAS tag → skip
    const suffix = r.topic.slice(PREFIX.length);     // "/L8/Status/MachSpeed"
    if (suffix === "") continue;
    const tag = { metric: suffix, value: r.value };
    if (r.quality === false) tag.q = false;          // absent q ⇒ good
    if (Number.isInteger(r.value) && /StateCurrent$/.test(suffix)) tag.long = true; // PackML state = long
    if (r.ts) tag.ts = r.ts;                          // optional per-tag ts (unix millis)
    tags.push(tag);
}

if (tags.length === 0) {
    node.warn("cpack-agent tee: no CPACK/SC/LINHAS tags in this message; skipping");
    return null;
}

// 4. The envelope + headers. `group` lets the agent's scope guard 403 a
//    mis-routed payload (defense-in-depth); keep it "CPACK".
msg.payload = {
    group: "CPACK",
    endpoint: "cpack-edge",
    scan_ts: Date.now(),
    tags: tags
};
msg.headers = {
    "Content-Type": "application/json",
    "X-Ingest-Key": key
};
msg.url = env.get("CPACK_AGENT_INGEST_URL") || "https://cpack-ingest.staging.packiot.com:8447/v1/tags";
msg.method = "POST";
return msg;
