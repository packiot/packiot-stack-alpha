import { Calculator, FlaskConical, Info, Loader2, Plus, RefreshCw, Save, Trash2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { classifyOnboardingError, isStaleSave, onboardingApi, type ClientDescriptor } from "@/api/onboarding";
import { edgeSsmApi } from "@/api/edge-ssm";
import { equipmentApi } from "@/api/equipment";
import { PageHeader } from "@/components/page-header";
import { Button, Card, Input, Select } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import { csadminUrl } from "@/lib/sibling-apps";
import { addDeriveRule, listDeriveRules, removeDeriveRule } from "@/lib/derive-rules";
import {
  COUNTERS,
  FORMULA_EXAMPLES,
  RESULTS,
  buildRule,
  checkFormula,
  describeInput,
  describeRule,
  inputPath,
  machinesOf,
  samplesFor,
  type Input as CalcInput,
  type Machine,
} from "@/lib/calc-builder";

type LoadState = "loading" | "ready" | "none" | "error";
const LETTERS = ["a", "b", "c", "d", "e", "f"];

/**
 * Calculations — create a new value from counters the machines already send
 * (e.g. scrap = what went in − good parts, or a line total = machine A + machine
 * B). Written for the automation team: pick from lists, try it with example
 * numbers, save, then apply. Saving is field-scoped + version-checked (see
 * onboardingApi.updateCustomizations); applying restarts the shared data
 * collector, which reads the saved rules at start-up.
 */
export function CustomizationsPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const idEnterprise = enterprise.id_enterprise;

  const [state, setState] = useState<LoadState>("loading");
  const [version, setVersion] = useState(0);
  const [baseline, setBaseline] = useState<ClientDescriptor | null>(null);
  const [descriptor, setDescriptor] = useState<ClientDescriptor | null>(null);
  const [names, setNames] = useState<Map<number, string>>(new Map());
  const [saving, setSaving] = useState(false);
  const [applying, setApplying] = useState(false);

  // builder
  const [targetId, setTargetId] = useState<number | "">("");
  const [result, setResult] = useState(RESULTS[0].leaf);
  const [inputs, setInputs] = useState<CalcInput[]>([]);
  const [formula, setFormula] = useState("");
  const [tryValues, setTryValues] = useState<Record<string, string>>({});
  const [tryOut, setTryOut] = useState<string | null>(null);
  const [trying, setTrying] = useState(false);

  const load = useCallback(async () => {
    setState("loading");
    try {
      const [row, eq] = await Promise.all([
        onboardingApi.getDescriptor(),
        equipmentApi.list({ idEnterprise }).catch(() => []),
      ]);
      const m = new Map<number, string>();
      for (const e of eq as Array<{ id_equipment: number; nm_equipment?: string; cd_equipment?: string }>)
        m.set(e.id_equipment, e.nm_equipment || e.cd_equipment || "");
      setNames(m);
      setVersion(row.version);
      setBaseline(row.descriptor ?? {});
      setDescriptor(row.descriptor ?? {});
      setState("ready");
    } catch (err) {
      const kind = classifyOnboardingError(err);
      setState(kind === "not-found" || kind === "disabled" ? "none" : "error");
    }
  }, [idEnterprise]);

  useEffect(() => {
    void load();
  }, [load]);

  const machines = useMemo(() => (descriptor ? machinesOf(descriptor, names) : []), [descriptor, names]);
  const target = machines.find((m) => m.id === targetId);
  const rules = useMemo(() => (descriptor ? listDeriveRules(descriptor, () => undefined) : []), [descriptor]);
  const dirty = useMemo(
    () => JSON.stringify(baseline?.equipment ?? []) !== JSON.stringify(descriptor?.equipment ?? []),
    [baseline, descriptor],
  );
  const formulaError = inputs.length ? checkFormula(formula, inputs.map((i) => i.letter)) : null;

  function pickTarget(id: number | "") {
    setTargetId(id);
    setInputs(id === "" ? [] : [{ letter: "a", machineId: id, counter: "ProdConsumedCount" }, { letter: "b", machineId: id, counter: "ProdProcessedCount" }]);
    setFormula("a - b");
    setTryValues({ a: "500", b: "470" });
    setTryOut(null);
  }

  function setInput(i: number, patch: Partial<CalcInput>) {
    setInputs((cur) => cur.map((x, j) => (j === i ? { ...x, ...patch } : x)));
    setTryOut(null);
  }

  function resolvedVars(): Record<string, string> | string {
    if (!target) return "Choose where the result goes first.";
    const vars: Record<string, string> = {};
    for (const inp of inputs) {
      const src = machines.find((m) => m.id === inp.machineId);
      if (!src) return `Value ${inp.letter}: choose a machine.`;
      const p = inputPath(target, src, inp.counter);
      if ("error" in p) return p.error;
      vars[inp.letter] = p.path;
    }
    return vars;
  }

  function draftWithRule(): ClientDescriptor | string {
    if (!descriptor || !target) return "Choose where the result goes first.";
    const vars = resolvedVars();
    if (typeof vars === "string") return vars;
    if (formulaError) return formulaError;
    return addDeriveRule(descriptor, target.id, target.topic, undefined, buildRule(result, formula, vars));
  }

  async function tryIt() {
    const draft = draftWithRule();
    if (typeof draft === "string") return toast.error(draft);
    const values = Object.fromEntries(inputs.map((i) => [i.letter, Number(tryValues[i.letter] ?? 0)]));
    setTrying(true);
    try {
      const res = await onboardingApi.simulate(draft, samplesFor(target!, inputs, values, machines, descriptor?.canonical?.prefix));
      const want = `${target!.topic.slice((descriptor?.canonical?.prefix ?? "").length)}/Admin/${result}/`;
      const hit = res.emitted.find((e) => e.metric.startsWith(want));
      setTryOut(hit ? String(hit.value) : "no result — check that every value has a number");
    } catch (e) {
      setTryOut(null);
      toast.error(e instanceof Error ? e.message : "Could not try the calculation");
    } finally {
      setTrying(false);
    }
  }

  function addToList() {
    const draft = draftWithRule();
    if (typeof draft === "string") return toast.error(draft);
    setDescriptor(draft);
    pickTarget("");
    toast.success("Added. Press Save to keep it.");
  }

  async function save() {
    if (!descriptor || !baseline) return;
    const before = new Map((baseline.equipment ?? []).map((e) => [e.id_equipment, JSON.stringify(e.derived ?? [])]));
    const derived = (descriptor.equipment ?? [])
      .filter((e) => e.id_equipment != null && before.get(e.id_equipment) !== JSON.stringify(e.derived ?? []))
      .map((e) => ({ id_equipment: e.id_equipment!, derived: e.derived ?? [] }));
    if (!derived.length) return;
    setSaving(true);
    try {
      const row = await onboardingApi.updateCustomizations(version, { derived });
      setVersion(row.version);
      setBaseline(row.descriptor);
      setDescriptor(row.descriptor);
      toast.success("Saved. Press “Apply now” to start using it.");
    } catch (e) {
      toast.error(
        isStaleSave(e)
          ? "Someone else saved changes while you were editing. Reload the page and add yours again."
          : e instanceof Error
            ? e.message
            : "Could not save",
      );
    } finally {
      setSaving(false);
    }
  }

  async function applyNow() {
    setApplying(true);
    try {
      const r = await edgeSsmApi.applyCalculations(idEnterprise);
      toast.success(r.mock ? "Test client — nothing was restarted." : "Applying… the data collector restarts in a few seconds.");
    } catch {
      toast.error("Could not apply right now. Try again in a minute, or ask the platform team.");
    } finally {
      setApplying(false);
    }
  }

  const machineName = (m: Machine) => `${m.name}${m.kind === "line" ? " (line)" : ""}`;

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title="Calculations"
        subtitle={`Create a new value from the counters ${enterprise.name}'s machines already send.`}
      />

      {state === "loading" ? (
        <Card className="p-6 text-[13px] text-muted-foreground">
          <Loader2 className="mr-2 inline h-4 w-4 animate-spin" /> Loading…
        </Card>
      ) : state === "error" ? (
        <Card className="p-6 text-[13px] text-muted-foreground">
          Couldn&apos;t load this client.{" "}
          <button className="text-primary hover:underline" onClick={() => void load()}>
            Try again
          </button>
        </Card>
      ) : state === "none" ? (
        <Card className="p-6 text-[13px] text-muted-foreground">
          {enterprise.name} isn&apos;t set up yet. Set it up in{" "}
          <a className="text-primary hover:underline" href={csadminUrl("/app/onboarding", idEnterprise)} target="_blank" rel="noreferrer">
            CS Admin ↗
          </a>{" "}
          first.
        </Card>
      ) : (
        <>
          <Card className="mb-5 flex gap-3 px-5 py-4 text-[13px] text-muted-foreground">
            <Info className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
            <p>
              <span className="font-semibold text-foreground">Example:</span> a line only counts what goes in and what
              comes out. Scrap = <span className="font-mono">what went in − good parts</span>. Or: a line has two
              packing machines, and the line total = <span className="font-mono">machine A + machine B</span>. The
              result is saved like a real counter, so OEE and the dashboards use it.
            </p>
          </Card>

          {/* existing calculations */}
          <Card className="mb-5 px-7 py-6">
            <p className="mb-3 text-[15px] font-extrabold text-foreground">Your calculations</p>
            {rules.length === 0 ? (
              <p className="text-[13px] text-muted-foreground">None yet — create one below.</p>
            ) : (
              <ul className="divide-y divide-border rounded-md border border-border">
                {rules.map((r) => {
                  const owner = machines.find((m) => m.id === r.id);
                  return (
                    <li key={`${r.id}:${r.idx}`} className="flex items-start gap-3 px-4 py-3 text-[13px]">
                      <div className="min-w-0 flex-1">
                        <p className="font-semibold text-foreground">
                          {owner ? machineName(owner) : `#${r.id}`} · {describeRule(r.rule)}
                        </p>
                        <p className="mt-0.5 text-[12px] text-muted-foreground">
                          {Object.entries(r.rule.expr?.vars ?? {}).map(([k, v]) => (
                            <span key={k} className="mr-3">
                              <span className="font-mono">{k}</span> = {owner ? describeInput(v, owner, machines) : v}
                            </span>
                          ))}
                        </p>
                      </div>
                      <button
                        type="button"
                        aria-label="Remove calculation"
                        onClick={() => setDescriptor((d) => (d ? removeDeriveRule(d, r.id, r.idx) : d))}
                      >
                        <Trash2 className="h-4 w-4 text-muted-foreground hover:text-danger" />
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </Card>

          {/* builder */}
          <Card className="mb-5 grid gap-5 px-7 py-6">
            <div className="flex items-center gap-2">
              <Calculator className="h-4 w-4 text-primary" />
              <span className="text-[15px] font-extrabold text-foreground">New calculation</span>
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-[13px]">
                <span className="mb-1 block font-semibold text-foreground">1. Where does the result go?</span>
                <Select id="calc-target" value={targetId} onChange={(e) => pickTarget(e.target.value === "" ? "" : Number(e.target.value))}>
                  <option value="">Choose a line or machine…</option>
                  {machines.map((m) => (
                    <option key={m.id} value={m.id}>
                      {machineName(m)}
                    </option>
                  ))}
                </Select>
              </label>
              <label className="text-[13px]">
                <span className="mb-1 block font-semibold text-foreground">What is the result?</span>
                <Select id="calc-result" value={result} onChange={(e) => setResult(e.target.value)} disabled={!target}>
                  {RESULTS.map((r) => (
                    <option key={r.leaf} value={r.leaf}>
                      {r.label} (e.g. {r.example})
                    </option>
                  ))}
                </Select>
              </label>
            </div>

            {target && (
              <>
                <div className="grid gap-2 text-[13px]">
                  <span className="font-semibold text-foreground">2. Which values does it use?</span>
                  {inputs.map((inp, i) => (
                    <div key={inp.letter} className="flex flex-wrap items-center gap-2">
                      <span className="w-6 font-mono text-[15px] font-bold text-primary">{inp.letter}</span>
                      <Select
                        id={`calc-in-${inp.letter}-machine`}
                        className="min-w-[180px] flex-1"
                        value={inp.machineId}
                        onChange={(e) => setInput(i, { machineId: Number(e.target.value) })}
                      >
                        {machines.map((m) => (
                          <option key={m.id} value={m.id}>
                            {m.id === target.id ? `${machineName(m)} — this one` : machineName(m)}
                          </option>
                        ))}
                      </Select>
                      <Select
                        id={`calc-in-${inp.letter}-counter`}
                        className="min-w-[180px] flex-1"
                        value={inp.counter}
                        onChange={(e) => setInput(i, { counter: e.target.value })}
                      >
                        {COUNTERS.map((c) => (
                          <option key={c.leaf} value={c.leaf}>
                            {c.label}
                          </option>
                        ))}
                      </Select>
                      {inputs.length > 1 && (
                        <button type="button" aria-label={`Remove value ${inp.letter}`} onClick={() => setInputs((cur) => cur.filter((_, j) => j !== i))}>
                          <Trash2 className="h-4 w-4 text-muted-foreground hover:text-danger" />
                        </button>
                      )}
                    </div>
                  ))}
                  {inputs.length < LETTERS.length && (
                    <div>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() =>
                          setInputs((cur) => [
                            ...cur,
                            { letter: LETTERS.find((l) => !cur.some((c) => c.letter === l))!, machineId: target.id, counter: "ProdProcessedCount" },
                          ])
                        }
                      >
                        <Plus className="h-3.5 w-3.5" /> Add a value
                      </Button>
                    </div>
                  )}
                </div>

                <label className="text-[13px]">
                  <span className="mb-1 block font-semibold text-foreground">3. Formula</span>
                  <Input id="calc-formula" value={formula} onChange={(e) => { setFormula(e.target.value); setTryOut(null); }} className="font-mono" />
                  <span className="mt-1.5 flex flex-wrap gap-1.5">
                    {FORMULA_EXAMPLES.map((f) => (
                      <button
                        key={f}
                        type="button"
                        onClick={() => setFormula(f)}
                        className="rounded border border-border bg-muted px-2 py-0.5 font-mono text-[12px] text-foreground hover:bg-muted-hover"
                      >
                        {f}
                      </button>
                    ))}
                  </span>
                  {formulaError && <span className="mt-1 block text-danger">{formulaError}</span>}
                </label>

                <div className="grid gap-2 rounded-md border border-border bg-muted/40 p-4 text-[13px]">
                  <span className="flex items-center gap-2 font-semibold text-foreground">
                    <FlaskConical className="h-4 w-4" /> 4. Try it with example numbers
                  </span>
                  <div className="flex flex-wrap items-center gap-3">
                    {inputs.map((inp) => (
                      <label key={inp.letter} className="flex items-center gap-1.5">
                        <span className="font-mono font-bold">{inp.letter} =</span>
                        <Input
                          id={`calc-try-${inp.letter}`}
                          className="h-[34px] w-24"
                          inputMode="decimal"
                          value={tryValues[inp.letter] ?? ""}
                          onChange={(e) => setTryValues((v) => ({ ...v, [inp.letter]: e.target.value }))}
                        />
                      </label>
                    ))}
                    <Button variant="ghost" size="sm" onClick={() => void tryIt()} disabled={trying || !!formulaError}>
                      {trying ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : null} Try
                    </Button>
                    {tryOut != null && (
                      <span className="text-[14px]">
                        Result: <span className="font-mono font-bold text-foreground">{tryOut}</span>
                      </span>
                    )}
                  </div>
                </div>

                <div>
                  <Button onClick={addToList} disabled={!!formulaError}>
                    <Plus className="h-4 w-4" /> Add calculation
                  </Button>
                </div>
              </>
            )}
          </Card>

          {/* save + apply */}
          <Card className="mb-8 grid gap-3 px-7 py-5 text-[13px]">
            <div className="flex flex-wrap items-center gap-3">
              <Button onClick={() => void save()} disabled={saving || !dirty}>
                {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />} Save
              </Button>
              <Button variant="ghost" onClick={() => void applyNow()} disabled={applying || dirty}>
                {applying ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Apply now
              </Button>
              <span className="text-muted-foreground">{dirty ? "You have unsaved changes." : "Everything is saved."}</span>
            </div>
            <p className="text-muted-foreground">
              <b className="text-foreground">Save</b> stores your calculations. <b className="text-foreground">Apply now</b>{" "}
              restarts the data collector so it starts using them (takes a few seconds; no data is lost). New results
              appear from that moment on — past data is not changed.
            </p>
          </Card>
        </>
      )}
    </div>
  );
}
