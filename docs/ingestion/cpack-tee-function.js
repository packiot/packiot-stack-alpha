// ─────────────────────────────────────────────────────────────────────────────
// CPACK → staging ingest tee — Node-RED `function` node body
// ADR-0032 "direct from PLC" realization. Copy-paste this into a `function`
// node placed on a SECOND wire off CPACK's SparkPlug-assembly node (the point
// where the payload is already the SparkPlug-JSON envelope, i.e. right before
// the existing cloud/pubsub-out node). The existing publish path stays wired
// and untouched — this is a tee, not a redirect.
//
// What it does:
//   1. Confirms msg.payload is the SparkPlug-JSON envelope the cloud worker
//      already consumes (timestamp + metrics[] with slash-topic names).
//   2. Sets the two HTTP headers the ingest-shim requires: X-Ingest-Key
//      (auth) + Content-Type. The KEY IS NOT HARDCODED — it is read from the
//      Node-RED environment (see "KEY HANDLING" below).
//   3. Leaves msg.payload as the envelope so the downstream `http request`
//      node POSTs it verbatim. The shim republishes it VERBATIM onto the
//      `oee` exchange (routing key sparkplug.data.cpack) → oeecloud-worker →
//      packiot_analytics (F3), tenant-routed to CPACK (ent 3 staging) via the
//      already-seeded packml_register rows.
//
// KEY HANDLING (do NOT paste the secret into this flow):
//   Set the ingest key as a Node-RED environment variable named
//   CPACK_INGEST_KEY (settings.js `functionGlobalContext`/`env`, an OS env var
//   on the Node-RED process, or the node's own Environment Variables tab).
//   The USER receives the key value out-of-band (see README §"Key handling").
//
// TOPIC SHAPE — must match what packml_register expects for CPACK ent 3:
//   The cloud worker resolves each metric by its topic NAME (not by protobuf
//   alias), via TopicForRegister(). CPACK line/unit metric names look like:
//     CPACK/SC/LINHAS/L8/Status/StateCurrent
//     CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit
//     CPACK/SC/LINHAS/L8/Admin/ProdProcessedCount/51/Unit
//     CPACK/SC/LINHAS/L8/Admin/ProdDefectiveCount/51/Unit
//   The first segment (CPACK) is the scope group the shim enforces and the
//   tenant the worker routes on (lower("CPACK") = "cpack"). Keep it CPACK.
// ─────────────────────────────────────────────────────────────────────────────

// 1. Resolve the ingest key from the environment (never from the flow file).
const key = env.get("CPACK_INGEST_KEY");
if (!key) {
    node.error("CPACK_INGEST_KEY env var is not set — refusing to POST without an ingest key", msg);
    return null; // drop; fix the env, do not leak an unauthenticated request
}

// 2. Normalize to the envelope shape the worker's sparkplug.Parse expects.
//    If your assembly node already emits { timestamp, gateway, metrics:[...] }
//    this block is a no-op passthrough. If it emits only the metrics array,
//    wrap it. Adjust `gateway` to a stable identifier for this factory.
let env_payload = msg.payload;
if (Array.isArray(env_payload)) {
    env_payload = { timestamp: Date.now(), gateway: "cpack-edge", metrics: env_payload };
} else if (env_payload && !env_payload.timestamp) {
    env_payload.timestamp = Date.now();
}

// Guard: must carry at least one metric with a slash-topic name, or the shim's
// scope guard cannot read the group and returns 400.
if (!env_payload || !Array.isArray(env_payload.metrics) || env_payload.metrics.length === 0) {
    node.warn("tee: payload has no metrics[]; skipping this message");
    return null;
}

// Do NOT set source_type here — the shim stamps it (F1/F2/F3 fan-out) and
// overwrites any value the tee sends. Sending it is harmless but pointless.

// 3. Set headers for the http-request node. The shim wants exactly these.
msg.headers = {
    "Content-Type": "application/json",
    "X-Ingest-Key": key
};
msg.payload = env_payload;

// The downstream `http request` node is configured POST + "Return: parsed JSON",
// so msg.statusCode carries 202 (accepted) / 401 / 403 / 400 / 503 for the
// error-handling wire. See README §"Response handling".
return msg;
