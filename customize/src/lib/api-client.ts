import axios, { AxiosError, type InternalAxiosRequestConfig } from "axios";
import { toast } from "sonner";
import { getAuthToken } from "@/lib/auth-token";
import { useEnterpriseStore } from "@/stores/enterprise-store";

declare module "axios" {
  export interface AxiosRequestConfig {
    /**
     * When true, the response error interceptor does NOT fire the global toast.
     * For calls whose failure the caller renders itself (e.g. an EXPECTED 404
     * shown as an empty/disabled state) — see api/onboarding.ts.
     */
    skipErrorToast?: boolean;
  }
}

/**
 * Shared axios instance pointed at edge-api — the ADR-0026 write/control plane
 * and the single source of topology (enterprises → sites → areas → equipments →
 * shifts → packml_register). Base URL is the edge-api host root; every route
 * already carries its own `/api/...` prefix (edge-api has NO global prefix).
 *
 * TWO request interceptors:
 *  1. attachBearer — dual-path credential (Cognito id-token when enabled, else
 *     the Firebase token) via auth-token.ts, sent as `Authorization: Bearer …`.
 *  2. attachTenantTarget — CS Admin operates ACROSS tenants. edge-api's CS-Admin
 *     auth path (ADR-0033) honors `?idEnterprise=<target>` for tokens whose
 *     `cognito:groups` include the CS group, and otherwise ignores it (a regular
 *     user's tenant is derived + locked server-side). So we attach the selected
 *     enterprise as a query param on every scoped call — this is what routes a
 *     write to the right tenant. Enterprise-level routes are exempt (the target
 *     is the enterprise itself, carried in the body / path).
 */
export const apiClient = axios.create({
  baseURL: import.meta.env.VITE_EDGE_API_URL,
  headers: { "Content-Type": "application/json" },
});

async function attachBearer(config: InternalAxiosRequestConfig) {
  const token = await getAuthToken();
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
}

function attachTenantTarget(config: InternalAxiosRequestConfig) {
  // The `enterprises` resource IS the tenant object — never scope it to itself.
  const url = config.url ?? "";
  if (url.startsWith("/api/enterprises")) return config;

  const selected = useEnterpriseStore.getState().selected;
  if (!selected) return config;

  const params = (config.params ?? {}) as Record<string, unknown>;
  // Don't clobber an explicit filter the caller already set.
  if (params.idEnterprise == null) {
    params.idEnterprise = selected.id_enterprise;
    config.params = params;
  }
  return config;
}

apiClient.interceptors.request.use(attachBearer);
apiClient.interceptors.request.use(attachTenantTarget);

apiClient.interceptors.response.use(
  (response) => response,
  (error: AxiosError<{ message?: string }>) => {
    const message =
      error.response?.data?.message ??
      error.message ??
      "Unexpected server error.";
    // A caller may opt out of the global toast (e.g. an EXPECTED 404 it renders
    // itself as a graceful empty/disabled state) by setting `skipErrorToast` on
    // the request config. Everything else still surfaces the toast.
    const skipToast = Boolean(
      (error.config as { skipErrorToast?: boolean } | undefined)?.skipErrorToast
    );
    if (error.response?.status !== 401 && !skipToast) {
      toast.error(message);
    }
    return Promise.reject(error);
  }
);
