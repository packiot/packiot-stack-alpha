import { isAxiosError } from "axios";
import { apiClient } from "@/lib/api-client";

/**
 * ADR-0045 "config-as-data" onboarding control plane, all on edge-api.
 *
 * Every route is CS-authed and tenant-scoped by `?idEnterprise=` — which the
 * api-client interceptor attaches automatically from the selected enterprise, so
 * callers here never pass it. The whole slice is DARK-BY-DEFAULT server-side
 * (`EDGE_API_ONBOARDING_ENABLED`): when the flag is off EVERY route 404s with
 * "Cannot resolve route" (indistinguishable from not existing). We tag those
 * reads `skipErrorToast` and classify the 404 in the UI so a fresh tenant (no
 * descriptor) and a disabled feature both render as graceful states, never a
 * red toast.
 *
 * The lifecycle status advances draft → generated → deployed → captured →
 * validated → cutover; the UI stepper is driven off the descriptor row's
 * `status`. `deployed` (Box-Ops: bundle pushed to the client box over SSM) sits
 * between `generated` and `captured`.
 */

export type OnboardingStatus =
  | "draft"
  | "generated"
  | "deployed"
  | "captured"
  | "validated"
  | "cutover";

export type CountIndexConfidence = "inferred" | "confirmed";

export interface CountIndex {
  value: number;
  confidence: CountIndexConfidence;
}

/** A declarative expr derive rule (ADR-0058 Tier 1): emit = f(vars). */
export interface DescriptorExprRule {
  /** Short identifier → the arriving metric suffix that binds it. */
  vars: Record<string, string>;
  /** Arithmetic expression over the vars keys, e.g. "gross - net". */
  expr: string;
}

/** One derived-metric rule on an equipment (ADR-0058). This UI authors the `expr`
 *  variant; integral/sum round-trip untouched via the index signature. */
export interface DescriptorDerived {
  /** Canonical count leaves this rule publishes (relative, e.g. "/Admin/ProdDefectiveCount/{idx}/Unit"). */
  emit: string[];
  /** SparkPlug type of the emitted count (double|float|long|int|bool|string). */
  type: string;
  expr?: DescriptorExprRule;
  [k: string]: unknown;
}

/** One equipment row inside the descriptor JSONB (tp=1 members carry a count_index). */
export interface DescriptorEquipment {
  topic: string;
  id_equipment?: number;
  id_unit?: number;
  tp_equipment?: number;
  count_index?: CountIndex;
  /** Agent-side derive rules (ADR-0058). Preserved across compose by id_equipment. */
  derived?: DescriptorDerived[];
  [k: string]: unknown;
}

export interface AliasPair {
  from: string;
  to: string;
}

export interface ParameterAlias extends AliasPair {
  applies_to?: string;
}

export interface DescriptorMapping {
  count_index_default_mode?: string;
  prefix_fixups?: AliasPair[];
  metric_aliases?: AliasPair[];
  parameter_aliases?: ParameterAlias[];
  parameter_decomposition?: unknown[];
  [k: string]: unknown;
}

/**
 * One outbound connector (ADR-0019 capabilities.integrations — the ERP database
 * sync et al). The descriptor stores it as config-as-data; `dsn_ref` is ALWAYS a
 * `secret://` pointer, never an inline credential (the loader's CI lint enforces
 * this). This UI renders it READ-ONLY — authoring integrations is a Go-connector
 * concern escalated to engineering.
 */
export interface DescriptorIntegration {
  /** Connector type, e.g. "erp_db_sync" (see the ADR-0019 G1/G2 connectors). */
  type?: string;
  /** DB driver when type is a database connector, e.g. "postgres" | "mssql". */
  driver?: string;
  /** Secret reference (never a value) — `secret://…`. */
  dsn_ref?: string;
  /** Source tables/streams this connector READS. */
  reads?: string[];
  /** Destination tables/streams this connector WRITES. */
  writes?: string[];
  /** Idempotency key column used to de-duplicate rows. */
  dedup_key?: string;
  [k: string]: unknown;
}

/** ADR-0019 capabilities block. We type only `integrations` (the surface this
 *  hub reads); everything else round-trips via the index signature. */
export interface DescriptorCapabilities {
  integrations?: DescriptorIntegration[];
  [k: string]: unknown;
}

/**
 * The tenant descriptor (ADR-0045 SSoT). Opaque JSONB to edge-api — validated
 * downstream by edge-transformer on generate. We type the fields the CS editor
 * drives and keep an index signature so unknown keys (metric_templates, agent,
 * tee, …) round-trip untouched.
 */
/** One physical PLC/reader connection the edge reader polls (descriptor `plc.
 *  endpoints[]`). host/port/protocol are the live connection; hostEnv/host_ref
 *  are the deploy-time indirection (a secret/env pointer, not a value). */
export interface DescriptorPlcEndpoint {
  name?: string;
  host?: string;
  port?: number;
  protocol?: string;
  rack?: number;
  slot?: number;
  hostEnv?: string;
  host_ref?: string;
  [k: string]: unknown;
}

/** The tenant's inbound PLC/reader connections (descriptor `plc`). */
export interface DescriptorPlc {
  endpoints?: DescriptorPlcEndpoint[];
  [k: string]: unknown;
}

export interface ClientDescriptor {
  /** ADR-0019 edge capabilities (operator mode, commands, integrations, custom
   *  flows). The Integrations page reads `capabilities.integrations`. */
  capabilities?: DescriptorCapabilities;
  /** Inbound PLC/reader connections the edge reader polls (host/port/protocol
   *  per line). The Connections page surfaces these. */
  plc?: DescriptorPlc;
  tenant?: string;
  enterprise_id?: number;
  canonical?: { prefix?: string; [k: string]: unknown };
  mapping?: DescriptorMapping;
  equipment?: DescriptorEquipment[];
  /**
   * Client-level edge property: this tenant's PLCs report production counters
   * but NO live machine-speed sensor (typical Modbus/S7 lines). When true the
   * cloud decoder must run the counters-only OEE path (COUNTERS_ONLY_OEE_ENABLED)
   * and derive rated speed from each equipment's `production_speed` — otherwise
   * its OEE glitch guard silently drops every counter and OEE stays at zero.
   * Captured here as config-as-data; the bundle generator / decoder read it (see
   * FOLLOW-UP in docs/clients/csadmin-bundle-setup-gaps.md — today it's hardcoded
   * in compose.production.yml).
   */
  counters_only_oee?: boolean;
  /**
   * Per-client Node-RED customizations (ADR-0045 §G3). Each entry is one RAW
   * Node-RED node object — exactly what "Export" produces in Node-RED. The bundle
   * generator (edge-transformer onboard-gen) renders these onto the generated
   * reader flow's "<Tenant> customizations" tab, so per-client integrations
   * (extra edge-api calls for PO control / downtimes, bespoke transforms,
   * dashboards) are DESCRIPTOR-SOURCED + versioned instead of hand-added on the
   * box (where the nodered-data volume loses them on any redeploy). Absent/empty
   * ⇒ the customizations tab is emitted empty (historical behavior).
   */
  customizations?: NodeRedNode[];
  [k: string]: unknown;
}

/** One raw Node-RED node (a "Export" object). Kept opaque — the generator + the
 *  Node-RED runtime own its schema; we only round-trip it through the descriptor. */
export type NodeRedNode = Record<string, unknown>;

export interface OnboardingArtifacts {
  profile_yaml: string;
  register_sql: string;
  agent_yaml: string;
  tee_node_json: string;
}

/** The four artifact fields, in render order — the only keys the editor drives. */
export const ARTIFACT_KEYS = [
  "profile_yaml",
  "register_sql",
  "agent_yaml",
  "tee_node_json",
] as const;

export type ArtifactKey = (typeof ARTIFACT_KEYS)[number];

/**
 * Dirty-diff for the manual-edit override: compare edited `drafts` against the
 * saved `artifacts` and return ONLY the fields that changed — exactly the body
 * `updateArtifacts` PUTs. An empty result ⇒ nothing to save (Save stays disabled).
 * A null saved row (never generated) treats every non-empty draft as changed, so
 * the caller can never PUT a no-op patch. Pure + framework-free so the wizard's
 * dirty tracking is unit-testable in isolation.
 */
export function artifactPatch(
  saved: OnboardingArtifacts | null,
  drafts: OnboardingArtifacts
): Partial<OnboardingArtifacts> {
  const patch: Partial<OnboardingArtifacts> = {};
  for (const key of ARTIFACT_KEYS) {
    const savedValue = saved?.[key] ?? "";
    if (drafts[key] !== savedValue) patch[key] = drafts[key];
  }
  return patch;
}

export interface InferredIndex {
  topic: string;
  index: number;
}

export interface OnboardingValidation {
  inferred_count_indices: InferredIndex[];
  cutover_eligible: boolean;
  unmapped: string[];
}

export interface ClientDescriptorRow {
  id: number;
  id_enterprise: number;
  tenant_code: string;
  descriptor: ClientDescriptor;
  version: number;
  status: OnboardingStatus;
  artifacts: OnboardingArtifacts | null;
  validation: OnboardingValidation | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
}

export interface GenerateResponse {
  tenant: string;
  artifacts: OnboardingArtifacts;
  validation: OnboardingValidation;
}

/** One raw input tag fed to the simulator (ADR-0058 simulate-before-deploy). */
export interface SimulateSample {
  metric: string;
  value: number;
  ts_millis: number;
}

/** A compact summary of one active derive rule (shown before any samples run). */
export interface SimulateRule {
  segment: string;
  emit: string[];
  kind: string; // integral | sum | expr
  expr?: string;
}

/** One synthesized tag the deriver produced, tagged with its triggering input. */
export interface SimulateEmitted {
  metric: string;
  value: unknown;
  ts_millis: number;
  after_input: string;
}

export interface SimulateResponse {
  tenant: string;
  derived_rules: SimulateRule[];
  emitted: SimulateEmitted[];
}

export interface ApplyRegisterResult {
  applied: boolean;
  rowsInserted: number;
  status: OnboardingStatus;
}

export interface LineMeterPlan {
  line_id: number;
  line_topic: string;
  gross_machine: number | null;
  lead_machine: number | null;
  scrap_machine: number | null;
  needs_confirm: boolean;
  note: string;
}
export interface ApplyLineMetersResult {
  applied: number;
  needsConfirm: LineMeterPlan[];
  lines: LineMeterPlan[];
}

export interface CaptureStartResult {
  status: OnboardingStatus;
  previousStatus: OnboardingStatus;
}

export interface CaptureStopResult {
  status: OnboardingStatus;
  previousStatus: OnboardingStatus;
  remainingInferred: number;
}

export type CaptureEntryStatus =
  | "confirmed"
  | "mismatch"
  | "unobserved"
  | "derived"
  | "extra";

export interface CaptureReportEntry {
  topic: string;
  id_equipment: number | null;
  descriptor_index: number | null;
  confidence: CountIndexConfidence | null;
  observed_indices: number[];
  status: CaptureEntryStatus;
}

export interface CaptureReport {
  entries: CaptureReportEntry[];
  summary: {
    confirmed: number;
    mismatch: number;
    unobserved: number;
    derived: number;
    extra: number;
    descriptor_count_entries: number;
    observations: number;
    remaining_inferred: number;
  };
}

export interface CaptureConfirmResult {
  descriptor: ClientDescriptor;
  version: number;
  confirmed: string[];
  skipped: { topic: string; reason: string }[];
  remainingInferred: number;
}

export interface CutoverResult {
  status: OnboardingStatus;
  cutoverEligible: true;
  cutoverWired: boolean;
  intendedAction: string;
}

export interface MarkDeployedResult {
  status: OnboardingStatus;
  previousStatus: OnboardingStatus;
  /** false when the call was a no-op (already deployed or past it). */
  changed: boolean;
}

/**
 * ADR-0053 "fat-edge B-minimal" per-tenant switch: run the decode stack (agent +
 * broker + transformer + local dashboard) ON the client's factory box so the shop
 * floor keeps live visibility and no counts are lost during an internet outage.
 * Advisory onboarding preference — absent flag reads as `false` (cloud-only).
 */
export interface OnpremOfflineState {
  enabled: boolean;
}

export interface OperatorEdgeState {
  enabled: boolean;
}

export interface BarcodeEdgeState {
  enabled: boolean;
}

/**
 * ADR-0047 P0 config-completeness gate (distinct from the ADR-0045 `validate`
 * cutover/DQ gate). Probes live config tables for the holes that make OEE
 * wrong-but-not-erroring — the CPACK archetype where a producing line had no
 * ideal speed and Performance silently collapsed. `ready` is false iff any
 * error-severity issue; warnings inform but don't block.
 */
export type ReadinessSeverity = "error" | "warning";

export interface ReadinessEquipmentRef {
  id_equipment: number;
  nm_equipment: string;
  tp_equipment: number;
}

export interface ReadinessIssue {
  code: string;
  severity: ReadinessSeverity;
  message: string;
  equipment?: ReadinessEquipmentRef[];
  detail?: unknown;
}

export interface OnboardingReadiness {
  id_enterprise: number;
  ready: boolean;
  error_count: number;
  warning_count: number;
  issues: ReadinessIssue[];
}

/**
 * The dark-by-default 404 ("Cannot resolve route") is how a disabled feature
 * looks; a real not-found ("No descriptor stored…") is a fresh tenant. Both are
 * 404s — we discriminate on the message so the UI can show the right state.
 */
export type OnboardingErrorKind = "disabled" | "not-found" | "other";

export function classifyOnboardingError(err: unknown): OnboardingErrorKind {
  if (!isAxiosError(err)) return "other";
  if (err.response?.status !== 404) return "other";
  const message = String(err.response?.data?.message ?? "");
  return /cannot resolve route/i.test(message) ? "disabled" : "not-found";
}

const DESCRIPTOR = "/api/onboarding/descriptor";

export const onboardingApi = {
  /**
   * Fetch the current descriptor row (+ cached artifacts/validation/status).
   * 404s are EXPECTED (disabled feature, or fresh tenant) → we suppress the
   * global toast and let the caller classify.
   */
  getDescriptor: () =>
    apiClient
      .get<ClientDescriptorRow>(DESCRIPTOR, { skipErrorToast: true })
      .then((r) => r.data),

  upsertDescriptor: (tenantCode: string, descriptor: ClientDescriptor) =>
    apiClient
      .post<ClientDescriptorRow>(DESCRIPTOR, { tenantCode, descriptor })
      .then((r) => r.data),

  generate: () =>
    apiClient
      .post<GenerateResponse>("/api/onboarding/generate")
      .then((r) => r.data),

  /**
   * POST /api/onboarding/simulate — preview what a DRAFT descriptor's derive/expr
   * rules would produce for `samples`, BEFORE deploy (ADR-0058 simulate-before-
   * deploy). The draft descriptor travels in the body (not the stored row), so
   * this reflects the CS engineer's in-flight edits. Nothing is persisted.
   */
  simulate: (descriptor: ClientDescriptor, samples: SimulateSample[]) =>
    apiClient
      .post<SimulateResponse>("/api/onboarding/simulate", { descriptor, samples })
      .then((r) => r.data),

  /**
   * PUT /api/onboarding/artifacts — persist a CS engineer's MANUAL EDITS to one
   * or more generated artifacts (an override of what `generate` produced). The
   * body carries ONLY the changed artifact fields (see `artifactPatch`); the
   * server rejects an empty artifact and returns the updated descriptor row (same
   * shape as `getDescriptor`). CS-authed + tenant-scoped by `?idEnterprise=`
   * (attached by the api-client interceptor), exactly like `generate`.
   *
   * NOTE: `generate`/"Rebuild config" overwrites `artifacts` WHOLESALE, so these
   * edits are discarded on the next rebuild by design — the UI warns about this.
   */
  updateArtifacts: (patch: Partial<OnboardingArtifacts>) =>
    apiClient
      .put<ClientDescriptorRow>("/api/onboarding/artifacts", patch)
      .then((r) => r.data),

  applyRegister: () =>
    apiClient
      .post<ApplyRegisterResult>("/api/onboarding/apply-register")
      .then((r) => r.data),

  captureStart: () =>
    apiClient
      .post<CaptureStartResult>("/api/onboarding/capture/start")
      .then((r) => r.data),

  captureStop: () =>
    apiClient
      .post<CaptureStopResult>("/api/onboarding/capture/stop")
      .then((r) => r.data),

  captureReport: () =>
    apiClient
      .get<CaptureReport>("/api/onboarding/capture/report", {
        skipErrorToast: true,
      })
      .then((r) => r.data),

  captureConfirm: (target: { all?: boolean; topics?: string[] }) =>
    apiClient
      .post<CaptureConfirmResult>("/api/onboarding/capture/confirm", target)
      .then((r) => r.data),

  validate: () =>
    apiClient
      .get<OnboardingValidation>("/api/onboarding/validate", {
        skipErrorToast: true,
      })
      .then((r) => r.data),

  cutover: () =>
    apiClient.post<CutoverResult>("/api/onboarding/cutover").then((r) => r.data),

  /**
   * POST /api/onboarding/mark-deployed — advance the descriptor
   * `generated → deployed` after the "Deploy to box" step has pushed the bundle
   * to the client box over SSM. Idempotent server-side: a no-op (still 200) when
   * the tenant is already `deployed` or past it, so the Deploy step can call it
   * unconditionally after a green deploy to advance the wizard to Capture.
   */
  markDeployed: () =>
    apiClient
      .post<MarkDeployedResult>("/api/onboarding/mark-deployed")
      .then((r) => r.data),

  /**
   * GET /api/onboarding/readiness — the ADR-0047 config-completeness report.
   * 404s are EXPECTED (disabled slice) → suppress the toast and let the caller
   * classify, same as the other onboarding reads.
   */
  readiness: () =>
    apiClient
      .get<OnboardingReadiness>("/api/onboarding/readiness", {
        skipErrorToast: true,
      })
      .then((r) => r.data),

  /**
   * POST /api/onboarding/reset — resets the descriptor row back to `draft` and
   * clears the generated artifacts + validation. The descriptor BODY is kept, so
   * this re-runs onboarding from the top without re-authoring. Returns the fresh
   * descriptor row (same shape as getDescriptor).
   */
  reset: () =>
    apiClient
      .post<ClientDescriptorRow>("/api/onboarding/reset")
      .then((r) => r.data),

  /**
   * POST /api/onboarding/apply-line-meters — auto-designate each tp=3 line's
   * infeed (gross_machine) + outfeed (lead_machine) meter from the descriptor
   * (role-based). The outfeed among several nets is a guess flagged in
   * `needsConfirm` — the CS confirms/overrides it per line in Line configuration.
   */
  applyLineMeters: () =>
    apiClient
      .post<ApplyLineMetersResult>("/api/onboarding/apply-line-meters")
      .then((r) => r.data),

  /**
   * GET /api/onboarding/onprem-offline — read the ADR-0053 "run the decode stack
   * on the client's factory box" preference for a tenant. Explicitly scoped by
   * `idEnterprise` (rather than leaning on the interceptor default) so the caller
   * names the tenant it reads. 404s are EXPECTED when the onboarding slice is dark
   * OR the flag was never set — both mean "not enabled", so we suppress the global
   * toast and let the caller default to `false`.
   */
  getOnpremOffline: (idEnterprise: number) =>
    apiClient
      .get<OnpremOfflineState>("/api/onboarding/onprem-offline", {
        params: { idEnterprise },
        skipErrorToast: true,
      })
      .then((r) => r.data),

  /**
   * POST /api/onboarding/onprem-offline — persist the on-prem offline preference
   * for a tenant. Carries `idEnterprise` in the BODY (per the edge-api contract)
   * alongside the desired `enabled` state and returns the stored value. We suppress
   * the global toast so the card owns failure handling: it rolls the optimistic
   * switch back and raises a single toast itself.
   */
  setOnpremOffline: (idEnterprise: number, enabled: boolean) =>
    apiClient
      .post<OnpremOfflineState>(
        "/api/onboarding/onprem-offline",
        { idEnterprise, enabled },
        { skipErrorToast: true },
      )
      .then((r) => r.data),

  /**
   * GET /api/onboarding/operator-edge — read the ADR-0054 "also run the operator
   * SPA on the client's factory box" preference for a tenant. Only meaningful
   * alongside on-prem offline (the operator rides the fat-edge box). Scoped by
   * `idEnterprise`. 404s are EXPECTED when the slice is dark OR the flag was never
   * set — both mean "not enabled", so we suppress the toast and default to false.
   */
  getOperatorEdge: (idEnterprise: number) =>
    apiClient
      .get<OperatorEdgeState>("/api/onboarding/operator-edge", {
        params: { idEnterprise },
        skipErrorToast: true,
      })
      .then((r) => r.data),

  /**
   * POST /api/onboarding/operator-edge — persist the edge-operator preference for
   * a tenant. Carries `idEnterprise` in the BODY (per the edge-api contract) with
   * the desired `enabled` state and returns the stored value. Toast suppressed so
   * the card owns failure handling (optimistic roll-back + a single toast).
   */
  setOperatorEdge: (idEnterprise: number, enabled: boolean) =>
    apiClient
      .post<OperatorEdgeState>(
        "/api/onboarding/operator-edge",
        { idEnterprise, enabled },
        { skipErrorToast: true },
      )
      .then((r) => r.data),

  /**
   * GET /api/onboarding/barcode-edge — read the task #230 "also run the barcode
   * scanner SPA on the client's factory box" preference for a tenant. Only
   * meaningful alongside on-prem offline (the SPA rides the fat-edge box). Scoped
   * by `idEnterprise`. 404s are EXPECTED when the slice is dark OR the flag was
   * never set — both mean "not enabled", so we suppress the toast and default to
   * false.
   */
  getBarcodeEdge: (idEnterprise: number) =>
    apiClient
      .get<BarcodeEdgeState>("/api/onboarding/barcode-edge", {
        params: { idEnterprise },
        skipErrorToast: true,
      })
      .then((r) => r.data),

  /**
   * POST /api/onboarding/barcode-edge — persist the edge-barcode preference for a
   * tenant. Carries `idEnterprise` in the BODY (per the edge-api contract) with
   * the desired `enabled` state and returns the stored value. Toast suppressed so
   * the card owns failure handling (optimistic roll-back + a single toast).
   */
  setBarcodeEdge: (idEnterprise: number, enabled: boolean) =>
    apiClient
      .post<BarcodeEdgeState>(
        "/api/onboarding/barcode-edge",
        { idEnterprise, enabled },
        { skipErrorToast: true },
      )
      .then((r) => r.data),
};
