-- t-bispharma-menu-leak-fix — remove the cross-client "Paradas C-Pack" report leak from
-- Bispharma (enterprise 5, role operator-bispharma-staging / id_user_role=5). STAGING.
--
-- ROOT CAUSE (grounded, 2026-09-15)
-- ─────────────────────────────────
-- serving.v_menu_per_user_role builds a role's menu by exploding
-- user_roles.permissions->desktop->screen[].code and JOINing pages ON id_page — WITHOUT
-- honoring pages.list_of_enterprises. That column is vestigial PowerBI-era scope: the
-- standard product pages (Home/OEE/Downtimes/… codes 1,2,3,5,6,8,25,26,27) were remapped
-- to list_of_enterprises={3,2000003} yet are meant for every tenant, so the view
-- deliberately ignores the field. Consequence: any FOREIGN custom-report code granted to a
-- role also renders. Role 5 was seeded (onboarding copy of the CPACK operator template)
-- with {code:64} = pages.id_page 64 "Paradas C-Pack" (a CPACK PowerBI report, dataset
-- 15580032-…, reportId 72d438d6-…, scoped list_of_enterprises={3,2000003}). So a logged-in
-- Bispharma operator sees a working link to a C-Pack report = cross-client data exposure.
--
-- WHY NOT "just make the view honor list_of_enterprises": that would strip Bispharma's
-- ENTIRE standard menu (all standard pages are mis-scoped {3,2000003}). Re-scoping the
-- standard pages + hardening the view is a larger redesign that also touches CPACK's live
-- menu — flagged as follow-up, not done blind. This migration fixes the confirmed leak at
-- the data layer, principled (by page scope, not a hardcoded code) so template drift can't
-- reintroduce a foreign report for role 5.
--
-- Systemic scan (2026-09-15): role 5 is the ONLY role in the DB granting a /report page not
-- scoped to its own enterprise — so this fully closes the exposure.
--
-- Reversible: role 5 permissions backed up to ops._bkp_user_roles_perms_menuleak.

BEGIN;

-- Backup pre-mutation permissions for verbatim rollback.
CREATE TABLE IF NOT EXISTS ops._bkp_user_roles_perms_menuleak AS
  SELECT id_user_role, permissions, now() AS backed_up_at
  FROM identity.user_roles WHERE id_user_role = 5;

-- Strip from role 5 any screen grant whose page is a /report custom report NOT scoped to
-- enterprise 5 (i.e. a foreign tenant's report). Keeps all standard pages and any future
-- report legitimately scoped to include 5.
UPDATE identity.user_roles ur
SET permissions = jsonb_set(
      ur.permissions, '{desktop,screen}',
      COALESCE((
        SELECT jsonb_agg(elem ORDER BY (elem->>'code')::int)
          FROM jsonb_array_elements(ur.permissions->'desktop'->'screen') elem
         WHERE NOT EXISTS (
           SELECT 1 FROM config.pages p
            WHERE p.id_page = (elem->>'code')::int
              AND p.page_info->>'URL' = '/report'
              AND NOT (p.list_of_enterprises @> ARRAY[ur.id_enterprise])
         )
      ), '[]'::jsonb)
    )
WHERE ur.id_user_role = 5;

COMMIT;

-- Verification (expect: 0 rows = no foreign /report grant remains for role 5):
--   SELECT (s.screen->>'code')::int AS code, p.page_info->>'name'
--     FROM identity.user_roles ur
--     CROSS JOIN LATERAL jsonb_array_elements((ur.permissions->'desktop')->'screen') s(screen)
--     JOIN config.pages p ON p.id_page=(s.screen->>'code')::int
--    WHERE ur.id_user_role=5 AND p.page_info->>'URL'='/report'
--      AND NOT (p.list_of_enterprises @> ARRAY[ur.id_enterprise]);
