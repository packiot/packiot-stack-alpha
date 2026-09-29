import { useCallback, useEffect, useMemo, useState } from "react";
import { Loader2, Save, TriangleAlert } from "lucide-react";
import { toast } from "sonner";
import { classifyOnboardingError, isStaleSave, onboardingApi } from "@/api/onboarding";
import { edgeSsmApi, type EdgeConnect } from "@/api/edge-ssm";
import { BoxWebUi } from "@/components/edge/box-webui";
import { BoxApply } from "@/components/node-red/box-apply";
import { CustomizationList } from "@/components/node-red/customization-list";
import { FlowInserter } from "@/components/node-red/flow-inserter";
import { PageHeader } from "@/components/page-header";
import { Button, Card } from "@/components/ui";
import { csadminUrl } from "@/lib/sibling-apps";
import { stableNodesJson } from "@/lib/node-red-customizations";
import type { Node } from "@/lib/node-red-import";
import { tenantPrefix } from "@/lib/node-red-spots";
import { useEnterpriseStore } from "@/stores/enterprise-store";

/**
 * Node-RED flows — ADR-0058 Tier 2 customization, end to end:
 *
 *  1. Insert — paste any Node-RED export, analyze + lint it, optionally re-id it
 *     and wire it to a reader SPOT (a named attach point on the generated PLC
 *     reader: raw reads, normalized tags, agent response/errors, or publish).
 *  2. Descriptor — the customizations stored on the tenant descriptor (the
 *     versioned source of truth), grouped by tab; Save is field-scoped + CAS.
 *  3. Apply — preview/apply the SAVED set onto the running box's Node-RED via its
 *     Admin API (the box seeds flows on first boot only, so this is how a later
 *     change lands). Box enrollment/restart/logs stay in CS Admin's Box Ops.
 *  4. Live editor — the box's own Node-RED UI through the platform (ADR-0057).
 */
export function NodeRedPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const id = enterprise.id_enterprise;
  const [state, setState] = useState<"loading" | "ready" | "none" | "error">("loading");
  const [version, setVersion] = useState(0);
  const [tenant, setTenant] = useState<string | undefined>();
  const [hasPlc, setHasPlc] = useState(false);
  const [saved, setSaved] = useState<Node[]>([]);
  const [nodes, setNodes] = useState<Node[]>([]);
  const [saving, setSaving] = useState(false);
  const [connect, setConnect] = useState<EdgeConnect | null | "unavailable">(null);

  const load = useCallback(async () => {
    setState("loading");
    try {
      const r = await onboardingApi.getDescriptor();
      const list = (r.descriptor?.customizations ?? []) as Node[];
      setVersion(r.version);
      setTenant(r.descriptor?.tenant);
      setHasPlc(!!r.descriptor?.plc);
      setSaved(list);
      setNodes(list);
      setState("ready");
    } catch (e) {
      const kind = classifyOnboardingError(e);
      setState(kind === "not-found" || kind === "disabled" ? "none" : "error");
    }
  }, []);

  useEffect(() => {
    void load();
    let alive = true;
    edgeSsmApi
      .connect(id)
      .then((c) => alive && setConnect(c))
      .catch(() => alive && setConnect("unavailable"));
    return () => {
      alive = false;
    };
  }, [load, id]);

  const prefix = tenantPrefix(tenant);
  const dirty = useMemo(() => stableNodesJson(nodes) !== stableNodesJson(saved), [nodes, saved]);

  async function save() {
    setSaving(true);
    try {
      const row = await onboardingApi.updateCustomizations(version, { customizations: nodes.length ? nodes : null });
      const list = (row.descriptor?.customizations ?? []) as Node[];
      setVersion(row.version);
      setSaved(list);
      setNodes(list);
      toast.success(`Saved ${list.length} node(s) to the descriptor (v${row.version}). Preview + apply to push them to the box.`);
    } catch (e) {
      toast.error(
        isStaleSave(e)
          ? "Someone saved this descriptor after you loaded it — reload (your unsaved nodes are lost on reload; copy them via Edit JSON first)."
          : e instanceof Error
            ? e.message
            : "Could not save",
      );
    } finally {
      setSaving(false);
    }
  }

  const isNodeRedBox = connect && connect !== "unavailable" && (connect.webUiPort ?? 1880) === 1880;

  if (state !== "ready") {
    return (
      <>
        <PageHeader title="Node-RED flows" subtitle={`Per-client Node-RED logic for ${enterprise.name}.`} />
        <Card className="px-7 py-6 text-sm text-muted-foreground">
          {state === "loading" && (
            <>
              <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> Loading the descriptor…
            </>
          )}
          {state === "error" && (
            <span className="text-danger">
              Couldn&apos;t load the descriptor.{" "}
              <button className="underline" onClick={() => void load()}>
                Retry
              </button>
            </span>
          )}
          {state === "none" && (
            <>
              {enterprise.name} has no descriptor yet — onboard it first in{" "}
              <a className="text-primary hover:underline" href={csadminUrl("/app/onboarding", id)} target="_blank" rel="noreferrer">
                CS Admin ↗
              </a>
              .
            </>
          )}
        </Card>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title="Node-RED flows"
        subtitle={`Paste, wire and ship per-client Node-RED logic for ${enterprise.name} (ADR-0058 Tier 2).`}
      />

      {!hasPlc && (
        <Card className="mb-5 flex gap-2 border-warning-border bg-warning-tint px-5 py-3 text-[13px] text-warning-strong">
          <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" />
          This descriptor has no <span className="font-mono">plc</span> block, so no Node-RED reader flow is generated
          for it — customizations are stored but have nowhere to render until the PLC connection is onboarded.
        </Card>
      )}

      <FlowInserter prefix={prefix} existing={nodes} onInsert={(added) => setNodes((cur) => [...cur, ...added])} />

      <CustomizationList prefix={prefix} nodes={nodes} onChange={setNodes} />

      <div className="mb-6 flex items-center gap-3">
        <Button onClick={() => void save()} disabled={saving || !dirty}>
          {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
          Save to descriptor
        </Button>
        <span className="text-[12px] text-muted-foreground">
          {dirty ? "Unsaved changes." : `Saved · descriptor v${version}.`} Saving validates the flow through the generator
          and never changes the onboarding status.
        </span>
      </div>

      {isNodeRedBox ? (
        <BoxApply
          idEnterprise={id}
          dirty={dirty}
          onAdopt={(found) =>
            setNodes((cur) => {
              const have = new Set(cur.map((n) => n.id));
              return [...cur, ...found.filter((n) => !have.has(n.id))];
            })
          }
        />
      ) : null}

      <Card className="px-7 py-6">
        <p className="mb-1 text-[15px] font-extrabold text-foreground">Live editor on the box</p>
        {connect === null && <p className="text-sm text-muted-foreground">Checking the box…</p>}
        {connect === "unavailable" && (
          <p className="text-sm text-muted-foreground">
            No reachable box for {enterprise.name}, so there is nothing to apply to live. Box enrollment and health are in{" "}
            <a className="text-primary hover:underline" href={csadminUrl("/app/box", id)} target="_blank" rel="noreferrer">
              CS Admin → Box Ops ↗
            </a>
            .
          </p>
        )}
        {connect && connect !== "unavailable" && !isNodeRedBox && (
          <p className="text-sm text-muted-foreground">
            This box runs the {connect.webUiLabel ?? "edge dashboard"}, not Node-RED — customizations are stored on the
            descriptor but there is no live Node-RED to apply them to.
          </p>
        )}
        {isNodeRedBox && (
          <>
            <p className="mb-2 text-[12px] text-muted-foreground">
              Edits made here are NOT in the descriptor — the next preview lists them so you can adopt them.
            </p>
            <BoxWebUi idEnterprise={id} />
          </>
        )}
      </Card>
    </>
  );
}
