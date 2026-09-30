import { Gauge, Info, Loader2, RefreshCw, Save } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { classifyOnboardingError, isStaleSave, onboardingApi, type OeeProfile } from "@/api/onboarding";
import { edgeSsmApi } from "@/api/edge-ssm";
import { equipmentApi } from "@/api/equipment";
import { PageHeader } from "@/components/page-header";
import { Button, Card, Select } from "@/components/ui";
import { csadminUrl } from "@/lib/sibling-apps";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import { stableJson } from "@/lib/node-red-customizations";

type LoadState = "loading" | "ready" | "none" | "error";

/** How a line is measured — the one per-line choice the OEE engine supports. */
type Source = "inherit" | "lead" | "own";
const LEAD = { availability_mode: "count_silence", ideal_source: "lead_machine" } as const;

const sourceOfProfile = (p: { availability_mode?: string; ideal_source?: string } | undefined): Source =>
  !p || (p.availability_mode == null && p.ideal_source == null)
    ? "inherit"
    : p.availability_mode === "count_silence" || p.ideal_source === "lead_machine"
      ? "lead"
      : "own";

interface Line {
  id: number;
  name: string;
  hasLead: boolean | null; // null = unknown
}

/**
 * OEE settings — how OEE is calculated for a client, in plain words, for the
 * automation team. The client default + per-line choice both map onto the
 * engine's line-lead scope (rollup.LineLeadScope). Only settings the engine
 * actually uses are shown; the others stay stored as they are. Save is field-
 * scoped + version-checked; Apply restarts the OEE calculator, which reads the
 * settings at start-up. Changes apply from then on — the past is not changed.
 */
export function OeeProfilePage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const id = enterprise.id_enterprise;

  const [state, setState] = useState<LoadState>("loading");
  const [version, setVersion] = useState(0);
  const [saved, setSaved] = useState<OeeProfile | undefined>();
  const [lines, setLines] = useState<Line[]>([]);
  const [clientSource, setClientSource] = useState<Exclude<Source, "inherit">>("own");
  const [perLine, setPerLine] = useState<Record<string, Source>>({});
  const [saving, setSaving] = useState(false);
  const [applying, setApplying] = useState(false);

  const hydrate = useCallback((p: OeeProfile | undefined) => {
    setSaved(p);
    setClientSource(sourceOfProfile(p) === "lead" ? "lead" : "own");
    setPerLine(Object.fromEntries(Object.entries(p?.lines ?? {}).map(([k, v]) => [k, sourceOfProfile(v)])));
  }, []);

  const load = useCallback(async () => {
    setState("loading");
    try {
      const [row, eq] = await Promise.all([onboardingApi.getDescriptor(), equipmentApi.list({ idEnterprise: id }).catch(() => [])]);
      const raw = new Map(
        (eq as Array<{ id_equipment: number; nm_equipment?: string; lead_machine?: number | null }>).map((e) => [e.id_equipment, e]),
      );
      setLines(
        (row.descriptor?.equipment ?? [])
          .filter((e) => e.tp_equipment === 3 && e.id_equipment != null)
          .map((e) => {
            const r = raw.get(e.id_equipment!);
            return {
              id: e.id_equipment!,
              name: r?.nm_equipment || e.topic.split("/").pop() || `#${e.id_equipment}`,
              hasLead: r ? (r.lead_machine ?? 0) > 0 : null,
            };
          }),
      );
      setVersion(row.version);
      hydrate(row.descriptor?.oee_profile);
      setState("ready");
    } catch (err) {
      const kind = classifyOnboardingError(err);
      setState(kind === "not-found" || kind === "disabled" ? "none" : "error");
    }
  }, [id, hydrate]);

  useEffect(() => {
    void load();
  }, [load]);

  function build(): OeeProfile | null {
    // Start from what is stored so settings this page doesn't show are kept.
    const p: OeeProfile = { ...(saved ?? {}) };
    delete p.availability_mode;
    delete p.ideal_source;
    if (clientSource === "lead") Object.assign(p, LEAD);
    const lineMap: NonNullable<OeeProfile["lines"]> = {};
    for (const [k, v] of Object.entries(perLine)) {
      if (v === "lead") lineMap[k] = { ...LEAD };
      if (v === "own") lineMap[k] = { availability_mode: "state" };
    }
    if (Object.keys(lineMap).length) p.lines = lineMap;
    else delete p.lines;
    // The per-client spike clamp is retired (it wrote made-up values; the platform
    // ingest check rejects impossible jumps and records them). Saving drops it.
    delete p.spike_margin;
    const keys = Object.keys(p).filter((k) => k !== "version");
    if (!keys.length) return null;
    p.version = 1;
    return p;
  }

  const current = useMemo(() => {
    try {
      return stableJson(build());
    } catch {
      return "invalid";
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clientSource, perLine, saved]);
  // Compare against what's stored MINUS the retired spike clamp, so a profile that
  // still carries it doesn't open as "unsaved changes".
  const storedComparable = useMemo(() => {
    if (!saved) return null;
    const c: OeeProfile = { ...saved };
    delete c.spike_margin;
    return Object.keys(c).some((k) => k !== "version") ? c : null;
  }, [saved]);
  const dirty = current !== stableJson(storedComparable);

  async function save() {
    let profile: OeeProfile | null;
    try {
      profile = build();
    } catch (e) {
      return toast.error(e instanceof Error ? e.message : "Check the values");
    }
    setSaving(true);
    try {
      const row = await onboardingApi.updateCustomizations(version, { oeeProfile: profile });
      setVersion(row.version);
      hydrate(row.descriptor?.oee_profile);
      toast.success("Saved. Press “Apply now” to start using these settings.");
    } catch (e) {
      toast.error(isStaleSave(e) ? "Someone else saved while you were editing. Reload the page and make your change again." : e instanceof Error ? e.message : "Could not save");
    } finally {
      setSaving(false);
    }
  }

  async function applyNow() {
    setApplying(true);
    try {
      const r = await edgeSsmApi.applyOeeSettings(id);
      toast.success(r.mock ? "Test client — nothing was restarted." : "Applying… the OEE calculator restarts in a few seconds.");
    } catch {
      toast.error("Could not apply right now. Try again in a minute, or ask the platform team.");
    } finally {
      setApplying(false);
    }
  }

  const clientLabel = clientSource === "lead" ? "its lead machine" : "its own signals";

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="OEE settings" subtitle={`How OEE is calculated for ${enterprise.name}.`} />

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
          <a className="text-primary hover:underline" href={csadminUrl("/app/onboarding", id)} target="_blank" rel="noreferrer">
            CS Admin ↗
          </a>{" "}
          first.
        </Card>
      ) : (
        <>
          <Card className="mb-5 flex gap-3 px-5 py-4 text-[13px] text-muted-foreground">
            <Info className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
            <p>
              <b className="text-foreground">OEE = Availability × Performance × Quality.</b> Example: a line ran 7 of 8 hours
              (88%), at 90% of its ideal speed, and 98% of the parts were good → OEE = 0.88 × 0.90 × 0.98 ≈ 78%.
            </p>
          </Card>

          <Card className="mb-5 grid gap-4 px-7 py-6 text-[13px]">
            <div className="flex items-center gap-2">
              <Gauge className="h-4 w-4 text-primary" />
              <span className="text-[15px] font-extrabold text-foreground">Where does each line get its data?</span>
            </div>
            <p className="text-muted-foreground">
              Some lines send their own &ldquo;running / stopped&rdquo; signals. Others only count parts — for those, the line uses
              its <b className="text-foreground">lead machine</b> (the main machine that counts the line&apos;s output): the line is
              running while the lead machine is counting.
            </p>
            <label>
              <span className="mb-1 block font-semibold text-foreground">Default for all lines</span>
              <Select id="oee-client-source" value={clientSource} onChange={(e) => setClientSource(e.target.value as "lead" | "own")}>
                <option value="own">Each line&apos;s own signals</option>
                <option value="lead">The line&apos;s lead machine</option>
              </Select>
            </label>
            {lines.length > 0 && (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[420px] border-collapse">
                  <thead>
                    <tr className="border-b border-border text-left text-[12px] uppercase tracking-[0.05em] text-muted-foreground">
                      <th className="py-2 font-semibold">Line</th>
                      <th className="py-2 font-semibold">Gets its data from</th>
                    </tr>
                  </thead>
                  <tbody>
                    {lines.map((l) => {
                      const v = perLine[String(l.id)] ?? "inherit";
                      return (
                        <tr key={l.id} className="border-b border-border">
                          <td className="py-2 pr-3 font-semibold text-foreground">{l.name}</td>
                          <td className="py-2">
                            <Select
                              id={`oee-line-${l.id}`}
                              className="h-[34px]"
                              value={v}
                              onChange={(e) => setPerLine((cur) => ({ ...cur, [String(l.id)]: e.target.value as Source }))}
                            >
                              <option value="inherit">Default ({clientLabel})</option>
                              <option value="lead" disabled={l.hasLead === false}>
                                Its lead machine{l.hasLead === false ? " — no lead machine set" : ""}
                              </option>
                              <option value="own">Its own signals</option>
                            </Select>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
                {lines.some((l) => l.hasLead === false) && (
                  <p className="mt-2 text-[12px] text-muted-foreground">
                    A line without a lead machine can&apos;t use it. Set one in{" "}
                    <a className="text-primary hover:underline" href={csadminUrl("/app/line-config", id)} target="_blank" rel="noreferrer">
                      CS Admin → Line configuration ↗
                    </a>
                    .
                  </p>
                )}
              </div>
            )}
          </Card>

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
              <b className="text-foreground">Apply now</b> restarts the OEE calculator (a few seconds; no data is lost). New results
              use the new settings from that moment on. <b className="text-foreground">Past results don&apos;t change</b> — to
              recalculate the past, ask the platform team for a recompute of the lines and dates you need.
            </p>
          </Card>
        </>
      )}
    </div>
  );
}
