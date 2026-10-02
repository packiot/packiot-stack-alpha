import { useCallback, useEffect, useState } from "react";
import { Cable, ExternalLink } from "lucide-react";
import { edgeSsmApi, type EdgeStatus } from "@/api/edge-ssm";
import { plcStatusApi, type PlcStatus } from "@/api/plc-status";
import { PageHeader } from "@/components/page-header";
import { Button, Card } from "@/components/ui";
import { csadminUrl } from "@/lib/sibling-apps";
import { lastSeenLabel } from "@/lib/plc-status-label";
import { useEnterpriseStore } from "@/stores/enterprise-store";

const DOT: Record<string, string> = { online: "#27ae60", stale: "#e6a817", offline: "#9198a4" };

/**
 * PLC connections — READ-ONLY. The client's PLC connection (the box, its tag
 * maps, the PackML register) is set up and operated in CS Admin; customizations
 * are built ON TOP of it here (derive rules read these PLCs' tags, Node-RED flows
 * run on this box). This page shows that connection's live state for the tenant
 * being customized and links every change to the CS Admin page that owns it — on
 * the same tenant (?idEnterprise), so the two apps never talk about different
 * clients.
 */
export function PlcConnectionsPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const id = enterprise.id_enterprise;
  const [box, setBox] = useState<EdgeStatus | null | "unavailable">(null);
  const [plcs, setPlcs] = useState<PlcStatus[] | null>(null);
  const [plcErr, setPlcErr] = useState(false);

  const load = useCallback(() => {
    setPlcErr(false);
    edgeSsmApi.status(id).then(setBox).catch(() => setBox("unavailable"));
    plcStatusApi.list(id).then(setPlcs).catch(() => setPlcErr(true));
  }, [id]);

  useEffect(() => {
    load();
    const t = window.setInterval(load, 30_000);
    return () => window.clearInterval(t);
  }, [load]);

  const link = (path: string, label: string) => (
    <a className="inline-flex items-center gap-1 text-[13px] font-semibold text-primary hover:underline" href={csadminUrl(path, id)} target="_blank" rel="noreferrer">
      {label} <ExternalLink className="h-3 w-3" />
    </a>
  );
  const online = plcs?.filter((p) => p.liveness === "online").length ?? 0;

  return (
    <>
      <PageHeader title="PLC connections" subtitle={`The PLC connection your customizations build on — live, read-only. ${enterprise.name}'s connection is managed in CS Admin.`} />

      <Card className="mb-5 px-7 py-6">
        <div className="mb-3 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <Cable className="h-4 w-4 text-primary" />
            <span className="text-[15px] font-extrabold text-foreground">Edge box</span>
          </div>
          {link("/app/box", "Box Ops in CS Admin")}
        </div>
        {box === null && <p className="text-sm text-muted-foreground">Checking…</p>}
        {box === "unavailable" && <p className="text-sm text-muted-foreground">Box status unavailable for {enterprise.name}.</p>}
        {box && box !== "unavailable" && (
          <p className="text-sm text-foreground">
            {box.registered ? (
              <>
                <span className="font-semibold">{box.pingStatus ?? "unknown"}</span>
                <span className="text-muted-foreground">
                  {" "}· {box.instanceId}
                  {box.lastPingDateTime ? ` · last ping ${new Date(box.lastPingDateTime).toLocaleString()}` : ""}
                </span>
              </>
            ) : (
              <span className="text-muted-foreground">No box enrolled yet.</span>
            )}
          </p>
        )}
      </Card>

      <Card className="overflow-hidden">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-7 py-4">
          <span className="text-[15px] font-extrabold text-foreground">
            PLCs{plcs ? ` · ${online}/${plcs.length} online` : ""}
          </span>
          <div className="flex flex-wrap items-center gap-4">
            {link("/app/plc-status", "PLC status")}
            {link("/app/sensors", "Sensor config")}
            {link("/app/packml-register", "PackML register")}
            <Button variant="ghost" size="sm" onClick={load}>Refresh</Button>
          </div>
        </div>
        {plcErr && <p className="px-7 py-4 text-sm text-danger">Couldn&apos;t load PLC status.</p>}
        {!plcErr && plcs === null && <p className="px-7 py-4 text-sm text-muted-foreground">Loading…</p>}
        {plcs?.length === 0 && <p className="px-7 py-4 text-sm text-muted-foreground">No PLCs configured yet.</p>}
        {plcs?.map((p) => (
          <div key={p.id_equipment} className="grid grid-cols-[18px_minmax(0,1fr)_120px_140px] items-center gap-3 border-b border-border px-7 py-2.5 last:border-0">
            <span className="h-2.5 w-2.5 rounded-full" style={{ background: DOT[p.liveness ?? "offline"] }} />
            <span className="min-w-0 truncate text-[13.5px] font-semibold text-foreground">
              {p.nm_equipment} <span className="font-normal text-muted-foreground">· {p.nm_area ?? ""}</span>
            </span>
            <span className="text-[12.5px] text-muted-foreground">{p.status ?? "—"}</span>
            <span className="text-[12px]" style={{ color: DOT[p.liveness ?? "offline"] }}>{lastSeenLabel(p)}</span>
          </div>
        ))}
      </Card>
    </>
  );
}
