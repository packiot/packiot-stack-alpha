import { apiClient } from "@/lib/api-client";

/**
 * The slice of edge-api's /api/edge-ssm the Customization Hub uses: the box's
 * connection summary (read-only — Box Ops in CS Admin owns every box action) and
 * the Node-RED editor embed (ADR-0057 web UI; editing flows is ADR-0058 Tier-2
 * customization, so it lives here). Types mirror csadmin/src/api/edge-ssm.ts.
 */
const BASE = "/api/edge-ssm";

export type EdgePingStatus =
  | "Online"
  | "ConnectionLost"
  | "Inactive"
  | string;

export interface EdgeStatus {
  registered: boolean;
  instanceId: string | null;
  pingStatus: EdgePingStatus | null;
  lastPingDateTime: string | null;
  agentVersion: string | null;
  platformName: string | null;
  platformVersion: string | null;
}

/** POST /webui result. */
export interface EdgeWebUi {
  sessionId: string;
  ticket: string;
  webUiLabel: string;
}

/** GET /connect — copy-paste operator shell + web-UI port-forward commands. */
export interface EdgeConnect {
  instanceId: string;
  shellCommand: string;
  /**
   * Port-forward for the box's local web UI. The server targets the port that
   * box class actually exposes — an on-prem-offline box has no Node-RED, so this
   * points at its edge-dashboard (:1881); a nodered/reader box points at
   * Node-RED (:1880). Field name kept for backward compat; use webUiLabel /
   * webUiPort for the honest, model-derived naming.
   */
  nodeRedPortForwardCommand: string;
  /**
   * Host port the forward targets — model-derived (1881 onprem, else 1880).
   * Optional so a csadmin ahead of the edge-api server change degrades to a
   * sane default rather than rendering "undefined".
   */
  webUiPort?: number;
  /** Label for the UI the forward reaches: "Edge dashboard" | "Node-RED". */
  webUiLabel?: string;
  /** Every screen the box offers (dashboard and/or Node-RED). Older servers omit it. */
  webUis?: { kind: "nodered" | "dashboard"; port: number; label: string }[];
}

/** One node the Node-RED plan would add/update/remove on the box. */
export interface NodeRedChange {
  id: string;
  type: string;
  name?: string;
  z?: string;
}

export type NodeRedApplyScope = "customizations" | "full";

/** GET /node-red/plan — dry-run diff of the SAVED descriptor vs the box. */
export interface NodeRedPlan {
  scope: NodeRedApplyScope;
  add: NodeRedChange[];
  update: NodeRedChange[];
  remove: NodeRedChange[];
  /** Nodes on a descriptor-owned tab that the saved descriptor doesn't render —
   *  hand-added in the box editor or removed from the descriptor. Full objects,
   *  so they can be adopted before an apply deletes them. */
  notInDescriptor: Record<string, unknown>[];
  unchanged: number;
  missingTypes: string[];
  blockers: string[];
  rev: string;
  descriptorVersion: number;
}

export interface NodeRedApplyResult extends NodeRedPlan {
  applied: boolean;
  mock?: boolean;
  mockMessage?: string;
}

export const edgeSsmApi = {
  status: (idEnterprise: number) =>
    apiClient
      .get<EdgeStatus>(`${BASE}/status`, { params: { idEnterprise }, skipErrorToast: true })
      .then((r) => r.data),
  connect: (idEnterprise: number) =>
    apiClient
      .get<EdgeConnect>(`${BASE}/connect`, { params: { idEnterprise }, skipErrorToast: true })
      .then((r) => r.data),
  /** Read-only dry run over a short-lived port-forward to the box's Node-RED. */
  nodeRedPlan: (idEnterprise: number, scope: NodeRedApplyScope) =>
    apiClient
      .get<NodeRedPlan>(`${BASE}/node-red/plan`, { params: { idEnterprise, scope }, skipErrorToast: true })
      .then((r) => r.data),
  /** Apply exactly what was planned (rev + descriptorVersion echo → 409 if either moved). */
  nodeRedApply: (idEnterprise: number, plan: Pick<NodeRedPlan, "rev" | "descriptorVersion" | "scope">) =>
    apiClient
      .post<NodeRedApplyResult>(
        `${BASE}/node-red/apply`,
        { idEnterprise, rev: plan.rev, descriptorVersion: plan.descriptorVersion, scope: plan.scope },
        { skipErrorToast: true },
      )
      .then((r) => r.data),
  /** Restart the shared data collector so it loads the client's saved calculations. */
  applyCalculations: (idEnterprise: number) =>
    apiClient
      .post<{ commandId: string; mock?: boolean; mockMessage?: string }>(
        `${BASE}/apply-calculations`,
        { idEnterprise },
        { skipErrorToast: true },
      )
      .then((r) => r.data),
  /** Restart the OEE calculator so it loads the client's saved OEE settings. */
  applyOeeSettings: (idEnterprise: number) =>
    apiClient
      .post<{ commandId: string; mock?: boolean }>(`${BASE}/apply-oee-settings`, { idEnterprise }, { skipErrorToast: true })
      .then((r) => r.data),
  openWebUi: (idEnterprise: number, target?: "nodered" | "dashboard") =>
    apiClient
      .post<EdgeWebUi>(`${BASE}/webui`, { idEnterprise, ...(target ? { target } : {}) }, { skipErrorToast: true })
      .then((r) => r.data),
};

export function webUiEmbedUrl(sessionId: string, ticket: string): string {
  const base = import.meta.env.VITE_EDGE_API_URL || "";
  return `${base}/api/edge-ssm/webui/${encodeURIComponent(sessionId)}/?ticket=${encodeURIComponent(ticket)}`;
}
