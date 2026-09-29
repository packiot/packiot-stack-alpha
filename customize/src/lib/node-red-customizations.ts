import type { NodeRedNode } from "@/api/onboarding";

/**
 * Order-sensitive but key-order-independent JSON of a node list — the dirty
 * check for the customizations editor (a node round-tripped through the server
 * may come back with its keys reordered by JSONB; that is not an edit).
 */
export function stableNodesJson(nodes: NodeRedNode[]): string {
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
  return JSON.stringify(norm(nodes));
}
