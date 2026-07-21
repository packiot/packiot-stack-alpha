// ─────────────────────────────────────────────────────────────────────────────
// Incoplast → staging ingest tee — Node-RED `function` node body
// This CONFIRMS / re-issues the tee already documented at
// ~/incoplast-ingest/tee-node-setup.md. If a working tee is already installed
// in Incoplast's Node-RED, you do NOT need to reinstall — see the "DELTA vs the
// already-installed tee" note at the bottom.
//
// Placement: a SECOND wire off Incoplast's SparkPlug-assembly node
// (PackML2SparkPlug / "prepare_Sparkplug & DBIRTH" / "SparkPlug DDATA"), right
// before the existing `pubsub-out`. The pubsub-out stays wired and untouched.
//
// Incoplast quirk (already handled by the cloud worker): PackML2SparkPlug
// encodes metric `counter`/`curspeed`/`id` as STRINGS ("120", "4"); the worker
// tolerates both strings and numbers. Send the envelope AS-IS — do not reshape.
//
// KEY HANDLING: read from env var INCOPLAST_INGEST_KEY (never hardcode).
// ─────────────────────────────────────────────────────────────────────────────

const key = env.get("INCOPLAST_INGEST_KEY");
if (!key) {
    node.error("INCOPLAST_INGEST_KEY env var is not set — refusing to POST without an ingest key", msg);
    return null;
}

// At the tap point the payload is ALREADY the SparkPlug-JSON envelope Incoplast
// sends to PubSub. Pass it through verbatim; just guarantee a top-level ts.
let env_payload = msg.payload;
if (env_payload && !env_payload.timestamp) {
    env_payload.timestamp = Date.now();
}
if (!env_payload || !Array.isArray(env_payload.metrics) || env_payload.metrics.length === 0) {
    node.warn("tee: payload has no metrics[]; skipping this message");
    return null;
}

// Its INCOPLAST/… topics route it to enterprise 4 automatically via the seeded
// packml_register. The shim's scope guard admits it because the first topic
// segment is INCOPLAST. Do NOT set source_type — the shim stamps it.

msg.headers = {
    "Content-Type": "application/json",
    "X-Ingest-Key": key
};
msg.payload = env_payload;
return msg;

// ── DELTA vs the already-installed Incoplast tee ─────────────────────────────
// 1. ENDPOINT UNCHANGED: same ingest-shim on :8444, routing key
//    sparkplug.data.incoplast, scope group INCOPLAST. Incoplast's cloud path is
//    byte-unchanged by the CPACK work (CPACK gets its OWN shim instance :8446).
// 2. KEY: the earlier setup pasted the key inline in the doc; this version reads
//    it from env (INCOPLAST_INGEST_KEY) so the secret never lives in the flow
//    export. If you keep the old inline-key node, that's fine functionally —
//    this is a hardening, not a correctness change.
// 3. FAN-OUT (cloud side, no Node-RED change): today the shim triple-emits
//    (F1/F2/F3). When ADR-0032 collapses to F3-only, the cloud sets
//    FANOUT_SOURCE_TYPES=refactored on the shim — the tee node is untouched.
