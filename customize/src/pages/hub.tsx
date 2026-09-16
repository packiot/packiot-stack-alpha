import {
  Braces,
  Clock,
  Database,
  Loader2,
  ServerCog,
  Workflow,
  type LucideIcon,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import {
  classifyOnboardingError,
  onboardingApi,
  type ClientDescriptor,
} from "@/api/onboarding";
import { equipmentApi } from "@/api/equipment";
import { PageHeader } from "@/components/page-header";
import { Card } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";
import { listDeriveRules } from "@/lib/derive-rules";

type LoadState = "loading" | "ready" | "none" | "error";

// Box Ops (Tier-2 Node-RED editor) lives in CS Admin for now — the Hub links out
// to it rather than embedding it. Kept as a constant so the target is a one-line
// change when/if Box Ops moves into this app.
const CSADMIN_BOX_OPS_URL = "https://csadmin.staging.packiot.app/app/box";

/**
 * The Customization Hub landing page — the centerpiece. For the selected
 * enterprise it loads the ADR-0045 descriptor row (via the SAME
 * `onboardingApi.getDescriptor()` the derive-rule editor uses) and surfaces:
 *   1. a row of customization option cards (derive rules / integrations /
 *      Node-RED flows), each with a live count badge + click-through, and
 *   2. a "Recent customizations" panel — the CURRENT derive rules on the
 *      descriptor, ordered by equipment, stamped with the descriptor
 *      version + updated_at (there is NO per-rule timestamp, so we do NOT
 *      fabricate one — the panel is labelled honestly as the current state).
 */
export function HubPage() {
  const enterprise = useEnterpriseStore((s) => s.selected)!;
  const idEnterprise = enterprise.id_enterprise;

  const [state, setState] = useState<LoadState>("loading");
  const [descriptor, setDescriptor] = useState<ClientDescriptor | null>(null);
  const [version, setVersion] = useState<number | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [nameById, setNameById] = useState<Map<number, string>>(new Map());

  const load = useCallback(async () => {
    setState("loading");
    try {
      const [row, eq] = await Promise.all([
        onboardingApi.getDescriptor(),
        equipmentApi.list({ idEnterprise }).catch(() => []),
      ]);
      const m = new Map<number, string>();
      for (const e of eq as Array<{ id_equipment: number; cd_equipment?: string }>)
        m.set(e.id_equipment, e.cd_equipment ?? "");
      setNameById(m);
      setDescriptor(row.descriptor ?? {});
      setVersion(row.version);
      setUpdatedAt(row.updated_at);
      setState("ready");
    } catch (err) {
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

  // topic per equipment straight off the descriptor (for a nicer rule label).
  const topicById = useMemo(() => {
    const m = new Map<number, string>();
    for (const e of descriptor?.equipment ?? [])
      if (e.id_equipment != null) m.set(e.id_equipment, e.topic ?? "");
    return m;
  }, [descriptor]);

  const rules = useMemo(
    () => (descriptor ? listDeriveRules(descriptor, (id) => topicById.get(id)) : []),
    [descriptor, topicById],
  );

  const integrationsCount = descriptor?.capabilities?.integrations?.length ?? 0;
  const flowsCount = descriptor?.customizations?.length ?? 0;

  const updatedLabel = updatedAt
    ? new Date(updatedAt).toLocaleString()
    : "unknown";

  return (
    <div className="mx-auto max-w-5xl">
      <PageHeader
        title="Customization Hub"
        subtitle={`Everything you can tailor for ${enterprise.name} — declarative derive rules, database integrations, and Node-RED flows.`}
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
            it is onboarded in CS Admin. Once a descriptor exists, its derive rules
            and integrations show up here.
          </p>
        </Card>
      ) : (
        <>
          {/* ── option cards ── */}
          <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <OptionCard
              to="/app/customizations"
              icon={Braces}
              title="Derive rules"
              badge="Tier 1"
              count={rules.length}
              countLabel={rules.length === 1 ? "rule" : "rules"}
              description="Author declarative expr transforms — scrap = gross − net, merge two PLCs, unit conversions — without hand-editing JSON."
            />
            <OptionCard
              to="/app/integrations"
              icon={Database}
              title="Database integrations"
              badge="ADR-0019"
              count={integrationsCount}
              countLabel={integrationsCount === 1 ? "connector" : "connectors"}
              description="Outbound ERP / database connectors this tenant's edge stack stands up. Read-only view of type, driver, reads, writes and dedup key."
            />
            <OptionCard
              href={CSADMIN_BOX_OPS_URL}
              icon={Workflow}
              title="Node-RED flows"
              badge="Tier 2"
              count={flowsCount}
              countLabel={flowsCount === 1 ? "flow node" : "flow nodes"}
              description="Arbitrary per-client Node-RED logic. Authored in the embedded editor on Box Ops — which lives in CS Admin for now (opens in a new tab)."
            />
          </div>

          {/* ── recent customizations ── */}
          <Card className="mb-8 px-7 py-6">
            <div className="mb-1 flex items-center gap-2">
              <Clock className="h-4 w-4 text-muted-foreground" />
              <span className="text-[15px] font-extrabold text-foreground">
                Recent customizations
              </span>
            </div>
            <p className="mb-4 text-[13px] text-muted-foreground">
              Current customizations on descriptor{" "}
              <span className="font-mono text-foreground">
                v{version ?? "?"}
              </span>
              , updated <span className="text-foreground">{updatedLabel}</span>. The
              descriptor carries no per-rule timestamp — this is the full current
              rule set, ordered by equipment (not a per-rule history).
            </p>

            {rules.length > 0 ? (
              <ul className="space-y-1.5 text-[12px]">
                {rules.map((r) => (
                  <li
                    key={`${r.id}:${r.idx}`}
                    className="flex items-center gap-2 rounded-md bg-muted px-3 py-2 font-mono"
                  >
                    <span className="text-muted-foreground">
                      {nameById.get(r.id) || r.topic || `#${r.id}`}
                    </span>
                    <span className="text-foreground">
                      {r.rule.emit[0]}
                      {r.rule.expr ? ` = ${r.rule.expr.expr}` : ""}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
                <ServerCog className="h-4 w-4" />
                No derive rules authored yet.{" "}
                <Link className="text-primary hover:underline" to="/app/customizations">
                  Add the first one →
                </Link>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

/** One customization option card. Either an in-app `to` route (Link) or an
 *  external `href` (opens a new tab) — exactly one is provided. */
function OptionCard({
  to,
  href,
  icon: Icon,
  title,
  badge,
  count,
  countLabel,
  description,
}: {
  to?: string;
  href?: string;
  icon: LucideIcon;
  title: string;
  badge: string;
  count: number;
  countLabel: string;
  description: string;
}) {
  const body = (
    <>
      <div className="mb-3 flex items-center justify-between">
        <span className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary-tint text-primary-strong">
          <Icon className="h-5 w-5" />
        </span>
        <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-bold uppercase tracking-[0.06em] text-muted-foreground">
          {badge}
        </span>
      </div>
      <div className="mb-1 flex items-baseline gap-2">
        <span className="text-[15px] font-extrabold text-foreground">{title}</span>
        <span className="text-[12px] font-bold text-primary">
          {count} {countLabel}
        </span>
      </div>
      <p className="text-[13px] leading-snug text-muted-foreground">{description}</p>
    </>
  );

  const cls =
    "group flex flex-col rounded-lg border border-border bg-surface p-5 text-left shadow-[0_1px_3px_rgba(0,0,0,0.05)] transition hover:border-primary hover:shadow-[0_4px_16px_rgba(0,0,0,0.12)]";

  if (href) {
    return (
      <a href={href} target="_blank" rel="noreferrer" className={cls}>
        {body}
      </a>
    );
  }
  return (
    <Link to={to!} className={cls}>
      {body}
    </Link>
  );
}
