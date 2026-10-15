import { useEffect, useState } from "react";
import { ShieldAlert } from "lucide-react";
import { fetchMirrorStatus, NOT_A_MIRROR, type MirrorStatus } from "@/api/mirror-status";
import { useEnterpriseStore } from "@/stores/enterprise-store";

/**
 * ADR-0064 read-only banner: shown when the selected enterprise is a mirror of production on this environment
 * (staging after the tenant's production go-live). Every save would be refused by edge-api anyway; the banner says
 * so before anyone tries, and links to production.
 */
export function MirrorBanner() {
  const id = useEnterpriseStore((s) => s.selected?.id_enterprise);
  const [status, setStatus] = useState<MirrorStatus>(NOT_A_MIRROR);
  useEffect(() => {
    let live = true;
    setStatus(NOT_A_MIRROR);
    if (id != null) fetchMirrorStatus().then((s) => live && setStatus(s));
    return () => {
      live = false;
    };
  }, [id]);
  if (!status.mirror) return null;
  return (
    <div role="alert" className="flex flex-none items-center gap-2 bg-amber-500 px-5 py-2 text-sm font-semibold text-black">
      <ShieldAlert className="h-4 w-4 flex-none" />
      <span>Read-only mirror of production — changes here are refused. {status.message}</span>
      {status.productionUrl && (
        <a className="ml-auto underline" href={status.productionUrl} target="_blank" rel="noreferrer">
          Open production
        </a>
      )}
    </div>
  );
}
