import { z } from "zod";

/* ─────────────── shared ─────────────── */

// week_begin / day_begin / week_size are raw OPERATIONAL SECONDS (the edge-api
// DTO column semantics): signed offsets from the operational week start (may be
// negative, e.g. CPACK -3000 = Sunday 23:10), and week_size = week length in
// seconds (>= 0). They are NOT {weekday,hour} — modelling them as WeekPoint and
// sending `.weekday` silently corrupted the stored anchor (was TODO(DRIFT-2)).
const weekFields = {
  week_begin: z.coerce.number().int(),
  day_begin: z.coerce.number().int(),
  week_size: z.coerce.number().int().min(0, "≥ 0"),
};

const nonNeg = z.coerce.number().min(0, "≥ 0");
const emptyToUndef = (v: unknown) =>
  v === "" || v == null || (typeof v === "number" && Number.isNaN(v)) ? undefined : v;

/* ─────────────── enterprise ─────────────── */

export const enterpriseSchema = z.object({
  name: z.string().trim().min(1, "Enterprise name is required"),
  // NOTE: enterprises has no `cd_enterprise` column — the phantom `code` INPUT
  // was removed (it silently discarded: baseBody never sent it, fromApi always
  // yielded ""). The domain `Enterprise.code` field + fromApi mapping are kept
  // because lib/descriptor-compose reads them as a topic-prefix fallback.
  timezone: z.string().min(1),
  scrap_calc_type: z.coerce.number().int().min(0).max(2),
  active: z.boolean().default(true),
  // File on new upload, string (existing S3 url) on edit, or none
  logo: z.union([z.instanceof(File), z.string(), z.null()]).optional(),
  ...weekFields,
});
export type EnterpriseFormValues = z.infer<typeof enterpriseSchema>;

/* ─────────────── site ─────────────── */

export const siteSchema = z.object({
  name: z.string().trim().min(1, "Site name is required"),
  // NOTE: no `cd_site` column — phantom `code` input removed (see enterprise).
  timezone: z.string().min(1),
  language_tag: z.string().min(1, "Select a language pack"),
  active: z.boolean().default(true),
  ...weekFields,
});
export type SiteFormValues = z.infer<typeof siteSchema>;

/* ─────────────── area ─────────────── */

export const areaSchema = z.object({
  name: z.string().trim().min(1, "Area name is required"),
  // NOTE: no `cd_area` column — phantom `code` input removed (see enterprise).
  id_site: z.coerce.number().int().positive("Select a site"),
  active: z.boolean().default(true),
  ...weekFields,
});
export type AreaFormValues = z.infer<typeof areaSchema>;

/* ─────────────── equipment ─────────────── */

export const equipmentSchema = z
  .object({
    id_enterprise: z.coerce.number().int().positive(),
    id_site: z.coerce.number().int().positive("Select a site"),
    id_area: z.coerce.number().int().positive("Select an area"),
    tp_equipment: z.union([z.literal(1), z.literal(2), z.literal(3)]),
    nm_equipment: z.string().trim().min(1, "Equipment name is required"),
    cd_equipment: z.string().trim().min(1, "Equipment code is required"),
    stop_threshold_time: nonNeg, // seconds (downtime vs micro-stop threshold)
    production_speed: nonNeg, // ideal speed, units/min
    ideal_speed: z.preprocess(emptyToUndef, nonNeg.optional()),
    minimum_performance_threshold: nonNeg,
    minimum_ideal_performance_threshold: nonNeg,
    require_downtime_reason: z.boolean().default(false),
    event_should_be_displayed: z.boolean().default(true),
    status_type: z.coerce.number().int(), // event trigger type: 0 instant, 5 5-min avg/CPAC, 1 rare
    net_production_type: z.coerce.number().int(), // 0 sensors, 1 scanned boxes
    // Removed VESTIGIAL inputs (columns kept, no live reader in the new stack):
    // speed_calculated_by_packiot, event_generated_by_packiot,
    // use_label_net_production, id_plc — see api/equipment.ts.
    // type-specific
    overview_version: z.string().optional(),
    id_parentequipment: z.preprocess(emptyToUndef, z.coerce.number().int().optional()),
    id_equipment_status_mirror: z.preprocess(emptyToUndef, z.coerce.number().int().optional()),
  })
  .superRefine((val, ctx) => {
    if (val.tp_equipment === 3 && !val.overview_version) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["overview_version"], message: "Select an overview version" });
    }
    if (val.tp_equipment === 1 && !val.id_parentequipment) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["id_parentequipment"], message: "Select the parent line/sector" });
    }
    if (val.tp_equipment === 2 && !val.id_equipment_status_mirror) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["id_equipment_status_mirror"], message: "Select the mirrored machine" });
    }
  });
export type EquipmentFormValues = z.infer<typeof equipmentSchema>;

/* ─────────────── packml register ─────────────── */

// Counter-role picker: 0 = "— none —" (unset), any positive id names the source
// machine. Optional so a role can be left blank or cleared.
const counterRole = z.coerce.number().int().nonnegative().default(0);

export const packmlRegisterSchema = z.object({
  id_site: z.coerce.number().int().positive("Select a site"),
  id_area: z.coerce.number().int().positive("Select an area"),
  id_equipment: z.coerce.number().int().positive("Select an equipment"),
  id_infeedcounter: counterRole,
  id_outfeedcounter: counterRole,
});
export type PackmlRegisterFormValues = z.infer<typeof packmlRegisterSchema>;

export const editPackmlRegisterSchema = z.object({
  active: z.boolean(),
  packml_topic: z.string().min(1, "Topic can't be empty"),
  id_equipment: z.coerce.number().int().positive("Select an equipment"),
  id_infeedcounter: counterRole,
  id_outfeedcounter: counterRole,
});
export type EditPackmlRegisterFormValues = z.infer<typeof editPackmlRegisterSchema>;

/* ─────────────── shift ─────────────── */

export const shiftDaySchema = z.object({
  day_number: z.coerce.number().int().min(1).max(7),
  on: z.boolean(),
  start: z.string().regex(/^\d{2}:\d{2}$/),
  end: z.string().regex(/^\d{2}:\d{2}$/),
});

export const shiftSchema = z
  .object({
    cd_shift: z.string().trim().min(1, "Shift name/code is required"),
    sequence_position: z.coerce.number().int().min(1),
    id_site: z.preprocess(emptyToUndef, z.coerce.number().int().optional()),
    id_area: z.preprocess(emptyToUndef, z.coerce.number().int().optional()),
    active: z.boolean().default(true),
    days: z.array(shiftDaySchema).length(7),
  })
  .superRefine((v, ctx) => {
    if (!v.days.some((d) => d.on)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["days"], message: "Enable at least one day" });
    }
  });
export type ShiftFormValues = z.infer<typeof shiftSchema>;

/* ─────────────── user ─────────────── */

export const userSchema = z.object({
  name: z.string().trim().min(1, "Name is required"),
  email: z.string().trim().email("Enter a valid email"),
  // FK → user_roles.id_user_role (replaces the old free-text `role`).
  idUserRole: z.coerce.number().int().positive("Select a role"),
  active: z.boolean().default(true),
});
export type UserFormValues = z.infer<typeof userSchema>;

/* ─────────────── user role ─────────────── */

export const userRoleSchema = z.object({
  nm_user_role: z.string().trim().min(1, "Role name is required"),
});
export type UserRoleFormValues = z.infer<typeof userRoleSchema>;

/* ─────────────── onboarding descriptor (ADR-0045 config-as-data) ─────────────── */

const aliasPairSchema = z.object({
  from: z.string().trim(),
  to: z.string().trim(),
});

const paramAliasSchema = z.object({
  from: z.string().trim(),
  to: z.string().trim(),
  applies_to: z.string().trim().optional().default(""),
});

const overrideRowSchema = z.object({
  topic: z.string(),
  id_equipment: z.coerce.number().int().optional(),
  // Carried for greenfield rows added via the machine picker so a new machine
  // can be authored into the descriptor without the raw-JSON panel. Optional —
  // existing rows never set them (their equipment entry already has them).
  id_unit: z.coerce.number().int().optional(),
  tp_equipment: z.coerce.number().int().optional(),
  value: z.coerce.number().int("Whole number").min(0, "≥ 0"),
  confidence: z.enum(["inferred", "confirmed"]),
});

/**
 * The structured, form-shaped slice of a tenant descriptor a CS engineer authors:
 * canonical prefix + conversion profile (the three alias lists) + per-member
 * count-index overrides with confidence. Everything the form does NOT surface
 * (metric_templates, agent, tee, parameter_decomposition, …) round-trips untouched
 * via mergeProfileForm — see lib/onboarding.ts.
 */
export const descriptorProfileSchema = z.object({
  tenantCode: z.string().trim().min(1, "Tenant code is required"),
  prefix: z.string().trim().min(1, "Canonical prefix is required"),
  count_index_default_mode: z.string().trim().optional().default(""),
  prefix_fixups: z.array(aliasPairSchema),
  metric_aliases: z.array(aliasPairSchema),
  parameter_aliases: z.array(paramAliasSchema),
  overrides: z.array(overrideRowSchema),
});
export type DescriptorProfileValues = z.infer<typeof descriptorProfileSchema>;

/* ─────────────── language pack ─────────────── */

/**
 * The form only validates `language_tag` (a required string). The five surface
 * blobs are opaque JSON documents attached via file-upload/paste and carried
 * outside react-hook-form, so they're modelled as optional `unknown` on the value
 * type rather than in the zod object. Retained for the /api/language-packs client
 * (the translations backfill source); the standalone Language Packs page was
 * removed in favour of the ADR-0048 Translations editor.
 */
export const languagePackSchema = z.object({
  language_tag: z.string().trim().min(1, "Language tag is required (e.g. pt-BR)"),
});
export type LanguagePackFormValues = z.infer<typeof languagePackSchema> & {
  language_pack_desktop?: unknown;
  language_pack_mobile?: unknown;
  language_pack_operator?: unknown;
  language_pack_overview?: unknown;
  language_pack_operator40?: unknown;
};

/* ─────────────── team ─────────────── */

// Scope selects use 0 for "none" (SelectField is numeric); coerced to null on save.
export const teamSchema = z.object({
  cd_team: z.string().trim().min(1, "Team name is required"),
  sequence_position: z.coerce.number().int().min(0).default(0),
  id_site: z.coerce.number().int().min(0).default(0),
  id_area: z.coerce.number().int().min(0).default(0),
  id_equipment: z.coerce.number().int().min(0).default(0),
});
export type TeamFormValues = z.infer<typeof teamSchema>;

/* ─────────────── production target ─────────────── */

export const productionTargetSchema = z.object({
  vlHour: z.coerce.number().int().min(0, "Must be ≥ 0"),
  vlDay: z.coerce.number().int().min(0, "Must be ≥ 0"),
  vlWeek: z.coerce.number().int().min(0, "Must be ≥ 0"),
  vlMonth: z.coerce.number().int().min(0, "Must be ≥ 0"),
  scrapDay: z.coerce.number().int().min(0).default(0),
});
export type ProductionTargetFormValues = z.infer<typeof productionTargetSchema>;
