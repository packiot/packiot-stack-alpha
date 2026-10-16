import { apiClient } from "@/lib/api-client";
import type { Enterprise } from "@/types";
import type { EnterpriseFormValues } from "@/schemas";
import { createCrud } from "./crud";

const crud = createCrud<Enterprise>("enterprises");

/**
 * Form → edge-api request body (CreateEnterpriseDto / EditEnterpriseDto).
 * Domain attributes are snake_case (the edge-api DTO column names); the edit id
 * `idEnterprise` is camelCase. Enterprise has no `cd_enterprise` column, so the
 * form's `code` is intentionally not sent.
 *
 * `week_begin`/`day_begin`/`week_size` are raw OPERATIONAL SECONDS (signed;
 * week_size >= 0) — sent through as-is to match the edge-api `number` DTO.
 *
 * TODO(integration): logo upload. Create/EditEnterpriseDto accept only
 * `logo_url: string` — there is no multipart/S3 upload endpoint on edge-api. A
 * newly-chosen File therefore cannot be persisted; we degrade by keeping the
 * existing logo_url (skip the field) rather than crashing. Wire an S3 upload +
 * `logo_url` return when the backend adds it (BACKEND-ALIGNMENT §4).
 */
function baseBody(v: EnterpriseFormValues): Record<string, unknown> {
  const body: Record<string, unknown> = {
    nm_enterprise: v.name,
    timezone: v.timezone,
    scrap_calc_type: v.scrap_calc_type,
    active: v.active,
    week_begin: v.week_begin, // operational seconds (signed)
    day_begin: v.day_begin, // operational seconds (signed)
    week_size: v.week_size, // week length in seconds (>= 0)
  };
  if (typeof v.logo === "string") body.logo_url = v.logo;
  return body;
}

/**
 * edge-api row → domain shape. edge-api uses the DB column `nm_enterprise`
 * (there is no `cd_enterprise`), but the domain/UI model uses `name`/`code`
 * (see baseBody, which maps the inverse on writes). Without this READ mapping
 * `e.name` is undefined and `e.name[0]` (avatar initial) throws
 * "Cannot read properties of undefined (reading '0')", white-screening the app.
 */
function fromApi(row: Enterprise): Enterprise {
  const raw = row as unknown as Record<string, unknown>;
  return {
    ...row,
    name: (raw.nm_enterprise as string) ?? row.name ?? "",
    code: (raw.cd_enterprise as string) ?? row.code ?? "",
  };
}

export const enterprisesApi = {
  list: () => crud.list().then((rows) => rows.map(fromApi)),
  get: (id: number | string) => crud.get(id).then(fromApi),
  create: (v: EnterpriseFormValues) =>
    apiClient
      .post<Enterprise>("/api/enterprises/create", baseBody(v))
      .then((r) => r.data),
  update: (id: number, v: EnterpriseFormValues) =>
    apiClient
      .post<Enterprise>("/api/enterprises/edit", { idEnterprise: id, ...baseBody(v) })
      .then((r) => r.data),
};
