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
  openWebUi: (idEnterprise: number) =>
    apiClient
      .post<EdgeWebUi>(`${BASE}/webui`, { idEnterprise }, { skipErrorToast: true })
      .then((r) => r.data),
};

export function webUiEmbedUrl(sessionId: string, ticket: string): string {
  const base = import.meta.env.VITE_EDGE_API_URL || "";
  return `${base}/api/edge-ssm/webui/${encodeURIComponent(sessionId)}/?ticket=${encodeURIComponent(ticket)}`;
}
