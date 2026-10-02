/**
 * The reader SPOTS — named attach points on the generated PLC-reader tab that a
 * customization can wire into (ADR-0058 Tier 2). Mirrors ReaderSpots in
 * services/sparkplug-decoder/internal/agent/clientdescriptor/reader_spots.go;
 * TestReaderSpotsContract pins the ids/kinds there — change both together.
 *
 *  - tap   → a `link out` on the reader tab; a customization subscribes with a
 *            `link in` and receives a COPY of the message (can't stall the reader).
 *  - entry → a `link in` on the reader tab feeding the normalize function; a
 *            customization sends `{ payload: { "<full topic>": number } }` to it
 *            and the tags ride the reader's keyed POST to the agent.
 */
export type SpotKind = "tap" | "entry";

export interface ReaderSpot {
  key: string;
  kind: SpotKind;
  label: string;
  /** What arrives (tap) / what to send (entry) — shown in the picker. */
  hint: string;
}

export const READER_SPOTS: ReaderSpot[] = [
  {
    key: "reads",
    kind: "tap",
    label: "PLC reads (raw)",
    hint: "Every raw PLC read message before normalize — msg.payload is the s7/modbus/opcua read.",
  },
  {
    key: "tags",
    kind: "tap",
    label: "Normalized tags",
    hint: "The envelope sent to the agent: msg.payload = { endpoint, scan_ts, tags: [{ metric, value, ts }] }. Ingest key stripped.",
  },
  {
    key: "ingest_result",
    kind: "tap",
    label: "Agent response",
    hint: "The agent's HTTP response to every POST (msg.statusCode, msg.payload).",
  },
  {
    key: "ingest_error",
    kind: "tap",
    label: "Agent errors",
    hint: "Only non-2xx agent responses — alerting, buffering, etc.",
  },
  {
    key: "publish",
    kind: "entry",
    label: "Publish extra tags",
    hint: 'Send msg.payload = { "<full canonical topic>": <number>, … } — it is normalized and POSTed to the agent with the reader\'s own key.',
  },
];

/** The generator's node-id stem is the lower-cased descriptor tenant. */
export function tenantPrefix(tenant: string | undefined): string {
  return (tenant ?? "").toLowerCase();
}

export function spotId(prefix: string, key: string): string {
  return `${prefix}_spot_${key}`;
}

/** The generated customizations tab id (flow nodes not in a declared tab land here). */
export function custTabId(prefix: string): string {
  return `${prefix}_cust_tab`;
}
