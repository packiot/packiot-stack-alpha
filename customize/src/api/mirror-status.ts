import { apiClient } from "@/lib/api-client";

/**
 * ADR-0064 — is the selected enterprise a read-only mirror of PRODUCTION on this environment?
 * edge-api `GET /api/environment/mirror-status` (the selected tenant travels as ?idEnterprise, like every call).
 * When `mirror` is true every write is refused (403 MIRROR_TENANT_WRITE_BLOCKED): configure in production instead.
 */
export interface MirrorStatus {
  mirror: boolean;
  idEnterprise: number | null;
  productionUrl: string | null;
  message: string | null;
}

export const NOT_A_MIRROR: MirrorStatus = { mirror: false, idEnterprise: null, productionUrl: null, message: null };

/** Normalises the response; anything unexpected (older edge-api: 404) means "not a mirror". */
export function parseMirrorStatus(data: unknown): MirrorStatus {
  if (!data || typeof data !== "object") return NOT_A_MIRROR;
  const d = data as Record<string, unknown>;
  if (d.mirror !== true) return NOT_A_MIRROR;
  return {
    mirror: true,
    idEnterprise: typeof d.idEnterprise === "number" ? d.idEnterprise : null,
    productionUrl: typeof d.productionUrl === "string" ? d.productionUrl : null,
    message:
      typeof d.message === "string"
        ? d.message
        : "This enterprise is a read-only mirror of production here. Make changes in production.",
  };
}

export async function fetchMirrorStatus(): Promise<MirrorStatus> {
  try {
    const { data } = await apiClient.get("/api/environment/mirror-status", { skipErrorToast: true });
    return parseMirrorStatus(data);
  } catch {
    return NOT_A_MIRROR;
  }
}
