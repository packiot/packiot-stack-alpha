import { Gauge, Loader2, Save } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { toast } from "sonner";
import {
  classifyOnboardingError,
  onboardingApi,
  type ClientDescriptor,
  type OeeProfile,
} from "@/api/onboarding";
import { PageHeader } from "@/components/page-header";
import { Button, Card, Input, Select } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";

type LoadState = "loading" | "ready" | "none" | "error";

/**
 * WS3 / ADR-0058 — the per-client OEE computation editor. Different clients
 * compute OEE differently (counter-anomaly tolerance, availability derivation,
 * ideal-speed source, quality basis, stop horizon). This page makes that an
 * editable, versioned config-as-data object on the tenant descriptor instead of
 * a hardcoded env list, so Customer Success can tune a client's OEE math without
 * a code change.
 *
 * Only `spike_margin` is WIRED to the running pipeline today (the decoder's WS1
 * counter-anomaly guard, via oeeprofile.Watcher — a saved margin takes effect on
 * the next config refresh, no redeploy). The remaining knobs are authored now and
 * consumed by the rollup engine as each seam is migrated off its env list
 * (Phase 2). Every field defaults to "platform default" (unset), so a partial
 * profile never changes an un-migrated knob — absence is byte-identical behavior.
 */
export function OeeProfilePage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;

  const [state, setState] = useState<LoadState>("loading");
  const [tenantCode, setTenantCode] = useState<string>("");
  const [descriptor, setDescriptor] = useState<ClientDescriptor | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);

  // Form fields kept as strings so "" = unset (= platform default). A number
  // knob is only written to the profile when it parses to a finite value.
  const [spikeMargin, setSpikeMargin] = useState("");
  const [onAnomaly, setOnAnomaly] = useState("");
  const [availabilityMode, setAvailabilityMode] = useState("");
  const [idealSource, setIdealSource] = useState("");
  const [qualityBasis, setQualityBasis] = useState("");
  const [stopThresholdSec, setStopThresholdSec] = useState("");

  const hydrate = useCallback((p: OeeProfile | undefined) => {
    setSpikeMargin(p?.spike_margin != null ? String(p.spike_margin) : "");
    setOnAnomaly(p?.on_anomaly ?? "");
    setAvailabilityMode(p?.availability_mode ?? "");
    setIdealSource(p?.ideal_source ?? "");
    setQualityBasis(p?.quality_basis ?? "");
    setStopThresholdSec(p?.stop_threshold_sec != null ? String(p.stop_threshold_sec) : "");
  }, []);

  const load = useCallback(async () => {
    setState("loading");
    setDirty(false);
    try {
      const row = await onboardingApi.getDescriptor();
      setTenantCode(row.tenant_code);
      setDescriptor(row.descriptor ?? {});
      hydrate((row.descriptor ?? {}).oee_profile);
      setState("ready");
    } catch (err) {
      const kind = classifyOnboardingError(err);
      if (kind === "not-found" || kind === "disabled") {
        setState("none");
        return;
      }
      setState("error");
    }
  }, [hydrate]);

  useEffect(() => {
    void load();
  }, [load]);

  function touch<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v);
      setDirty(true);
    };
  }

  // Assemble the OeeProfile from the form, DROPPING every unset field so the
  // stored object carries only what the CS engineer actually set. Returns null
  // when nothing is set (⇒ we omit oee_profile entirely, byte-identical default).
  // Throws a user-facing message on an invalid value.
  function buildProfile(): OeeProfile | null {
    const p: OeeProfile = {};

    if (spikeMargin.trim() !== "") {
      const m = Number(spikeMargin);
      if (!Number.isFinite(m) || m <= 0) {
        throw new Error("Spike margin must be a positive number (e.g. 3).");
      }
      if (m < 1.5) {
        throw new Error("Spike margin < 1.5 would clamp real production — use ≥ 1.5 (typical 3–5).");
      }
      if (m > 1000) {
        throw new Error("Spike margin > 1000 is effectively no guard — pick a realistic bound.");
      }
      p.spike_margin = m;
    }
    if (onAnomaly !== "") p.on_anomaly = onAnomaly as OeeProfile["on_anomaly"];
    if (availabilityMode !== "") p.availability_mode = availabilityMode as OeeProfile["availability_mode"];
    if (idealSource !== "") p.ideal_source = idealSource as OeeProfile["ideal_source"];
    if (qualityBasis !== "") p.quality_basis = qualityBasis as OeeProfile["quality_basis"];
    if (stopThresholdSec.trim() !== "") {
      const s = Number(stopThresholdSec);
      if (!Number.isInteger(s) || s <= 0) {
        throw new Error("Stop threshold must be a positive whole number of seconds.");
      }
      p.stop_threshold_sec = s;
    }

    if (Object.keys(p).length === 0) return null;
    p.version = 1;
    return p;
  }

  async function save() {
    if (!descriptor) return;
    let profile: OeeProfile | null;
    try {
      profile = buildProfile();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Invalid OEE profile");
      return;
    }
    setSaving(true);
    try {
      // Load-modify-save the whole descriptor (same pattern as the derive-rule
      // editor). Omit oee_profile entirely when empty so an untouched tenant
      // stays byte-identical.
      const next: ClientDescriptor = { ...descriptor };
      if (profile) next.oee_profile = profile;
      else delete next.oee_profile;
      await onboardingApi.upsertDescriptor(tenantCode, next);
      setDescriptor(next);
      setDirty(false);
      toast.success(
        profile
          ? "OEE profile saved. The spike margin applies on the decoder's next config refresh."
          : "OEE profile cleared — this tenant is back on platform defaults.",
      );
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="OEE Computation"
        subtitle={`Tune how ${enterprise.name} computes OEE. Config-as-data on the tenant descriptor — no code change.`}
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
            This tenant has no descriptor yet — there is nothing to configure until it
            is onboarded in{" "}
            <Link className="text-primary hover:underline" to="/app/hub">
              CS Admin
            </Link>
            . Once onboarded, its OEE profile is editable here.
          </p>
        </Card>
      ) : (
        <>
          {/* ── WIRED: the WS1 counter-anomaly guard margin ── */}
          <Card className="mb-5 px-7 py-6">
            <div className="mb-1 flex items-center gap-2">
              <Gauge className="h-4 w-4 text-muted-foreground" />
              <span className="text-[15px] font-extrabold text-foreground">
                Counter-anomaly guard
              </span>
              <WiredBadge />
            </div>
            <p className="mb-4 text-[13px] text-muted-foreground">
              A counter increment implying a rate above{" "}
              <code className="font-mono">margin × ideal_speed</code> is a physically-
              impossible jump (a stuck/rolled totalizer) and is clamped before it reaches
              gross/net. This is the guard that stopped CPACK line L5 inflating 25–73× vs
              legacy. The bound is per-equipment (uses each machine's ideal speed); this
              margin is the client's tolerance.
            </p>
            <Field label="Spike margin" hint="Multiple of ideal speed. Typical 3–5. Empty = platform default (guard off unless set globally).">
              <Input
                type="number"
                inputMode="decimal"
                step="0.5"
                min="1.5"
                placeholder="platform default"
                value={spikeMargin}
                onChange={(e) => touch(setSpikeMargin)(e.target.value)}
                className="max-w-[220px]"
              />
            </Field>
            <Field label="On anomaly" hint="What to do with an over-threshold increment. Only 'clamp' is implemented today.">
              <Select
                value={onAnomaly}
                onChange={(e) => touch(setOnAnomaly)(e.target.value)}
                className="max-w-[220px]"
              >
                <option value="">platform default (clamp)</option>
                <option value="clamp">clamp to ceiling</option>
                <option value="reject" disabled>reject (Phase 2)</option>
                <option value="flag" disabled>flag only (Phase 2)</option>
              </Select>
            </Field>
          </Card>

          {/* ── Phase 2: rollup knobs (authored now, consumed as migrated) ── */}
          <Card className="mb-5 px-7 py-6">
            <div className="mb-1 flex items-center gap-2">
              <span className="text-[15px] font-extrabold text-foreground">
                OEE math
              </span>
              <PhaseTwoBadge />
            </div>
            <p className="mb-4 text-[13px] text-muted-foreground">
              How Availability, Performance and Quality are derived. Authored here now and
              read by the rollup engine as each seam moves off its per-client env list.
              Leave a field on <em>platform default</em> to keep today's behavior.
            </p>
            <Field label="Availability mode" hint="How running vs stopped time is derived.">
              <Select
                value={availabilityMode}
                onChange={(e) => touch(setAvailabilityMode)(e.target.value)}
                className="max-w-[280px]"
              >
                <option value="">platform default</option>
                <option value="state">state events (StateCurrent / downtimes)</option>
                <option value="count_silence">count silence (counters-only machines)</option>
              </Select>
            </Field>
            <Field label="Ideal-speed source" hint="Which speed the Performance factor is measured against.">
              <Select
                value={idealSource}
                onChange={(e) => touch(setIdealSource)(e.target.value)}
                className="max-w-[280px]"
              >
                <option value="">platform default</option>
                <option value="lead_machine">line lead machine's production_speed</option>
                <option value="nameplate">the equipment's own production_speed</option>
                <option value="inferred">inferred from history (provisional)</option>
              </Select>
            </Field>
            <Field label="Quality basis" hint="How the Quality factor is computed.">
              <Select
                value={qualityBasis}
                onChange={(e) => touch(setQualityBasis)(e.target.value)}
                className="max-w-[280px]"
              >
                <option value="">platform default (net / gross)</option>
                <option value="net_gross">net / gross</option>
                <option value="good_total">good / total</option>
              </Select>
            </Field>
            <Field label="Stop threshold (seconds)" hint="Idle longer than this counts as a stop (SparkPlug param 30751). Empty = per-equipment value, then env default.">
              <Input
                type="number"
                inputMode="numeric"
                step="1"
                min="1"
                placeholder="platform default"
                value={stopThresholdSec}
                onChange={(e) => touch(setStopThresholdSec)(e.target.value)}
                className="max-w-[220px]"
              />
            </Field>
          </Card>

          <div className="flex items-center justify-end gap-3">
            {dirty ? (
              <span className="text-[12px] text-muted-foreground">Unsaved changes</span>
            ) : null}
            <Button onClick={() => void save()} disabled={saving || !dirty}>
              {saving ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Save className="h-4 w-4" />
              )}
              Save profile
            </Button>
          </div>
        </>
      )}
    </div>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint: string;
  children: React.ReactNode;
}) {
  return (
    <div className="mb-4">
      <label className="mb-1 block text-[13px] font-bold text-foreground">{label}</label>
      {children}
      <p className="mt-1 text-[12px] text-muted-foreground">{hint}</p>
    </div>
  );
}

function WiredBadge() {
  return (
    <span className="inline-flex items-center rounded-full bg-success-tint px-[9px] py-[2px] text-[11px] font-bold text-success">
      Live
    </span>
  );
}

function PhaseTwoBadge() {
  return (
    <span className="inline-flex items-center rounded-full bg-muted px-[9px] py-[2px] text-[11px] font-bold text-muted-foreground">
      Phase 2
    </span>
  );
}
