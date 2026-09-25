/**
 * Cross-links between the Customization Hub and CS Admin (csadmin.*).
 *
 * CS Admin owns the client's PLC CONNECTION (Box Ops, PackML register, sensor
 * config, PLC status); the hub owns CUSTOMIZATIONS. The two SPAs are sibling
 * subdomains with NO shared browser state, so every link carries the tenant as
 * `?idEnterprise=N` and the receiving app selects it on arrival — otherwise
 * CS Admin could open on a different client than the one being customized.
 *
 * Base URL: VITE_CSADMIN_URL when set, else the sibling host derived from this
 * one (customize.<env> → csadmin.<env>).
 */
function siblingBase(envUrl: string | undefined, from: string, to: string): string {
  if (envUrl) return envUrl.replace(/\/$/, "");
  const { protocol, host } = window.location;
  return host.startsWith(`${from}.`) ? `${protocol}//${to}.${host.slice(from.length + 1)}` : `${protocol}//${host}`;
}

export function csadminUrl(path: string, idEnterprise?: number): string {
  const base = siblingBase(import.meta.env.VITE_CSADMIN_URL, "customize", "csadmin");
  const q = idEnterprise != null ? `?idEnterprise=${idEnterprise}` : "";
  return `${base}${path}${q}`;
}
