import type { NodeRedNode } from "@/api/onboarding";
import { custTabId, READER_SPOTS, spotId } from "@/lib/node-red-spots";

/**
 * The Node-RED flow inserter's pure core: take whatever a CS engineer pastes
 * (an editor "Export", a flows.json, a single node, a library snippet), make it
 * safe to append to the descriptor's `customizations`, and optionally wire it to
 * a reader spot. No React, no IO — every rule here is unit-tested.
 */

export type Node = NodeRedNode & { id: string; type: string };

const CONTAINER_TYPES = new Set(["tab", "subflow"]);

/** Accept every shape Node-RED hands out and return a flat node array. */
export function parseNodeRedPaste(text: string): { nodes: Node[] } | { error: string } {
  const trimmed = text.trim();
  if (!trimmed) return { error: "Paste a Node-RED export first." };
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    return { error: `Not valid JSON: ${e instanceof Error ? e.message : String(e)}` };
  }
  // v2 GET /flows {rev, flows}; library/snippet {nodes}; one bare node object.
  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    const o = parsed as Record<string, unknown>;
    if (Array.isArray(o.flows)) parsed = o.flows;
    else if (Array.isArray(o.nodes)) parsed = o.nodes;
    else parsed = [o];
  }
  if (!Array.isArray(parsed)) return { error: "Expected a JSON array of Node-RED nodes." };
  const seen = new Set<string>();
  for (let i = 0; i < parsed.length; i++) {
    const n = parsed[i] as Record<string, unknown> | null;
    if (!n || typeof n !== "object" || Array.isArray(n)) return { error: `Node ${i} is not an object.` };
    if (typeof n.id !== "string" || !n.id.trim()) return { error: `Node ${i}: missing a string "id".` };
    if (typeof n.type !== "string" || !n.type.trim()) return { error: `Node ${i} (${n.id}): missing a string "type".` };
    if (seen.has(n.id)) return { error: `Duplicate id "${n.id}" inside the paste.` };
    seen.add(n.id);
  }
  return { nodes: parsed as Node[] };
}

/** A flow node sits on a tab/subflow (has z); config/tab/subflow nodes do not. */
export const isFlowNode = (n: Node) => typeof n.z === "string" && !CONTAINER_TYPES.has(n.type);

function outputs(n: Node): string[][] {
  return Array.isArray(n.wires) ? (n.wires as unknown[]).map((w) => (Array.isArray(w) ? (w as string[]) : [])) : [];
}

export interface Finding {
  level: "error" | "warning";
  message: string;
  nodeId?: string;
}

export interface FlowAnalysis {
  total: number;
  flowNodes: number;
  configNodes: number;
  tabs: Node[];
  subflows: Node[];
  byType: [string, number][];
  /** Flow nodes nothing wires into — where a tap feeds the snippet. */
  entries: Node[];
  /** Flow nodes with an output wired to nothing — where publish is fed from. */
  exits: Node[];
  findings: Finding[];
  /** Ids already present in the existing customizations or reserved by the generator. */
  collisions: string[];
}

// Mirrors clientdescriptor.checkFunctionBounds (ADR-0009): the server rejects these
// on save; surfacing them here saves a round-trip and names the node.
const MAX_FUNCTION_LINES = 200;
const INLINE_NETWORK =
  /\b(?:require\s*\(\s*['"](?:https?|axios|node-fetch|request|net|dgram|dns)\b|fetch\s*\(|XMLHttpRequest|https?\.(?:request|get)\s*\(|WebSocket\s*\()/i;
const UNSAFE_EVAL = /\b(?:eval\s*\(|new\s+Function\s*\(|require\s*\(\s*['"]vm['"])/i;

export function analyzeFlow(nodes: Node[], existing: Node[], prefix: string): FlowAnalysis {
  const ids = new Set(nodes.map((n) => n.id));
  const incoming = new Set<string>();
  const findings: Finding[] = [];
  const counts = new Map<string, number>();

  for (const n of nodes) {
    counts.set(n.type, (counts.get(n.type) ?? 0) + 1);
    for (const out of outputs(n)) {
      for (const t of out) {
        incoming.add(t);
        if (!ids.has(t)) {
          findings.push({ level: "warning", nodeId: n.id, message: `${label(n)} is wired to "${t}", which is not in the paste — that wire will be dropped by Node-RED.` });
        }
      }
    }
    if (n.type === "function") {
      const code = typeof n.func === "string" ? n.func : "";
      const lines = code.split("\n").length;
      if (lines > MAX_FUNCTION_LINES)
        findings.push({ level: "error", nodeId: n.id, message: `${label(n)}: function body is ${lines} lines (limit ${MAX_FUNCTION_LINES}) — split it or use a derive rule.` });
      if (INLINE_NETWORK.test(code))
        findings.push({ level: "error", nodeId: n.id, message: `${label(n)}: makes an inline network call — use an "http request" node instead.` });
      if (UNSAFE_EVAL.test(code))
        findings.push({ level: "error", nodeId: n.id, message: `${label(n)}: uses eval/new Function/vm — not allowed.` });
    }
    if (n.type === "link in" || n.type === "link out") {
      for (const l of (Array.isArray(n.links) ? n.links : []) as string[]) {
        if (!ids.has(l) && !l.startsWith(`${prefix}_spot_`))
          findings.push({ level: "warning", nodeId: n.id, message: `${label(n)} links to "${l}", which is neither in the paste nor a reader spot.` });
      }
    }
  }

  const reserved = new Set(existing.map((n) => n.id));
  const collisions = nodes
    .map((n) => n.id)
    .filter((id) => reserved.has(id) || (prefix !== "" && id.startsWith(`${prefix}_`)));

  const flow = nodes.filter(isFlowNode);
  return {
    total: nodes.length,
    flowNodes: flow.length,
    configNodes: nodes.filter((n) => n.z === undefined && !CONTAINER_TYPES.has(n.type)).length,
    tabs: nodes.filter((n) => n.type === "tab"),
    subflows: nodes.filter((n) => n.type === "subflow"),
    byType: [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])),
    entries: flow.filter((n) => !incoming.has(n.id) && n.type !== "comment" && n.type !== "link in" && n.type !== "inject"),
    exits: flow.filter(
      (n) => n.type !== "link out" && outputs(n).length > 0 && outputs(n).some((o) => o.length === 0),
    ),
    findings,
    collisions,
  };
}

function label(n: Node): string {
  const name = typeof n.name === "string" && n.name ? `"${n.name}"` : n.id;
  return `${n.type} ${name}`;
}

/** Fresh, Node-RED-shaped id (16 hex chars). */
export function newNodeId(rand: () => number = Math.random): string {
  let s = "";
  for (let i = 0; i < 16; i++) s += Math.floor(rand() * 16).toString(16);
  return s;
}

/**
 * Give every node a fresh id and rewrite EVERY reference consistently — z, g,
 * wires, links, subflow in/out ports, `subflow:<id>` instance types and any
 * config-node reference (a string property equal to an old id), which is how
 * Node-RED's own "import as copy" behaves. Lets the same snippet be inserted
 * twice, or pasted into a tenant whose ids collide.
 */
export function reidNodes(nodes: Node[], mint: () => string = () => newNodeId()): Node[] {
  const map = new Map<string, string>();
  for (const n of nodes) map.set(n.id, mint());
  const swap = (v: unknown): unknown => {
    if (typeof v === "string") return map.get(v) ?? v;
    if (Array.isArray(v)) return v.map(swap);
    if (v && typeof v === "object") {
      const o: Record<string, unknown> = {};
      for (const [k, x] of Object.entries(v)) o[k] = swap(x);
      return o;
    }
    return v;
  };
  return nodes.map((n) => {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(n)) {
      if (k === "type" && typeof v === "string" && v.startsWith("subflow:")) {
        out.type = `subflow:${map.get(v.slice(8)) ?? v.slice(8)}`;
      } else if (k === "func" || k === "info" || k === "name" || k === "label" || k === "template") {
        out[k] = v; // free text — never rewrite user code/prose
      } else {
        out[k] = swap(v);
      }
    }
    return out as Node;
  });
}

export type Placement = "customizations-tab" | "own-tab";

/**
 * Drop the pasted tab nodes when the author wants everything on the shared
 * customizations tab (the generator then re-homes their flow nodes); keep them
 * for "own tab". Subflows are always kept — their internals must stay inside.
 */
export function applyPlacement(nodes: Node[], placement: Placement): Node[] {
  return placement === "own-tab" ? nodes : nodes.filter((n) => n.type !== "tab");
}

/**
 * Wire the snippet to a reader spot by adding ONE link node on the snippet's
 * side (the generator back-fills the spot's side, TestReaderSpotsSubscription):
 *  - tap   → `link in` subscribed to the spot, wired into `targets` (entry nodes)
 *  - entry → `link out` to the publish spot, fed from `targets` (exit nodes)
 */
export function attachToSpot(
  nodes: Node[],
  spotKey: string,
  prefix: string,
  targets: string[],
  mint: () => string = () => newNodeId(),
): Node[] {
  const spot = READER_SPOTS.find((s) => s.key === spotKey);
  if (!spot) throw new Error(`Unknown spot "${spotKey}".`);
  if (targets.length === 0) throw new Error("Pick at least one node to connect to the spot.");
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const first = byId.get(targets[0]);
  if (!first) throw new Error(`Node "${targets[0]}" is not in the paste.`);
  const z = typeof first.z === "string" ? first.z : custTabId(prefix);
  const x = typeof first.x === "number" ? first.x : 200;
  const y = typeof first.y === "number" ? first.y : 100;
  const id = mint();
  const sid = spotId(prefix, spot.key);

  if (spot.kind === "tap") {
    const link: Node = { id, type: "link in", z, name: `← spot: ${spot.key}`, links: [sid], x: x - 160, y, wires: [targets] };
    return [...nodes, link];
  }
  const link: Node = { id, type: "link out", z, name: `→ spot: ${spot.key}`, mode: "link", links: [sid], x: x + 200, y };
  const wired = nodes.map((n) => {
    if (!targets.includes(n.id)) return n;
    const w = outputs(n);
    if (w.length === 0) w.push([]);
    w[0] = [...w[0], id];
    return { ...n, wires: w };
  });
  return [...wired, link];
}

/** Group the stored customizations by the tab/subflow they render onto. */
export function groupByContainer(nodes: Node[], prefix: string): { key: string; label: string; nodes: Node[] }[] {
  const containers = new Map(nodes.filter((n) => CONTAINER_TYPES.has(n.type)).map((n) => [n.id, n]));
  const groups = new Map<string, Node[]>();
  for (const n of nodes) {
    let key: string;
    if (CONTAINER_TYPES.has(n.type)) key = n.id;
    else if (typeof n.z === "string" && containers.has(n.z)) key = n.z;
    else if (typeof n.z === "string") key = custTabId(prefix);
    else key = "__config__";
    groups.set(key, [...(groups.get(key) ?? []), n]);
  }
  const labelOf = (key: string) => {
    if (key === "__config__") return "Config nodes (shared)";
    if (key === custTabId(prefix)) return "Customizations tab";
    const c = containers.get(key);
    const name = (c?.label ?? c?.name ?? key) as string;
    return c?.type === "subflow" ? `Subflow · ${name}` : `Tab · ${name}`;
  };
  return [...groups.entries()].map(([key, ns]) => ({ key, label: labelOf(key), nodes: ns }));
}

/** Remove nodes AND every wire/link pointing at them from the remaining nodes. */
export function removeNodes(nodes: Node[], drop: Set<string>): Node[] {
  // Dropping a tab/subflow also drops everything on it — scrub wires to THOSE too.
  const gone = new Set(drop);
  for (const n of nodes) if (typeof n.z === "string" && drop.has(n.z)) gone.add(n.id);
  return nodes
    .filter((n) => !gone.has(n.id))
    .map((n) => {
      const out: Node = { ...n };
      if (Array.isArray(n.wires)) out.wires = outputs(n).map((o) => o.filter((t) => !gone.has(t)));
      if (Array.isArray(n.links)) out.links = (n.links as string[]).filter((l) => !gone.has(l));
      return out;
    });
}
