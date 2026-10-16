import { apiClient } from "@/lib/api-client";

/** Per-machine liveness, derived by edge-api from max(equipment_values.ts_value). */
export type Liveness = "online" | "stale" | "offline";

/** One PLC's live snapshot (edge-api GET /api/plc-status ← uns_equipment_current_metrics).
 *  A "PLC" is the line/controller the box connects to (tp=3), or a standalone
 *  machine for machine-metered tenants with no lines. Fields are still per-row. */
export interface PlcStatus {
  id_equipment: number;
  nm_equipment: string;
  nm_area?: string | null;
  nm_site?: string | null;
  /** Raw PackML state code — the API sends this as a NUMBER (e.g. 6, 10). */
  state?: number | string | null;
  /** Human-readable state label ("lowSpeed", "stopped", …). Preferred in the UI. */
  status?: string | null;
  speed?: number | null;
  ideal_speed?: number | null;
  downtime_category?: string | null;
  downtime_subcategory?: string | null;
  /** Batch refresh timestamp of the UNS snapshot — NOT per-machine liveness. */
  last_updated?: string | null;
  /** TRUE per-machine freshness: when this machine last pushed data. Drives `liveness`. */
  last_data_ts?: string | null;
  /** Per-machine liveness: online (<5m), stale (<30m), offline (≥30m / never seen). */
  liveness?: Liveness | null;
}

export const plcStatusApi = {
  list: (idEnterprise: number) =>
    apiClient
      .get<PlcStatus[]>("/api/plc-status", { params: { idEnterprise } })
      .then((r) => r.data),
};

/**
 * GET /api/plc-status/plc-probe (edge-api #217) — a one-shot reachability check
 * for ONE PLC endpoint. edge-api resolves the tenant's enrolled edge box from
 * `idEnterprise` and routes the TCP probe through SSM to run ON the box
 * (`via:"ssm"`); a colocated/sandbox path may probe directly (`via:"direct"`).
 *
 * The endpoint is deliberately SOFT-FAILING: an unreachable PLC, a not-enrolled
 * box, or an SSM/agent error all come back as a 200 with the failure described in
 * `error`/`note` — never a 500. Only a missing/bad host/port/idEnterprise is a
 * 400. So we `skipErrorToast` and render every outcome inline per row.
 */
export interface PlcProbeResult {
  /** The PLC's TCP port accepted a connection (end-to-end reachable). */
  reachable: boolean;
  /** The edge agent/box the probe ran on was itself reachable (SSM Online). */
  agentReachable: boolean;
  /** Round-trip latency of the successful connect, or null when unreachable. */
  latencyMs: number | null;
  /** A failure reason (PLC refused/timed out, agent error) — null on success. */
  error: string | null;
  /** Guidance when there's nothing to probe THROUGH yet (e.g. enroll the box). */
  note: string | null;
  /** How the probe was routed: through the SSM-enrolled box, or directly. */
  via: "ssm" | "direct";
}

export interface ProbePlcParams {
  idEnterprise: number;
  host: string;
  port: number;
  /** Only for a colocated/sandbox direct path — omit for real clients. */
  agentHost?: string;
  timeout_ms?: number;
}

/**
 * A generous client-side ceiling. edge-api's probe is already bounded, but we
 * cap the axios request ourselves so a stuck SSM round-trip can never wedge the
 * row's spinner — the caller still wraps this in its own catch.
 *
 * Sized for the SLOW path, not the happy one: when the probe routes cloud → SSM →
 * box (`via:"ssm"`), edge-api runs a RunCommand on the box and waits for it, so a
 * real result can take ~20–30s to come back. A 20s ceiling clipped that — axios
 * aborted before the (HTTP 200) verdict arrived, so a perfectly good "PLC
 * unreachable / agent not answering" answer surfaced as a bogus "couldn't reach
 * the probe". 40s sits comfortably above the observed round-trip with headroom,
 * while still guaranteeing the spinner can't hang forever.
 */
const PROBE_CLIENT_TIMEOUT_MS = 40_000;

export function probePlc(params: ProbePlcParams): Promise<PlcProbeResult> {
  return apiClient
    .get<PlcProbeResult>("/api/plc-status/plc-probe", {
      params,
      skipErrorToast: true,
      timeout: PROBE_CLIENT_TIMEOUT_MS,
    })
    .then((r) => r.data);
}

/** A resolved PLC socket target derived from a descriptor endpoint's host ref. */
export interface HostPort {
  host: string;
  port: number;
}

/** Default PLC port per protocol when the host ref carries no explicit `:port`. */
export const DEFAULT_PLC_PORT: Record<string, number> = {
  s7: 102,
  modbus_tcp: 502,
  opcua: 4840,
};

/**
 * Derive a probeable `{ host, port }` from a descriptor endpoint's host ref.
 *
 *  - s7 / modbus_tcp: the ref is `host` or `host:port` — the explicit port wins,
 *    else the protocol default (s7→102, modbus_tcp→502).
 *  - opcua: the ref is an `opc.tcp://host:port/path` URL — we take host+port from
 *    the authority, defaulting the port to 4840.
 *
 * Returns null when no host can be derived: an empty ref, an unset
 * `secret://…` placeholder, or a colon with an empty/garbage host. The caller
 * disables "Test" in that case (there's nothing to probe).
 */
export function deriveHostPort(
  protocol: string | undefined,
  raw: string | undefined,
): HostPort | null {
  const value = (raw ?? "").trim();
  if (!value || value.startsWith("secret://")) return null;

  const proto = protocol ?? "s7";
  const fallbackPort = DEFAULT_PLC_PORT[proto] ?? DEFAULT_PLC_PORT.s7;

  if (proto === "opcua") {
    // Lenient: accept the ref with or without the scheme, ignore any /path.
    const authority = value.replace(/^opc\.tcp:\/\//i, "").split("/")[0] ?? "";
    return parseAuthority(authority, fallbackPort);
  }
  // s7 / modbus_tcp (and any other host-based protocol) — host or host:port.
  return parseAuthority(value, fallbackPort);
}

/** Split a `host` / `host:port` authority; fall back to the default port. */
function parseAuthority(authority: string, fallbackPort: number): HostPort | null {
  const trimmed = authority.trim();
  if (!trimmed) return null;

  const idx = trimmed.lastIndexOf(":");
  if (idx === -1) return { host: trimmed, port: fallbackPort };

  const host = trimmed.slice(0, idx).trim();
  if (!host) return null; // e.g. ":102" — no host to probe

  const port = Number(trimmed.slice(idx + 1).trim());
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    // A stray/empty/invalid port — keep the host, use the protocol default.
    return { host, port: fallbackPort };
  }
  return { host, port };
}
