import { apiClient } from "@/lib/api-client";
import type { Equipment } from "@/types";
import type { EquipmentFormValues } from "@/schemas";

/** overview_events_type is derived from the equipment type: line=3, sector=2, machine=1. */
function overviewEventsType(tp: number): number {
  return tp === 3 ? 3 : tp === 2 ? 2 : 1;
}

/**
 * Form → edge-api request body (Create/EditEquipmentDto). Per-field casing
 * matches the DTO exactly: request-level FK ids are camelCase (`idEnterprise`,
 * `idSite`, `idArea`), every domain attribute is snake_case (`tp_equipment`,
 * `nm_equipment`, `stop_threshold_time`, `overview_events_type`, …), and the
 * column-name FKs stay snake_case too (`id_parentequipment`,
 * `id_equipment_status_mirror`, `id_counter_status`). No client-side unit
 * scaling: stop threshold in seconds, speeds in units/min, thresholds as
 * whole numbers. overview_events_type is derived.
 *
 * VESTIGIAL columns are intentionally NOT sent: speed_calculated_by_packiot,
 * event_generated_by_packiot, use_label_net_production, id_plc — persisted DB
 * columns with no live reader in the new stack (edge-transformer / oeecloud-
 * worker / refdata / F3 OEE views). The edit DAO only SETs keys present in the
 * body, so omitting them preserves any existing value; create inserts NULL.
 *
 * TODO(integration): lead_machine (PackML 30702) is NOT on Create/EditEquipmentDto
 * — edge-api computes the line lead server-side, so CS Admin cannot set it here.
 * A sector still sends id_equipment_status_mirror. Wire an explicit lead_machine
 * field if/when the DTO adds one (BACKEND-ALIGNMENT §6).
 */
export function equipmentFormToApi(v: EquipmentFormValues): Record<string, unknown> {
  const body: Record<string, unknown> = {
    idEnterprise: v.id_enterprise,
    idSite: v.id_site,
    idArea: v.id_area,
    tp_equipment: v.tp_equipment,
    nm_equipment: v.nm_equipment,
    cd_equipment: v.cd_equipment,
    stop_threshold_time: v.stop_threshold_time,
    production_speed: v.production_speed,
    ideal_speed: v.ideal_speed ?? null,
    minimum_performance_threshold: v.minimum_performance_threshold,
    minimum_ideal_performance_threshold: v.minimum_ideal_performance_threshold,
    require_downtime_reason: v.require_downtime_reason,
    event_should_be_displayed: v.event_should_be_displayed,
    status_type: v.status_type,
    net_production_type: v.net_production_type,
    overview_events_type: overviewEventsType(v.tp_equipment),
  };
  if (v.tp_equipment === 3) {
    // Send as a JSON STRING, not a JS array: edge-api binds this value straight
    // into the `overview_version` JSONB column, and pg serializes a JS array as a
    // Postgres text[] → "column is of type jsonb but expression is of type text[]"
    // (500 on every line create). A JSON string binds as text and Postgres coerces
    // text→jsonb on assignment. fromApi still JSON-round-trips it back to an array.
    body.overview_version = v.overview_version
      ? JSON.stringify([{ version: v.overview_version }])
      : null;
  } else if (v.tp_equipment === 1) {
    body.id_parentequipment = v.id_parentequipment ?? null;
  } else if (v.tp_equipment === 2) {
    // A sector carries BOTH its parent line and its mirrored machine. Sending
    // id_parentequipment here is what actually wires the sector under its line
    // (the form picker alone did nothing without this — the sector floated at
    // the area root in the topology tree).
    body.id_parentequipment = v.id_parentequipment ?? null;
    body.id_equipment_status_mirror = v.id_equipment_status_mirror ?? null;
  }
  return body;
}

type EquipmentRow = Equipment & {
  status_type?: number;
  overview_version?: { version: string }[] | string | null;
};

/** Backend entity (snake_case DB columns) → form defaults for editing. */
export function equipmentApiToForm(e: EquipmentRow): EquipmentFormValues {
  const ov = Array.isArray(e.overview_version)
    ? e.overview_version[0]?.version
    : (e.overview_version ?? undefined);
  return {
    id_enterprise: e.id_enterprise ?? 0,
    id_site: e.id_site ?? 0,
    id_area: e.id_area ?? 0,
    tp_equipment: (e.tp_equipment ?? 3) as 1 | 2 | 3,
    nm_equipment: e.nm_equipment ?? "",
    cd_equipment: e.cd_equipment ?? "",
    stop_threshold_time: e.stop_threshold_time ?? 0,
    production_speed: e.production_speed ?? 0,
    ideal_speed: e.ideal_speed ?? undefined,
    minimum_performance_threshold: e.minimum_performance_threshold ?? 0,
    minimum_ideal_performance_threshold: e.minimum_ideal_performance_threshold ?? 0,
    require_downtime_reason: e.require_downtime_reason ?? false,
    event_should_be_displayed: e.event_should_be_displayed ?? true,
    status_type: e.status_type ?? 5,
    net_production_type: e.net_production_type ?? 0,
    overview_version: ov,
    id_parentequipment: e.id_parentequipment ?? undefined,
    id_equipment_status_mirror: e.id_equipment_status_mirror ?? undefined,
  };
}

interface ListParams {
  idEnterprise: number;
  idSite?: number;
  idArea?: number;
}

export interface MoveWarning {
  code: "cross-site-shift-discontinuity" | "destination-area-no-shifts" | "role-machine-outside-move-set";
  message: string;
  details?: unknown;
}

export interface MoveTopicDiff {
  id_packml_register: number;
  id_equipment: number;
  old_topic: string;
  new_topic: string;
  old_id_site: number | null;
  new_id_site: number | null;
  old_id_area: number | null;
  new_id_area: number | null;
  changed: boolean;
}

export interface MoveResult {
  movedEquipmentIds: number[];
  movedEquipments: Equipment[];
  topicDiff: MoveTopicDiff[];
  warnings: MoveWarning[];
  from: { idSite: number; idArea: number };
  to: { idSite: number; idArea: number };
}

/** edge-api verb-in-path; ids in body (delete carries only idEquipment, tenant from ?idEnterprise=). */
export const equipmentApi = {
  list: (params: ListParams) =>
    apiClient.get<Equipment[]>("/api/equipments", { params }).then((r) => r.data),
  create: (v: EquipmentFormValues) =>
    apiClient.post("/api/equipments/create", equipmentFormToApi(v)).then((r) => r.data),
  update: (id_equipment: number, v: EquipmentFormValues) =>
    apiClient
      .post("/api/equipments/edit", { idEquipment: id_equipment, ...equipmentFormToApi(v) })
      .then((r) => r.data),
  remove: (id_equipment: number) =>
    apiClient.post("/api/equipments/delete", { idEquipment: id_equipment }).then((r) => r.data),
  /**
   * Targeted partial update used by the Line configuration editor. edge-api's
   * EditEquipmentDto only SETs the columns present in the body (the required FK
   * ids + name are re-sent unchanged from `row` to satisfy @IsNotEmpty and avoid
   * mutating them), so `patch` may carry just id_parentequipment / position /
   * lead_machine / gross_machine / scrap_machine. Send `null` to clear a role.
   */
  patch: (row: Equipment, patch: Record<string, unknown>) =>
    apiClient
      .post("/api/equipments/edit", {
        idEquipment: row.id_equipment,
        idEnterprise: row.id_enterprise,
        idSite: row.id_site,
        idArea: row.id_area,
        tp_equipment: row.tp_equipment,
        nm_equipment: row.nm_equipment,
        ...patch,
      })
      .then((r) => r.data),
  /**
   * Dedicated, transactional line-move (Cap-2) — NOT the generic edit above.
   * Moves `id_equipment` and every descendant to the destination site/area,
   * hard-blocks (409) on a running production order in the move-set, and
   * recomputes every dependent packml_register topic server-side. Returns the
   * topic diff + non-blocking warnings in the SAME response (no separate
   * dry-run endpoint — the caller must confirm before calling this).
   */
  move: (id_equipment: number, idSite: number, idArea: number) =>
    apiClient
      .post<MoveResult>(`/api/equipments/${id_equipment}/move`, { idSite, idArea })
      .then((r) => r.data),
};
