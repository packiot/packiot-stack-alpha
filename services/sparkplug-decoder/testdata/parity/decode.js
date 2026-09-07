// ADR-0010 Phase 1 parity harness — Node.js side.
//
// Reads a binary Sparkplug B payload from stdin and prints a canonical JSON
// projection to stdout. The Go decoder produces the same shape (see the
// paired parity_test.go). Diffing the two outputs proves cross-implementation
// parity of the vendored Eclipse Tahu protobuf schema.
//
// Uses `sparkplug-payload` — the exact library Node-RED's
// `node-red-contrib-sparkplug-payload` node wraps. Comparing to Go's decoder
// therefore tests parity at the SAME abstraction level Node-RED consumes.
//
// Usage:
//   node decode.js < payload.bin | jq .
//
// Or invoked from Go tests: see internal/sparkplug/parity_test.go.

const sp = require('sparkplug-payload');
const spb = sp.get('spBv1.0');

async function main() {
    // Read all stdin bytes.
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    const buf = Buffer.concat(chunks);

    // Decode via the exact library Node-RED uses.
    const payload = spb.decodePayload(buf);

    // Canonical projection: strip Buffer/BigInt for JSON compat + pick fields
    // both sides can produce identically. This is the diffable shape.
    const canonical = {
        timestamp: toNum(payload.timestamp),
        seq: toNum(payload.seq),
        metric_count: (payload.metrics || []).length,
        metrics: (payload.metrics || []).map(m => ({
            name: m.name || null,
            alias: toNum(m.alias),
            timestamp: toNum(m.timestamp),
            type: m.type || null,   // string name like "Int64" — sparkplug-payload's mapping
            value: coerceValue(m.value),
        })),
    };

    process.stdout.write(JSON.stringify(canonical));
}

// sparkplug-payload uses Long.js (via protobufjs) for uint64 fields. Long
// values arrive as objects: { high: int, low: int, unsigned: bool }. Convert
// to a JS number when safe (high == 0 and low fits), else to string.
function toNum(x) {
    if (x == null) return null;
    if (typeof x === 'bigint') {
        return x <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(x) : x.toString();
    }
    // Long.js shape from protobufjs.
    if (isLong(x)) {
        // Reconstruct: (high << 32) | low  (for unsigned; low can be negative
        // when interpreted as signed int32).
        const low = x.low >>> 0;   // to unsigned 32-bit
        const high = x.high;
        if (high === 0) return low;               // fits in 32 bits
        if (high === -1 && !x.unsigned) return low - 0x100000000; // small negative
        // Fall through to string for anything larger.
        const val = BigInt(high) * (1n << 32n) + BigInt(low);
        return val <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(val) : val.toString();
    }
    return x;
}

function isLong(x) {
    return x != null && typeof x === 'object'
        && typeof x.low === 'number' && typeof x.high === 'number'
        && typeof x.unsigned === 'boolean';
}

// Metric values can be numbers, strings, booleans, Buffers, BigInts, Longs.
// Normalize each to a JSON-safe primitive.
function coerceValue(v) {
    if (v == null) return null;
    if (typeof v === 'bigint') {
        return v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v.toString();
    }
    if (isLong(v)) return toNum(v);
    if (Buffer.isBuffer(v)) return v.toString('base64');
    return v;
}

main().catch(err => {
    console.error('decode error:', err.message);
    process.exit(1);
});
