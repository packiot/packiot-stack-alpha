# configs/superset/custom_sso_security_manager.py
# W2 embedded-Superset — custom security manager SKETCH (INERT until W2 go).
# Bind-mounted read-only alongside superset_config.py on PYTHONPATH; wired via
#   CUSTOM_SECURITY_MANAGER = CognitoTenantSecurityManager  (in superset_config.py)
#
# PURPOSE: Superset has no Metabase-style "login attribute" that a query filter
# reads directly. To make AUTHORING (Cognito-OIDC) accounts tenant-safe, we must
# bind each user's id_enterprise to a Superset RLS filter at login. This class
# does exactly that, using Strategy A from the spec: one Superset ROLE per tenant
# (`tenant_<id>`) carrying a literal `id_enterprise = <id>` RLS filter on the
# bi.* datasets; the user is granted [Gamma_BI, tenant_<id>].
#
# This is a DESIGN sketch — method names/paths track Superset/FAB but treat it as
# pseudocode to be hardened in the real PR (imports, session handling, the RLS/
# dataset ORM models move between Superset versions).

import logging

from superset.security import SupersetSecurityManager

log = logging.getLogger(__name__)

# The Cognito claim that carries the tenant. Prefer a dedicated custom attribute
# (`custom:id_enterprise`) minted into the token by a Cognito pre-token-generation
# Lambda; fall back to a group convention `tenant-<id>` if that is what exists.
TENANT_CLAIM = "custom:id_enterprise"

# The bi.* datasets an authoring RLS filter must cover (must match the Superset
# dataset names registered from the `bi` schema).
BI_DATASETS = [
    "oee_shift",
    "oee_hourly",
    "production_order_runtime",
    "downtimes",
    "equipments",
]


class CognitoTenantSecurityManager(SupersetSecurityManager):
    def oauth_user_info(self, provider, response=None):
        """Extract the identity + tenant from the Cognito OIDC userinfo/ID token."""
        if provider != "cognito":
            return super().oauth_user_info(provider, response)
        me = self.appbuilder.sm.oauth_remotes[provider].get("userInfo").json()
        return {
            "username": me["email"],
            "email": me["email"],
            "first_name": me.get("given_name", ""),
            "last_name": me.get("family_name", ""),
            # non-standard keys ride through so auth_user_oauth() → our hook can read them:
            "id_enterprise": me.get(TENANT_CLAIM),
        }

    def auth_user_oauth(self, userinfo):
        """FAB calls this after oauth_user_info; it (self-)registers the user.
        We wrap it to bind the per-tenant RLS role right after provisioning."""
        user = super().auth_user_oauth(userinfo)
        if user is None:
            return None
        id_enterprise = userinfo.get("id_enterprise")
        if not id_enterprise:
            # FAIL CLOSED: no tenant on the identity → no data. Strip data roles.
            log.warning("Cognito login for %s carried no %s — denying data access",
                        user.username, TENANT_CLAIM)
            self._set_roles(user, [self.find_role("Public")])
            return user
        self._bind_tenant(user, int(id_enterprise))
        return user

    # ── the tenant binding: ensure role + RLS filter exist, assign to the user ──
    def _bind_tenant(self, user, id_enterprise: int):
        role_name = f"tenant_{id_enterprise}"
        role = self.find_role(role_name) or self.add_role(role_name)

        # Ensure ONE RLS filter `id_enterprise = <id>` on the bi.* datasets, bound
        # to this tenant role. (RowLevelSecurityFilter is a Superset ORM model; the
        # exact import path/fields vary by version — harden in the real PR.)
        self._ensure_rls_filter(
            name=f"tenant_{id_enterprise}_isolation",
            clause=f"id_enterprise = {id_enterprise}",   # literal; id_enterprise is int → no injection surface
            role=role,
            dataset_names=BI_DATASETS,
        )

        # Grant [Gamma_BI (authoring), tenant_<id> (isolation)]. Gamma_BI is a
        # cloned Gamma restricted to the bi.* datasets (see spec §2.3).
        self._set_roles(user, [self.find_role("Gamma_BI"), role])

    # helpers _ensure_rls_filter / _set_roles omitted — thin wrappers over
    # self.get_session + the RowLevelSecurityFilter / ab_user_role ORM. See spec.

    # ── HARDENING: deny authors native SQL against the analytics DB ──────────────
    # RLS filters rewrite DATASET queries (charts / Explore). A user with SQL Lab
    # AND raw access to the analytics database could write arbitrary SQL that
    # BYPASSES the dataset-scoped RLS entirely (SELECT straight off a base table).
    # So the authoring role must be BOTH RLS-sandboxed AND denied native SQL:
    #   * Gamma_BI is a cloned Gamma with the SQL-Lab perms STRIPPED
    #     (can_sql_json / can_csv / menu_access on "SQL Lab" removed), so authors
    #     get Explore + saved charts on the bi.* datasets but no SQL Lab; and
    #   * the analytics "database" is registered with expose_in_sqllab=False +
    #     allow_dml=False (belt-and-suspenders — even an over-granted role sees no
    #     SQL-Lab entry for it).
    # _harden_gamma_bi() is idempotent and called once from the security manager
    # bootstrap (or run as a post-`superset init` step in the real PR).
    def _harden_gamma_bi(self):
        role = self.find_role("Gamma_BI")
        if role is None:
            return
        DENY = {"can_sql_json", "can_csv", "can_sqllab", "menu_access"}
        DENY_VIEWS = {"SQL Lab", "SQL Editor", "Query Search"}
        role.permissions = [
            p for p in role.permissions
            if not (
                (p.permission and p.permission.name in DENY)
                and (p.view_menu and p.view_menu.name in DENY_VIEWS)
            )
            and not (p.permission and p.permission.name in {"can_sql_json", "can_csv"})
        ]
        self.get_session.merge(role)
        self.get_session.commit()


# ── ALTERNATIVE (Strategy B, see 03-authoring-rls-mapping.optional.sql) ────────
# Instead of a role-per-tenant, create ONE global RLS filter in the UI with clause:
#     id_enterprise IN (SELECT id_enterprise FROM bi.user_tenant
#                        WHERE username = '{{ current_username() }}')
# and, in _bind_tenant above, upsert (user.username → id_enterprise) into
# bi.user_tenant instead of minting a per-tenant role. One filter serves every
# tenant; the cost is maintaining that mapping table. Pick ONE strategy.
