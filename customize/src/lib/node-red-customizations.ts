import type { NodeRedNode } from "@/api/onboarding";

/**
 * Key-order-independent JSON — the dirty check for editors whose values
 * round-trip through the server (JSONB may return keys reordered; that is not
 * an edit).
 */
export function stableJson(value: unknown): string {
  const norm = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(norm);
    if (v && typeof v === "object") {
      return Object.fromEntries(
        Object.keys(v as Record<string, unknown>)
          .sort()
          .map((k) => [k, norm((v as Record<string, unknown>)[k])]),
      );
    }
    return v;
  };
  return JSON.stringify(norm(value));
}

/** stableJson for a Node-RED node list (order of nodes still matters). */
export function stableNodesJson(nodes: NodeRedNode[]): string {
  return stableJson(nodes);
}
