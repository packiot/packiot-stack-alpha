# front4 enterprise switcher for cs-admin / Packiot staff (BUG #18 design)

> **Status: design + safe groundwork landed.** Groundwork (front4 surfaces
> `cognito:groups` + `isCsAdmin()`) is inert and shipped. The switcher UI and the
> **refdata cross-tenant override are security-sensitive (tenant isolation) and
> gated on the review below.**

## The ask

`dev@packiot.com` (a Packiot developer / staff account) has **no way to change
which enterprise it views** in front4. Staff should be able to pick any tenant;
a normal client user must stay locked to their own.

## What already exists (so this is smaller than it looks)

- **The authority signal exists.** The only Cognito group in the staging pool is
  **`cs-admin`** ("cross-tenant onboarding"), and `dev@packiot.com` is in it. This
  is the *same* group edge-api gates cross-tenant access on
  (`EDGE_API_CS_ADMIN_GROUP`, `CsAdminGuard`). There is no separate "superadmin"
  group — **`cs-admin` IS the staff/superadmin signal.**
- **The cross-tenant pattern exists in edge-api.** For a `cs-admin` token, the
  `?idEnterprise=<n>` query path (auth.middleware) targets ANY tenant with no DB
  row — the exact mechanism used for Box Ops all along. So the **write plane
  (edgeApi) already honors a chosen enterprise** for cs-admin callers; front4 just
  isn't sending one.
- **Groundwork (DONE):** `front4/src/cognito.js` now returns `groups` from the ID
  token and exports `isCsAdmin()` / `CS_ADMIN_GROUP`. Inert — grants nothing.

## What's missing

1. **front4 switcher UI** — a tenant dropdown shown ONLY when `isCsAdmin()`; on
   pick, store the chosen `id_enterprise` (context + localStorage) and re-run the
   bootstrap (`VariablesContext.initialValues`) so all panels re-scope.
2. **Send the override on all three data clients** for cs-admin:
   - `edgeApi` (write): add `?idEnterprise=<chosen>` (edge-api already honors it).
   - `refdata` (read): send the chosen tenant — **needs backend support (below).**
   - legacy `api`: same override param where still used.
3. **refdata cross-tenant override — the security-critical piece.** Today refdata
   derives `customer_id` **server-side from the JWT** and sets the RLS GUC
   `app.tenant_id` from it (the #264 NOBYPASSRLS + `set_config('app.tenant_id',…,true)`
   fence). To let staff view another tenant, refdata must accept an override
   (header/param, e.g. `X-Enterprise-Override`) **ONLY when the token's
   `cognito:groups` includes `cs-admin`**, and set the GUC to the overridden
   tenant. Everything else (RLS FORCE, tx-local GUC, deny-on-unset) stays.

## Security review gates (MUST pass before wiring refdata)

This is a deliberate cross-tenant read for staff — get it wrong and it's a
tenant-data leak. Non-negotiables:

- **Server-verified group.** The override is honored ONLY after refdata verifies
  `cs-admin` in the *token* (never trust a client header/flag alone). A
  non-cs-admin sending `X-Enterprise-Override` is ignored (fall back to the
  token's own tenant) — fail-closed.
- **Reuse the RLS fence.** The override sets `app.tenant_id` to the chosen tenant
  inside the existing tx-local `set_config(...,true)` wrapper — it does NOT
  bypass RLS, add BYPASSRLS, or widen the role. A cs-admin viewing tenant 7 is
  still fenced to tenant 7 for that request.
- **Audit.** Log `{actingUser (cs-admin sub), overriddenEnterprise}` on every
  overridden request (mirror the edge-api Box Ops audit shift CloudTrail→UserLogs).
- **No override ⇒ own tenant.** Absent the header, behavior is byte-identical to
  today (token-derived tenant). Reversible.
- **Cross-check** against [[reference_readapi_tenant_isolation_app_layer_superuser]]
  and [[feedback_264_readapi_nobypassrls_rls_coenforcer]] — the override must be a
  co-enforcer of the SAME GUC, not a new escape hatch.

## Staged plan

| # | Step | Repo | Risk | Gate |
|---|---|---|---|---|
| G0 | surface `cognito:groups` + `isCsAdmin()` | front4 | none | **done** |
| G1 | switcher UI (cs-admin only) + store chosen enterprise + re-bootstrap | front4 | none (until backend honors it) | build |
| G2 | send `?idEnterprise=` on edgeApi/legacy for cs-admin | front4 | edge-api already honors | build |
| G3 | refdata `X-Enterprise-Override` honored ONLY for cs-admin tokens; GUC set to override; audited | refdata (read-api) | **cross-tenant read — security review** | **explicit review + go** |
| G4 | hardproof: cs-admin switches tenants (data re-scopes); a non-cs-admin's override is IGNORED (still own tenant); RLS still fences | live | — | verify both directions |

## Why not just do it

The whole platform's tenant isolation rests on `app.tenant_id` + FORCE RLS +
NOBYPASSRLS roles. A cross-tenant override is exactly the kind of change that,
done hastily, silently voids that fence. It is consistent with the existing
cs-admin cross-tenant model (edge-api already does it for writes), so it is
*legitimate* — but the refdata side (G3) gets a real review, not a rushed patch.
