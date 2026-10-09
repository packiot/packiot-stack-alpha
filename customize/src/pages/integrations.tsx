import { Cpu, Database, KeyRound, Loader2, Plug } from "lucide-react";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import {
  classifyOnboardingError,
  onboardingApi,
  type DescriptorIntegration,
  type DescriptorPlcEndpoint,
} from "@/api/onboarding";
import { PageHeader } from "@/components/page-header";
import { Card } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";

type LoadState = "loading" | "ready" | "none" | "error";

/**
 * Database integrations (ADR-0019 capabilities.integrations) — READ-ONLY.
 *
 * Outbound connectors (ERP DB sync, etc.) are config-as-data on the descriptor.
 * Authoring one is a Go-connector change escalated to engineering, so this hub
 * only DISPLAYS them: type / driver / reads / writes / dedup key, plus the
 * `dsn_ref` secret POINTER (never a credential value — the descriptor stores a
 * `secret://…` reference and the loader's CI lint rejects inline secrets).
 */
export function IntegrationsPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;

  const [state, setState] = useState<LoadState>("loading");
  const [integrations, setIntegrations] = useState<DescriptorIntegration[]>([]);
  const [plc, setPlc] = useState<DescriptorPlcEndpoint[]>([]);

  const load = useCallback(async () => {
    setState("loading");
    try {
      const row = await onboardingApi.getDescriptor();
      setIntegrations(row.descriptor?.capabilities?.integrations ?? []);
      setPlc(row.descriptor?.plc?.endpoints ?? []);
      setState("ready");
    } catch (err) {
      const kind = classifyOnboardingError(err);
      if (kind === "not-found" || kind === "disabled") {
        setState("none");
        return;
      }
      setState("error");
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title="Connections & integrations"
        subtitle={`Everything ${enterprise.name} talks to — inbound PLC/reader connections the edge polls, and outbound ERP/database integrations (ADR-0019). Read-only.`}
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
            This tenant has no descriptor yet — there is nothing to show until it is
            onboarded in CS Admin.
          </p>
        </Card>
      ) : (
        <div className="space-y-8">
          {/* ── Inbound: PLC / reader connections (descriptor.plc.endpoints) ── */}
          <section>
            <div className="mb-3 flex items-center gap-2">
              <Cpu className="h-4 w-4 text-muted-foreground" />
              <h2 className="text-[15px] font-extrabold text-foreground">
                PLC / reader connections
              </h2>
              <span className="text-[12px] text-muted-foreground">
                {plc.length} {plc.length === 1 ? "endpoint" : "endpoints"}
              </span>
            </div>
            {plc.length === 0 ? (
              <Card className="p-6">
                <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
                  <Plug className="h-4 w-4" />
                  No PLC endpoints on this tenant's descriptor.
                </div>
              </Card>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {plc.map((e, i) => (
                  <PlcCard key={i} endpoint={e} />
                ))}
              </div>
            )}
          </section>

          {/* ── Outbound: ERP / database integrations (capabilities.integrations) ── */}
          <section>
            <div className="mb-3 flex items-center gap-2">
              <Database className="h-4 w-4 text-muted-foreground" />
              <h2 className="text-[15px] font-extrabold text-foreground">
                ERP / database integrations
              </h2>
              <span className="text-[12px] text-muted-foreground">
                {integrations.length}{" "}
                {integrations.length === 1 ? "connector" : "connectors"}
              </span>
            </div>
            {integrations.length === 0 ? (
              <Card className="p-6">
                <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
                  <Database className="h-4 w-4" />
                  No ERP/database integrations declared on this tenant's descriptor.
                </div>
              </Card>
            ) : (
              <div className="space-y-4">
                {integrations.map((it, i) => (
                  <IntegrationCard key={i} integration={it} />
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

function PlcCard({ endpoint }: { endpoint: DescriptorPlcEndpoint }) {
  const { name, host, port, protocol, rack, slot, hostEnv, host_ref } = endpoint;
  const addr = [host, port].filter(Boolean).join(":");
  return (
    <Card className="px-5 py-4">
      <div className="mb-2 flex items-center gap-2">
        <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary-tint text-primary-strong">
          <Cpu className="h-[16px] w-[16px]" />
        </span>
        <div className="text-[14px] font-extrabold text-foreground">
          {name || "PLC"}
        </div>
        {protocol ? (
          <span className="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] uppercase text-muted-foreground">
            {protocol}
          </span>
        ) : null}
      </div>
      <dl className="grid gap-x-4 gap-y-2 text-[12px] sm:grid-cols-2">
        <Meta label="Address" value={addr} mono />
        {rack != null || slot != null ? (
          <Meta label="Rack / slot" value={`${rack ?? "—"} / ${slot ?? "—"}`} mono />
        ) : null}
        <Meta
          label="Host (secret/env ref)"
          value={host_ref || hostEnv}
          mono
          icon={<KeyRound className="h-3.5 w-3.5 text-muted-foreground" />}
        />
      </dl>
    </Card>
  );
}

function IntegrationCard({ integration }: { integration: DescriptorIntegration }) {
  const { type, driver, dsn_ref, reads, writes, dedup_key } = integration;
  return (
    <Card className="px-7 py-6">
      <div className="mb-3 flex items-center gap-2">
        <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary-tint text-primary-strong">
          <Database className="h-[18px] w-[18px]" />
        </span>
        <div>
          <div className="text-[15px] font-extrabold text-foreground">
            {type || "connector"}
          </div>
          {driver ? (
            <div className="text-[12px] text-muted-foreground">
              driver: <span className="font-mono text-foreground">{driver}</span>
            </div>
          ) : null}
        </div>
      </div>

      <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
        <MetaList label="Reads" values={reads} />
        <MetaList label="Writes" values={writes} />
        <Meta label="Dedup key" value={dedup_key} mono />
        <Meta
          label="DSN (secret ref)"
          value={dsn_ref}
          mono
          icon={<KeyRound className="h-3.5 w-3.5 text-muted-foreground" />}
        />
      </dl>
    </Card>
  );
}

function Meta({
  label,
  value,
  mono,
  icon,
}: {
  label: string;
  value?: string;
  mono?: boolean;
  icon?: ReactNode;
}) {
  return (
    <div>
      <dt className="mb-0.5 flex items-center gap-1.5 text-[11px] font-bold uppercase tracking-[0.06em] text-muted-foreground">
        {icon}
        {label}
      </dt>
      <dd className={mono ? "font-mono text-[12px] text-foreground" : "text-[13px] text-foreground"}>
        {value || <span className="text-muted-foreground">—</span>}
      </dd>
    </div>
  );
}

function MetaList({ label, values }: { label: string; values?: string[] }) {
  return (
    <div>
      <dt className="mb-0.5 text-[11px] font-bold uppercase tracking-[0.06em] text-muted-foreground">
        {label}
      </dt>
      <dd>
        {values && values.length > 0 ? (
          <ul className="space-y-0.5 font-mono text-[12px] text-foreground">
            {values.map((v, i) => (
              <li key={i}>{v}</li>
            ))}
          </ul>
        ) : (
          <span className="text-[13px] text-muted-foreground">—</span>
        )}
      </dd>
    </div>
  );
}
