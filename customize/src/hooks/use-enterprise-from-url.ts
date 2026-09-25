import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { enterprisesApi } from "@/api/enterprises";
import { useEnterpriseStore } from "@/stores/enterprise-store";

/**
 * Tenant hand-off between CS Admin and the Customization Hub. The two apps are
 * sibling subdomains with no shared browser state, so a cross-link carries
 * `?idEnterprise=N`. On arrival: if N isn't the selected tenant, load + select
 * it, then drop the param from the URL. "loading" while that is in flight so the
 * shell doesn't bounce to the enterprise picker (and lose the param) first. A
 * tenant the user can't read just falls through to the normal picker.
 */
export function useEnterpriseFromUrl(): "loading" | "ready" {
  const [params, setParams] = useSearchParams();
  const selected = useEnterpriseStore((s) => s.selected);
  const select = useEnterpriseStore((s) => s.select);
  const raw = params.get("idEnterprise");
  const want = raw != null && /^\d+$/.test(raw) ? Number(raw) : null;
  const needsSwitch = want != null && selected?.id_enterprise !== want;
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (raw == null) return;
    const strip = () => {
      const next = new URLSearchParams(params);
      next.delete("idEnterprise");
      setParams(next, { replace: true });
    };
    if (!needsSwitch) {
      strip();
      return;
    }
    let alive = true;
    enterprisesApi
      .get(want!)
      .then((e) => {
        if (alive) select(e);
      })
      .catch(() => {
        /* not readable → the normal picker handles it */
      })
      .finally(() => {
        if (!alive) return;
        strip();
        setDone(true);
      });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [raw]);

  return needsSwitch && !done ? "loading" : "ready";
}
