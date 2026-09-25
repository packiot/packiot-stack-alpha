import { useCallback, useEffect, useState } from "react";
import { Workflow } from "lucide-react";
import { toast } from "sonner";
import { onboardingApi, type ClientDescriptorRow } from "@/api/onboarding";
import { edgeSsmApi, type EdgeConnect } from "@/api/edge-ssm";
import { BoxWebUi } from "@/components/edge/box-webui";
import { PageHeader } from "@/components/page-header";
import { Button, Card } from "@/components/ui";
import { csadminUrl } from "@/lib/sibling-apps";
import { parseCustomizations } from "@/lib/node-red-customizations";
import { useEnterpriseStore } from "@/stores/enterprise-store";

/**
 * Node-RED flows — ADR-0058 Tier-2 customization. Two surfaces, both here (CS
 * Admin no longer authors customizations):
 *
 *  1. Descriptor flows — the per-client Node-RED nodes stored on the descriptor
 *     (`customizations`, ADR-0045 §G3) and rendered onto the generated reader
 *     flow's customizations tab. Versioned with the descriptor; this is the
 *     durable way to customize. Moved here from CS Admin's onboarding Review.
 *  2. Live editor — the box's own Node-RED UI through the platform (ADR-0057),
 *     for boxes that run Node-RED. The box itself (deploy/restart/logs) is CS
 *     Admin's Box Ops.
 */
export function NodeRedPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const id = enterprise.id_enterprise;
  const [row, setRow] = useState<ClientDescriptorRow | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "none" | "error">("loading");
  const [text, setText] = useState("");
  const [saving, setSaving] = useState(false);
  const [connect, setConnect] = useState<EdgeConnect | null | "unavailable">(null);

  const load = useCallback(async () => {
    setState("loading");
    try {
      const r = await onboardingApi.getDescriptor();
      setRow(r);
      const nodes = r.descriptor?.customizations ?? [];
      setText(nodes.length ? JSON.stringify(nodes, null, 2) : "");
      setState("ready");
    } catch (e) {
      const status = (e as { response?: { status?: number } })?.response?.status;
      setState(status === 404 ? "none" : "error");
    }
  }, []);

  useEffect(() => {
    void load();
    edgeSsmApi.connect(id).then(setConnect).catch(() => setConnect("unavailable"));
  }, [load, id]);

  async function save() {
    const parsed = parseCustomizations(text);
    if ("error" in parsed) {
      toast.error(`Fix the Node-RED JSON: ${parsed.error}`);
      return;
    }
    setSaving(true);
    try {
      // Re-read and replace ONLY `customizations`, so a concurrent onboarding or
      // hub edit to any other part of the descriptor is never overwritten.
      const latest = await onboardingApi.getDescriptor();
      const next = { ...latest.descriptor };
      if (parsed.nodes.length) next.customizations = parsed.nodes;
      else delete next.customizations;
      await onboardingApi.upsertDescriptor(latest.tenant_code, next);
      toast.success(`Saved ${parsed.nodes.length} Node-RED node(s) — they ship with the next generate/deploy`);
      await load();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not save");
    } finally {
      setSaving(false);
    }
  }

  const isNodeRedBox = connect && connect !== "unavailable" && (connect.webUiPort ?? 1880) === 1880;

  return (
    <>
      <PageHeader title="Node-RED flows" subtitle={`Per-client Node-RED logic for ${enterprise.name} (ADR-0058 Tier 2).`} />

      <Card className="mb-5 px-7 py-6">
        <div className="mb-1 flex items-center gap-2">
          <Workflow className="h-4 w-4 text-primary" />
          <span className="text-[15px] font-extrabold text-foreground">Descriptor flows</span>
        </div>
        <p className="mb-3 max-w-[680px] text-[13px] text-muted-foreground">
          A Node-RED export (JSON array of nodes) rendered onto the generated reader flow&apos;s{" "}
          <span className="font-mono">customizations</span> tab — versioned with the descriptor and shipped on the
          next generate/deploy (Box Ops in CS Admin). Leave empty for none.
        </p>
        {state === "loading" && <p className="text-sm text-muted-foreground">Loading…</p>}
        {state === "error" && <p className="text-sm text-danger">Couldn&apos;t load the descriptor.</p>}
        {state === "none" && (
          <p className="text-sm text-muted-foreground">
            {enterprise.name} has no descriptor yet — onboard it first in{" "}
            <a className="text-primary hover:underline" href={csadminUrl("/app/onboarding", id)} target="_blank" rel="noreferrer">
              CS Admin ↗
            </a>
            .
          </p>
        )}
        {state === "ready" && row && (
          <>
            <textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              spellCheck={false}
              placeholder={'[\n  { "id": "my-integration", "type": "function", "z": "customizations", "name": "example", "func": "return msg;" }\n]'}
              className="h-[260px] w-full rounded-md border border-border bg-chrome p-3 font-mono text-[12px] leading-[1.55] text-chrome-foreground outline-none focus:border-primary"
            />
            <div className="mt-3 flex justify-end">
              <Button onClick={() => void save()} disabled={saving}>
                {saving ? "Saving…" : "Save flows"}
              </Button>
            </div>
          </>
        )}
      </Card>

      <Card className="px-7 py-6">
        <p className="mb-1 text-[15px] font-extrabold text-foreground">Live editor on the box</p>
        {connect === null && <p className="text-sm text-muted-foreground">Checking the box…</p>}
        {connect === "unavailable" && (
          <p className="text-sm text-muted-foreground">
            No reachable box for {enterprise.name}. Box enrollment and health are in{" "}
            <a className="text-primary hover:underline" href={csadminUrl("/app/box", id)} target="_blank" rel="noreferrer">
              CS Admin → Box Ops ↗
            </a>
            .
          </p>
        )}
        {connect && connect !== "unavailable" && !isNodeRedBox && (
          <p className="text-sm text-muted-foreground">
            This box runs the {connect.webUiLabel ?? "edge dashboard"} (no Node-RED editor). Use the descriptor flows above.
          </p>
        )}
        {isNodeRedBox && <BoxWebUi idEnterprise={id} />}
      </Card>
    </>
  );
}
