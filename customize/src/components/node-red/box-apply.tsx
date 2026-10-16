import { useState } from "react";
import { isAxiosError } from "axios";
import { Loader2, Rocket, ScanSearch, TriangleAlert } from "lucide-react";
import { toast } from "sonner";
import {
  edgeSsmApi,
  type NodeRedApplyResult,
  type NodeRedApplyScope,
  type NodeRedChange,
  type NodeRedPlan,
} from "@/api/edge-ssm";
import { Button, Card, Select } from "@/components/ui";
import type { Node } from "@/lib/node-red-import";

interface Props {
  idEnterprise: number;
  /** Unsaved edits exist — apply only ever ships the SAVED descriptor. */
  dirty: boolean;
  /** Adopt nodes found on the box (hand-added) into the working customizations. */
  onAdopt: (nodes: Node[]) => void;
}

function errorText(e: unknown): string {
  if (isAxiosError(e)) {
    const d = e.response?.data as { message?: unknown; blockers?: string[] } | undefined;
    if (d?.blockers?.length) return d.blockers.join(" ");
    if (typeof d?.message === "string") return d.message;
    if (d?.message && typeof d.message === "object") {
      const m = d.message as { message?: string; blockers?: string[] };
      return m.blockers?.join(" ") ?? m.message ?? e.message;
    }
  }
  return e instanceof Error ? e.message : "Request failed";
}

function Changes({ title, items, tone }: { title: string; items: NodeRedChange[]; tone: string }) {
  if (!items.length) return null;
  return (
    <div>
      <p className={`mb-1 text-[12px] font-bold ${tone}`}>
        {title} · {items.length}
      </p>
      <ul className="max-h-40 overflow-auto font-mono text-[11px] text-muted-foreground">
        {items.map((c) => (
          <li key={c.id}>
            {c.type} {c.name ? `"${c.name}" ` : ""}
            <span className="opacity-70">{c.id}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

/**
 * Plan → Apply the SAVED customizations onto the running box's Node-RED (the
 * box seeds its flows on first boot only, so this is how a later change lands).
 * The plan is a dry run; apply echoes its `rev` + descriptor version so a
 * concurrent deploy or save is a 409, never a silent overwrite.
 */
export function BoxApply({ idEnterprise, dirty, onAdopt }: Props) {
  const [scope, setScope] = useState<NodeRedApplyScope>("customizations");
  const [plan, setPlan] = useState<NodeRedPlan | null>(null);
  const [result, setResult] = useState<NodeRedApplyResult | null>(null);
  const [busy, setBusy] = useState<"plan" | "apply" | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function runPlan() {
    setBusy("plan");
    setErr(null);
    setResult(null);
    try {
      setPlan(await edgeSsmApi.nodeRedPlan(idEnterprise, scope));
    } catch (e) {
      setPlan(null);
      setErr(errorText(e));
    } finally {
      setBusy(null);
    }
  }

  async function runApply() {
    if (!plan) return;
    setBusy("apply");
    setErr(null);
    try {
      const r = await edgeSsmApi.nodeRedApply(idEnterprise, plan);
      setResult(r);
      setPlan(null);
      toast.success(
        r.mock ? "Sandbox twin — apply simulated, nothing deployed." : r.applied ? "Applied to the box." : "Nothing to change on the box.",
      );
    } catch (e) {
      setErr(errorText(e));
    } finally {
      setBusy(null);
    }
  }

  const empty = plan && !plan.add.length && !plan.update.length && !plan.remove.length;

  return (
    <Card className="mb-5 px-7 py-6">
      <div className="mb-1 flex items-center gap-2">
        <Rocket className="h-4 w-4 text-primary" />
        <span className="text-[15px] font-extrabold text-foreground">Apply to the running box</span>
      </div>
      <p className="mb-3 max-w-[720px] text-[13px] text-muted-foreground">
        The box loads its flows from the descriptor only on first boot. This pushes the saved customizations
        into its live Node-RED — preview first; only changed nodes restart.
      </p>
      <div className="flex flex-wrap items-center gap-3">
        <Select
          className="w-auto min-w-[300px]"
          value={scope}
          onChange={(e) => {
            setScope(e.target.value as NodeRedApplyScope);
            setPlan(null);
          }}
        >
          <option value="customizations">Customizations only (reader untouched)</option>
          <option value="full">Customizations + refresh the generated reader tab</option>
        </Select>
        <Button variant="ghost" onClick={() => void runPlan()} disabled={busy != null || dirty}>
          {busy === "plan" ? <Loader2 className="h-4 w-4 animate-spin" /> : <ScanSearch className="h-4 w-4" />}
          Preview changes
        </Button>
        {dirty && <span className="text-[12px] text-warning-strong">Save first — only saved customizations are applied.</span>}
      </div>

      {err && (
        <p className="mt-3 flex gap-1.5 text-[13px] text-danger">
          <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" /> {err}
        </p>
      )}

      {plan && (
        <div className="mt-4 space-y-3">
          <p className="text-[12px] text-muted-foreground">
            Planned against descriptor v{plan.descriptorVersion} · box rev <span className="font-mono">{plan.rev.slice(0, 8)}</span> ·{" "}
            {plan.unchanged} node(s) already match.
          </p>
          {plan.blockers.map((b, i) => (
            <p key={i} className="flex gap-1.5 rounded-md border border-danger-border bg-danger-tint px-3 py-2 text-[12px] text-danger">
              <TriangleAlert className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {b}
            </p>
          ))}
          {plan.notInDescriptor.length > 0 && (
            <div className="rounded-md border border-warning-border bg-warning-tint px-3 py-2 text-[12px] text-warning-strong">
              {plan.notInDescriptor.length} node(s) on the box are not in the saved descriptor (added in the box editor, or
              removed from the descriptor) and would be deleted.{" "}
              <button
                type="button"
                className="font-bold underline"
                onClick={() => {
                  onAdopt(plan.notInDescriptor as Node[]);
                  setPlan(null);
                  toast.success("Adopted into the customizations — Save, then preview again.");
                }}
              >
                Keep them: adopt into the descriptor
              </button>
            </div>
          )}
          <div className="grid gap-3 sm:grid-cols-3">
            <Changes title="Add" items={plan.add} tone="text-success" />
            <Changes title="Update" items={plan.update} tone="text-primary" />
            <Changes title="Remove" items={plan.remove} tone="text-danger" />
          </div>
          {empty ? (
            <p className="text-[13px] text-muted-foreground">The box already matches the descriptor.</p>
          ) : (
            <Button onClick={() => void runApply()} disabled={busy != null || plan.blockers.length > 0}>
              {busy === "apply" ? <Loader2 className="h-4 w-4 animate-spin" /> : <Rocket className="h-4 w-4" />}
              Apply to box
            </Button>
          )}
        </div>
      )}

      {result && (
        <p className="mt-3 text-[13px] text-foreground">
          {result.mock
            ? result.mockMessage
            : result.applied
              ? `Deployed: +${result.add.length} / ~${result.update.length} / −${result.remove.length} node(s).`
              : "Nothing to change — the box already matches."}
        </p>
      )}
    </Card>
  );
}
