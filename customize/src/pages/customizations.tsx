import { Braces, Loader2, Plus, Rocket, Save, Wrench } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import {
  classifyOnboardingError,
  onboardingApi,
  type ClientDescriptor,
  type SimulateResponse,
} from "@/api/onboarding";
import { equipmentApi } from "@/api/equipment";
import { PageHeader } from "@/components/page-header";
import { Button, Card, Input } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import { csadminUrl } from "@/lib/sibling-apps";
import {
  addDeriveRule,
  buildDeriveRule,
  listDeriveRules,
  parseSamples,
  parseVarLines,
  removeDeriveRule,
  ROLE_LABEL,
  type DeriveRole,
} from "@/lib/derive-rules";

type LoadState = "loading" | "ready" | "none" | "error";

/**
 * ADR-0058 Tier-1 customizations editor — the standalone home for authoring
 * declarative `expr` derive rules on an ALREADY-onboarded client (the same
 * op-builder that lives in the onboarding wizard's Review step, but for a live
 * tenant's stored descriptor). Load → add/remove rules → Simulate against sample
 * tags → Save (optionally regenerate to deploy). Tier-2 (arbitrary Node-RED
 * logic) is the embedded editor on the Box Ops page.
 */
export function CustomizationsPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const idEnterprise = enterprise.id_enterprise;

  const [state, setState] = useState<LoadState>("loading");
  const [tenantCode, setTenantCode] = useState<string>("");
  const [descriptor, setDescriptor] = useState<ClientDescriptor | null>(null);
  const [dirty, setDirty] = useState(false);

  // id_equipment → display name (cd_equipment), for a friendlier picker/list.
  const [nameById, setNameById] = useState<Map<number, string>>(new Map());

  // op-builder inputs
  const [deriveTarget, setDeriveTarget] = useState<number | "">("");
  const [deriveRole, setDeriveRole] = useState<DeriveRole>("scrap");
  const [deriveExpr, setDeriveExpr] = useState("");
  const [deriveVarsText, setDeriveVarsText] = useState("");

  // simulate
  const [samplesText, setSamplesText] = useState("");
  const [simBusy, setSimBusy] = useState(false);
  const [simResult, setSimResult] = useState<SimulateResponse | null>(null);

  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setState("loading");
    setDirty(false);
    setSimResult(null);
    try {
      const [row, eq] = await Promise.all([
        onboardingApi.getDescriptor(),
        equipmentApi.list({ idEnterprise }).catch(() => []),
      ]);
      const m = new Map<number, string>();
      for (const e of eq as Array<{ id_equipment: number; cd_equipment?: string }>)
        m.set(e.id_equipment, e.cd_equipment ?? "");
      setNameById(m);
      setTenantCode(row.tenant_code);
      setDescriptor(row.descriptor ?? {});
      setState("ready");
    } catch (err) {
      // A fresh tenant (not-found) or a dark onboarding feature (disabled) simply
      // has no descriptor to edit — that is a "nothing to customize yet" state,
      // not an error. Only a real failure ("other") is an error.
      const kind = classifyOnboardingError(err);
      if (kind === "not-found" || kind === "disabled") {
        setState("none");
        return;
      }
      setState("error");
    }
  }, [idEnterprise]);

  useEffect(() => {
    void load();
  }, [load]);

  // topic per equipment, straight off the stored descriptor (guaranteed present
  // for mapped equipment — the set customizations attach to).
  const topicById = useMemo(() => {
    const m = new Map<number, string>();
    for (const e of descriptor?.equipment ?? [])
      if (e.id_equipment != null) m.set(e.id_equipment, e.topic ?? "");
    return m;
  }, [descriptor]);

  const pickable = useMemo(
    () =>
      (descriptor?.equipment ?? [])
        .filter((e) => e.id_equipment != null)
        .map((e) => ({
          id: e.id_equipment!,
          topic: e.topic ?? "",
          tp: e.tp_equipment,
          name: nameById.get(e.id_equipment!) ?? "",
        })),
    [descriptor, nameById],
  );

  const rules = useMemo(
    () => (descriptor ? listDeriveRules(descriptor, (id) => topicById.get(id)) : []),
    [descriptor, topicById],
  );

  function onAddRule() {
    if (!descriptor) return;
    if (deriveTarget === "") {
      toast.error("Pick an equipment for the rule.");
      return;
    }
    if (deriveExpr.trim() === "") {
      toast.error("Enter an expression (e.g. gross - net).");
      return;
    }
    const vars = parseVarLines(deriveVarsText);
    if ("error" in vars) {
      toast.error(`Fix the variables: ${vars.error}`);
      return;
    }
    if (Object.keys(vars).length === 0) {
      toast.error("Add at least one variable (name = /suffix).");
      return;
    }
    const id = deriveTarget;
    const rule = buildDeriveRule(deriveRole, deriveExpr.trim(), vars);
    const tp = pickable.find((p) => p.id === id)?.tp;
    setDescriptor((prev) =>
      prev ? addDeriveRule(prev, id, topicById.get(id) ?? "", tp, rule) : prev,
    );
    setDeriveExpr("");
    setDeriveVarsText("");
    setDirty(true);
    toast.success("Rule added — Simulate to preview, then Save to persist.");
  }

  function onRemoveRule(id: number, idx: number) {
    setDescriptor((prev) => (prev ? removeDeriveRule(prev, id, idx) : prev));
    setDirty(true);
  }

  async function runSimulation() {
    if (!descriptor) return;
    const samples = parseSamples(samplesText);
    if ("error" in samples) {
      toast.error(`Fix the samples JSON: ${samples.error}`);
      return;
    }
    setSimBusy(true);
    try {
      const res = await onboardingApi.simulate(descriptor, samples);
      setSimResult(res);
      toast.success(
        `Simulated ${res.derived_rules.length} rule(s) → ${res.emitted.length} tag(s)`,
      );
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Simulation failed");
    } finally {
      setSimBusy(false);
    }
  }

  async function save(regenerate: boolean) {
    if (!descriptor) return;
    setSaving(true);
    try {
      await onboardingApi.upsertDescriptor(tenantCode, descriptor);
      if (regenerate) {
        await onboardingApi.generate();
        toast.success("Saved + regenerated — the new config will deploy to the box.");
      } else {
        toast.success("Customizations saved to the descriptor.");
      }
      setDirty(false);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title="Customizations"
        subtitle={`Author declarative derive rules (Tier 1) for ${enterprise.name}. For arbitrary Node-RED logic (Tier 2), use the embedded editor on Box Ops.`}
      />

      {state === "loading" ? (
        <Card className="p-6 text-[13px] text-muted-foreground">
          <Loader2 className="mr-2 inline h-4 w-4 animate-spin" />
          Loading this tenant's descriptor…
        </Card>
      ) : state === "error" ? (
        <Card className="p-6">
          <p className="text-[13px] text-muted-foreground">
            Could not load the descriptor.{" "}
            <button className="text-primary hover:underline" onClick={() => void load()}>
              Retry
            </button>
          </p>
        </Card>
      ) : state === "none" ? (
        <Card className="p-6">
          <p className="text-[13px] text-muted-foreground">
            This tenant has no descriptor yet — there is nothing to customize until
            it is onboarded in{" "}
            <a className="text-primary hover:underline" href={csadminUrl("/app/onboarding", enterprise.id_enterprise)} target="_blank" rel="noreferrer">
              CS Admin ↗
            </a>
            , where you can author derive rules inline during Review. Once onboarded,
            they show up here for editing.
          </p>
        </Card>
      ) : (
        <>
          {/* ── existing rules + op-builder ── */}
          <Card className="mb-5 px-7 py-6">
            <div className="mb-2 flex items-center gap-2">
              <Braces className="h-4 w-4 text-muted-foreground" />
              <span className="text-[15px] font-extrabold text-foreground">Derive rules</span>
            </div>
            <p className="mb-3 text-[13px] text-muted-foreground">
              Author a declarative transform — <code className="font-mono">scrap = gross - net</code>,
              merge two PLCs, a unit conversion — on an equipment, without hand-editing JSON.
              The result is a canonical count the agent synthesizes; preview it in Simulate below.
            </p>

            {rules.length > 0 ? (
              <ul className="mb-4 space-y-1 text-[12px]">
                {rules.map((r) => (
                  <li key={`${r.id}:${r.idx}`} className="flex items-center gap-2 font-mono">
                    <span className="text-muted-foreground">
                      {nameById.get(r.id) || r.topic || `#${r.id}`}
                    </span>
                    <span className="text-foreground">
                      {r.rule.emit[0]}
                      {r.rule.expr ? ` = ${r.rule.expr.expr}` : ""}
                    </span>
                    <button
                      type="button"
                      className="text-destructive hover:underline"
                      onClick={() => onRemoveRule(r.id, r.idx)}
                    >
                      remove
                    </button>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="mb-4 text-[12px] text-muted-foreground">
                No derive rules authored yet.
              </p>
            )}

            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-[13px]">
                <span className="mb-1 block font-semibold text-foreground">Equipment</span>
                <select
                  className="w-full rounded-md border border-border bg-background p-2 text-[13px]"
                  value={deriveTarget}
                  onChange={(e) =>
                    setDeriveTarget(e.target.value === "" ? "" : Number(e.target.value))
                  }
                >
                  <option value="">Select…</option>
                  {pickable.map((e) => (
                    <option key={e.id} value={e.id}>
                      {e.name ? `${e.name} — ` : ""}
                      {e.topic || `#${e.id}`}
                    </option>
                  ))}
                </select>
              </label>
              <label className="text-[13px]">
                <span className="mb-1 block font-semibold text-foreground">Emits (role)</span>
                <select
                  className="w-full rounded-md border border-border bg-background p-2 text-[13px]"
                  value={deriveRole}
                  onChange={(e) => setDeriveRole(e.target.value as DeriveRole)}
                >
                  {(Object.keys(ROLE_LABEL) as DeriveRole[]).map((role) => (
                    <option key={role} value={role}>
                      {ROLE_LABEL[role]}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <label className="mt-3 block text-[13px]">
              <span className="mb-1 block font-semibold text-foreground">Expression</span>
              <Input
                placeholder="gross - net"
                value={deriveExpr}
                onChange={(e) => setDeriveExpr(e.target.value)}
              />
            </label>
            <label className="mt-3 block text-[13px]">
              <span className="mb-1 block font-semibold text-foreground">
                Variables — one <code className="font-mono">name = /arriving/suffix</code> per line
              </span>
              <textarea
                className="h-24 w-full rounded-md border border-border bg-background p-3 font-mono text-[12px]"
                spellCheck={false}
                placeholder={`gross = /LINHAS/L01/S1INFEED/Admin/ProdProcessedCount/101/Unit\nnet = /LINHAS/L01/S6OUTPUT/Admin/ProdProcessedCount/106/Unit`}
                value={deriveVarsText}
                onChange={(e) => setDeriveVarsText(e.target.value)}
              />
            </label>
            <div className="mt-3">
              <Button variant="ghost" onClick={onAddRule}>
                <Plus className="mr-2 h-4 w-4" />
                Add rule
              </Button>
            </div>
          </Card>

          {/* ── simulate ── */}
          <Card className="mb-5 px-7 py-6">
            <div className="mb-2 flex items-center gap-2">
              <Wrench className="h-4 w-4 text-muted-foreground" />
              <span className="text-[15px] font-extrabold text-foreground">
                Simulate customizations
              </span>
            </div>
            <p className="mb-3 text-[13px] text-muted-foreground">
              Feed sample tags to this plant's derive/expr rules and preview the tags
              they would produce — no live box needed. One JSON array of{" "}
              <code className="font-mono">{`{ "metric", "value", "ts_millis?" }`}</code>.
            </p>
            <textarea
              className="mb-3 h-32 w-full rounded-md border border-border bg-background p-3 font-mono text-[12px]"
              spellCheck={false}
              placeholder={`[\n  { "metric": "/LINHAS/L01/S1INFEED/Admin/ProdProcessedCount/101/Unit", "value": 500 },\n  { "metric": "/LINHAS/L01/S6OUTPUT/Admin/ProdProcessedCount/106/Unit", "value": 470 }\n]`}
              value={samplesText}
              onChange={(e) => setSamplesText(e.target.value)}
            />
            <div className="flex items-center gap-3">
              <Button variant="ghost" onClick={runSimulation} disabled={simBusy}>
                {simBusy ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
                {simBusy ? "Simulating…" : "Run simulation"}
              </Button>
              {simResult ? (
                <span className="text-[13px] text-muted-foreground">
                  {simResult.derived_rules.length} rule(s) · {simResult.emitted.length} tag(s) produced
                </span>
              ) : null}
            </div>
            {simResult ? (
              <div className="mt-4 space-y-4">
                {simResult.derived_rules.length > 0 ? (
                  <div>
                    <p className="mb-1 text-[13px] font-extrabold text-foreground">Active rules</p>
                    <ul className="space-y-1 text-[12px]">
                      {simResult.derived_rules.map((r, i) => (
                        <li key={i} className="font-mono text-muted-foreground">
                          [{r.kind}] {r.emit.join(", ")}
                          {r.expr ? <span className="text-foreground"> = {r.expr}</span> : null}
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : (
                  <p className="text-[13px] text-muted-foreground">
                    No derive/expr rules on this descriptor — nothing to simulate.
                  </p>
                )}
                <div>
                  <p className="mb-1 text-[13px] font-extrabold text-foreground">Produced tags</p>
                  {simResult.emitted.length > 0 ? (
                    <ul className="space-y-1 text-[12px]">
                      {simResult.emitted.map((e, i) => (
                        <li key={i} className="font-mono">
                          <span className="text-foreground">{e.metric}</span>
                          <span className="text-muted-foreground"> = {String(e.value)}</span>
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="text-[13px] text-muted-foreground">
                      No tags produced — an expr may still be waiting for all its inputs
                      (feed every referenced tag at least once).
                    </p>
                  )}
                </div>
              </div>
            ) : null}
          </Card>

          {/* ── save ── */}
          <div className="mb-8 flex items-center gap-3">
            <Button onClick={() => void save(false)} disabled={saving || !dirty}>
              {saving ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Save className="mr-2 h-4 w-4" />}
              Save
            </Button>
            <Button variant="ghost" onClick={() => void save(true)} disabled={saving || !dirty}>
              <Rocket className="mr-2 h-4 w-4" />
              Save &amp; regenerate
            </Button>
            <span className="text-[12px] text-muted-foreground">
              {dirty ? "Unsaved changes." : "All changes saved."} Regenerate rebuilds
              the bundle so the rules deploy to the box.
            </span>
          </div>
        </>
      )}
    </div>
  );
}
