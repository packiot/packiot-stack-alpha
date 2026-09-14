# CloudBeaver staging config

Seed `data-sources.json` (mounted read-only → `/opt/cloudbeaver/seed/`, rendered into
the workspace at boot by the compose entrypoint, which seds the `@..._PASSWORD@`
placeholders from env). Both staff-browser connections are read-only.

## Focus mode (declutter)

Each connection carries per-connection navigator flags so the tree opens on the app
data, not Postgres/extension internals:

| key (data-sources.json) | value | effect |
|---|---|---|
| `show-system-objects`   | false | hides `pg_catalog`, `information_schema`, `pg_temp_*` |
| `show-utility-objects`  | false | hides driver utility objects |
| `navigator-hide-folders`| true  | drops the per-schema category folders (Tables/Views/Sequences/…) — objects show directly under the schema, killing the empty-folder noise |
| `navigator-hide-virtual`| true  | hides the virtual-model node |

**Key format is CloudBeaver-specific** (discovered from how CloudBeaver's own
serializer persists them): flat connection-level keys — `show-system-objects` has
NO prefix; the others use the `navigator-` prefix. A nested `"navigator-settings":{…}`
block is silently ignored.

### Proven (userConnections + navigator GraphQL API, staging)

After `docker restart cloudbeaver`, `query{userConnections{navigatorSettings{…}}}`
returns `showSystemObjects=false, showUtilityObjects=false, hideFolders=true,
hideVirtualModel=true` for BOTH connections. Walking the navigator tree
(`navNodeChildren`) on `packiot_analytics` shows: `pg_catalog` / `information_schema`
/ `pg_temp_*` gone; app schemas present (bronze, silver, gold, core, config, ops,
identity, serving, customer_reports, bi, public); tables render directly under each
schema (no "Tables" folder).

### Known CloudBeaver-CE limitation — extension schemas

CloudBeaver has **no per-schema allowlist** and `ConnectionConfig` exposes **no**
object/schema-filter input, so the 7 TimescaleDB extension schemas
(`_timescaledb_*`, `timescaledb_information`, `timescaledb_experimental`) cannot be
selectively hidden from the seed — `show-system-objects=false` does not classify them
as system. They remain visible; there is no codifiable fix in CE (`navSetFolderFilter`
is session-only, not persisted to `data-sources.json`).
