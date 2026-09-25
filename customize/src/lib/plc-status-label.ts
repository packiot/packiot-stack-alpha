import type { PlcStatus } from "@/api/plc-status";

/**
 * "Last seen" = when THIS PLC last sent data. A backend that sends `liveness`
 * computes `last_data_ts` over a 2 h window, so null there means "nothing in 2 h"
 * — NOT a reason to show `last_updated`, which is the snapshot table's shared
 * batch-refresh time (it read "51s ago" on PLCs silent for 8-26 h). Only an old
 * backend (no `liveness`) falls back to it.
 */
export function lastSeenLabel(r: Pick<PlcStatus, "liveness" | "last_data_ts" | "last_updated">): string {
  if (r.liveness) return r.last_data_ts ? ageLabel(r.last_data_ts) : "no data in 2h";
  return ageLabel(r.last_data_ts ?? r.last_updated);
}

export function ageLabel(lastDataTs?: string | null): string {
  if (!lastDataTs) return "—";
  const diff = Date.now() - new Date(lastDataTs).getTime();
  if (Number.isNaN(diff)) return "—";
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}
