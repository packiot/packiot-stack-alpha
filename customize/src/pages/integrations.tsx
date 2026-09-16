import { Database, KeyRound, Loader2 } from "lucide-react";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import {
  classifyOnboardingError,
  onboardingApi,
  type DescriptorIntegration,
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

  const load = useCallback(async () => {
    setState("loading");
    try {
      const row = await onboardingApi.getDescriptor();
      setIntegrations(row.descriptor?.capabilities?.integrations ?? []);
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
        title="Database integrations"
        subtitle={`Outbound ERP / database connectors declared on ${enterprise.name}'s descriptor (ADR-0019). Read-only — authoring a connector is a Go-layer change escalated to engineering.`}
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
      ) : integrations.length === 0 ? (
        <Card className="p-6">
          <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
            <Database className="h-4 w-4" />
            No database integrations declared on this tenant's descriptor.
          </div>
        </Card>
      ) : (
        <div className="space-y-4">
          {integrations.map((it, i) => (
            <IntegrationCard key={i} integration={it} />
          ))}
        </div>
      )}
    </div>
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
