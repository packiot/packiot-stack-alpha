/** Domain entities as stored / returned by the backend REST API. */

export type ID = number;

export type EquipmentType = 1 | 2 | 3; // 1 = Machine, 2 = Sector, 3 = Line

export interface Enterprise {
  id_enterprise: ID;
  name: string;
  code: string;
  timezone: string;
  logo_url: string | null;
  active: boolean;
  scrap_calc_type: number;
  // operational seconds; may be negative; week_size = week length in seconds
  week_begin: number;
  day_begin: number;
  week_size: number;
}

export interface Site {
  id_site: ID;
  id_enterprise: ID;
  name: string;
  code: string;
  timezone: string;
  language_tag: string;
  active: boolean;
  // operational seconds; may be negative; week_size = week length in seconds
  week_begin: number;
  day_begin: number;
  week_size: number;
}

export interface Area {
  id_area: ID;
  id_site: ID;
  name: string;
  code: string;
  active: boolean;
  // operational seconds; may be negative; week_size = week length in seconds
  week_begin: number;
  day_begin: number;
  week_size: number;
}

export interface Equipment {
  id_equipment: ID;
  id_enterprise: ID;
  id_site: ID;
  id_area: ID;
  tp_equipment: EquipmentType;
  nm_equipment: string;
  cd_equipment: string;
  /** seconds (UI collects minutes) */
  stop_threshold_time: number;
  production_speed: number;
  ideal_speed: number | null;
  /** 0..1 (UI collects percent) */
  minimum_performance_threshold: number;
  /** 0..1 (UI collects percent) */
  minimum_ideal_performance_threshold: number;
  require_downtime_reason: boolean;
  event_should_be_displayed: boolean;
  speed_calculated_by_packiot: boolean;
  event_generated_by_packiot: boolean;
  net_production_type: number;
  status_type: number;
  /**
   * Soft-delete flag (extended to `equipments` by the CS-Admin CRUD series). The
   * list endpoint returns it verbatim; the tables render it as an Active/Inactive
   * status pill. Optional/nullable: a legacy row may predate the column — treat
   * absent/null as active.
   */
  active?: boolean | null;
  id_counter_status?: number;
  use_label_net_production?: boolean;
  overview_events_type?: number;
  // type-specific
  overview_version?: string | null; // line
  id_parentequipment?: ID | null; // machine / sector — line membership
  position?: number | null; // order within parent line/sector
  id_equipment_status_mirror?: ID | null; // line lead / sector mirror
  // line counter-role sources (tp=3) — line_lead.go, gross = net + scrap
  lead_machine?: ID | null; // NET/output source + availability cadence (30702)
  gross_machine?: ID | null; // GROSS/input source
  scrap_machine?: ID | null; // SCRAP source
  // advanced / uncertain (raw columns; status_type / id_counter_status /
  // use_label_net_production are already declared above with their canonical types)
  alert?: string | null;
  performance_alert_threshold?: number | null;
  sector_infeed?: string | null;
  sector_outfeed?: string | null;
  state_status?: string | null;
  idle?: string | null;
  starved?: string | null;
  blocked?: string | null;
  state_fault?: string | null;
  id_packed_counter?: string | null;
  cd_sector?: string | null;
  overview_event_type?: string | null;
  flexible_position?: boolean | null;
  state_change_threshold_time?: number | null;
  conversion_factor?: number | null;
}

export interface ShiftHour {
  id_shift_hour: number;
  id_shift?: ID;
  day_number: number;
  day_week?: string;
  /** seconds elapsed from the operational week start */
  begin_time: number;
  end_time: number;
}

export interface Shift {
  id_shift: ID;
  id_enterprise: ID;
  cd_shift: string;
  sequence_position: number;
  id_site: ID | null;
  id_area: ID | null;
  active: boolean;
  hours?: ShiftHour[];
}

export interface AppUser {
  id_user: ID;
  id_enterprise: ID;
  name: string;
  email: string;
  /** FK → user_roles.id_user_role (the canonical role reference) */
  id_user_role?: ID;
  /** legacy free-text label; kept for display when the list backend still sends it */
  role?: string;
  /** true = console/CS user; false = a factory/service account (operator, refdata, …) */
  internal_user?: boolean;
  active: boolean;
  // Preserved-on-edit fields. edge-api's UsersDAO.edit does a FULL-ROW UPDATE
  // with hardcoded defaults (`internal_user ?? false`, `timezone ?? 'UTC'`,
  // `languages ?? 'en'`, `phone_number ?? null`), so any field the edit body
  // omits is CLOBBERED to that default — not left untouched. The Users form
  // doesn't author these, so we round-trip the values the list returned to keep
  // the edit non-destructive. Typed here so the fromApi `...row` spread carries
  // them through TypeScript, not just at runtime.
  timezone?: string | null;
  languages?: string | null;
  phone_number?: string | null;
}

export interface UserRole {
  id_user_role: ID;
  nm_user_role: string;
  id_enterprise: ID;
}

/**
 * A language pack row: a `language_tag` plus up to five optional jsonb surface
 * blobs (desktop / mobile / operator / overview / operator40). Each surface is
 * an opaque JSON document authored by CS — hence `unknown`.
 */
export interface LanguagePack {
  id_language_pack: ID;
  language_tag: string;
  language_pack_desktop?: unknown;
  language_pack_mobile?: unknown;
  language_pack_operator?: unknown;
  language_pack_overview?: unknown;
  language_pack_operator40?: unknown;
  /**
   * The list endpoint (GET /api/language-packs) returns presence booleans, not
   * the surface blobs themselves — the blobs are only fetched on GET /:id (edit).
   */
  has_desktop?: boolean;
  has_mobile?: boolean;
  has_operator?: boolean;
  has_overview?: boolean;
  has_operator40?: boolean;
}

export interface PackMlTopic {
  topic: string;
  payload: number | string;
}

export interface PackmlRegister {
  id_packml_register: number;
  packml_topic: string;
  id_enterprise: number;
  id_site: number | null;
  id_area: number | null;
  id_equipment: number | null;
  id_unit: number | null;
  active: boolean;
  // Counter-role sources (config-as-data): each names the machine whose counter
  // stream plays the infeed/gross or outfeed/net role for this topic's
  // equipment. Nullable FK to equipments.id_equipment; null = unset.
  // (id_rejectcounter was retired from packml_register on 2026-08-26 — edge-api
  // #205 — it was 100% NULL platform-wide with no reader.)
  id_infeedcounter: number | null;
  id_outfeedcounter: number | null;
}

/**
 * `teams` — a structural (topology) config row (ADR-0047 §2.1): a named group
 * scoped to an enterprise, optionally narrowed to a site/area/equipment.
 */
export interface Team {
  id_team: number;
  cd_team: string | null;
  id_enterprise: number | null;
  id_site: number | null;
  id_area: number | null;
  id_equipment: number | null;
  sequence_position: number;
}

/**
 * One `production_targets` row joined to its equipment — the OEE volume target
 * per period. Read-only shape returned by GET /api/production-targets; writes go
 * through the set-default / set-scrap endpoints.
 */
export interface ProductionTarget {
  id_equipment: number;
  id_enterprise: number;
  id_site: number | null;
  id_area: number | null;
  nm_equipment: string | null;
  tp_equipment: number | null;
  vl_hour: number;
  vl_day: number;
  vl_week: number;
  vl_month: number;
  vl_shift: number;
}
