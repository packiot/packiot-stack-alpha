import { useState } from "react";
import { edgeSsmApi, webUiEmbedUrl } from "@/api/edge-ssm";
import { Button } from "@/components/ui";

/**
 * ADR-0057 Phase 2b — the box web UI (Node-RED / edge-dashboard) embedded in
 * csadmin, gated by the CS-Admin login alone (no local AWS CLI / port-forward).
 *
 * Open → POST /api/edge-ssm/webui → { sessionId, ticket, webUiLabel } → an
 * iframe at /api/edge-ssm/webui/:sessionId/?ticket=…, which edge-api reverse-
 * proxies (via the edge-session-broker's port-forward) to the box, injecting a
 * <base> + a fetch/XHR shim so the UI's absolute paths resolve under the mount.
 */
export function BoxWebUi({ idEnterprise }: { idEnterprise: number }) {
  const [src, setSrc] = useState<string | null>(null);
  const [label, setLabel] = useState<string>("web UI");
  const [status, setStatus] = useState<string>("idle");

  async function open() {
    setStatus("opening…");
    try {
      const r = await edgeSsmApi.openWebUi(idEnterprise);
      setLabel(r.webUiLabel);
      setSrc(webUiEmbedUrl(r.sessionId, r.ticket));
      setStatus("connected");
    } catch {
      setStatus("failed to open");
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[12px] text-muted-foreground">
          {label} · <span className="font-mono">{status}</span>
        </span>
        {src ? (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setSrc(null);
              setStatus("idle");
            }}
          >
            Close view
          </Button>
        ) : (
          <Button variant="ghost" size="sm" onClick={() => void open()}>
            Open {label} view
          </Button>
        )}
      </div>
      {src ? (
        <iframe
          title="box web UI"
          src={src}
          className="h-[520px] w-full rounded-md border border-border bg-white"
        />
      ) : null}
    </div>
  );
}
