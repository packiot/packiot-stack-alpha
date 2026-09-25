import type { NodeRedNode } from "@/api/onboarding";

/**
 * Parse + validate the customizations textarea (a JSON array of raw Node-RED
 * nodes) with the SAME rule the edge-transformer descriptor validator enforces
 * (validateCustomizations): each node needs a non-empty string `id` + `type`, ids
 * unique. A malformed paste fails at author time, not on the deployed flow.
 */
export function parseCustomizations(
  text: string
): { nodes: NodeRedNode[] } | { error: string } {
  const trimmed = text.trim();
  if (trimmed === "") return { nodes: [] };
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    return { error: e instanceof Error ? e.message : "Invalid JSON" };
  }
  if (!Array.isArray(parsed)) {
    return { error: "Customizations must be a JSON array of Node-RED nodes (paste a Node-RED export)." };
  }
  const seen = new Set<string>();
  for (let i = 0; i < parsed.length; i++) {
    const n = parsed[i];
    if (typeof n !== "object" || n == null || Array.isArray(n)) {
      return { error: `Node ${i} must be an object.` };
    }
    const node = n as Record<string, unknown>;
    const id = typeof node.id === "string" ? node.id.trim() : "";
    if (id === "") return { error: `Node ${i}: a non-empty string "id" is required.` };
    if (typeof node.type !== "string" || node.type.trim() === "") {
      return { error: `Node ${i} (id "${id}"): a non-empty string "type" is required.` };
    }
    if (seen.has(id)) return { error: `Duplicate node id "${id}" — every Node-RED node id must be unique.` };
    seen.add(id);
  }
  return { nodes: parsed as NodeRedNode[] };
}
