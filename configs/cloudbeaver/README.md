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

## Hiding the TimescaleDB extension schemas (schema object-filter)

`show-system-objects=false` hides `pg_catalog`/`information_schema`/`pg_temp_*` but does
NOT classify the 7 TimescaleDB extension schemas (`_timescaledb_*`,
`timescaledb_information`, `timescaledb_experimental`) as system, so they stayed visible.
There is no per-schema *allowlist*, but a per-connection **object filter** IS
persistable to `data-sources.json` (discovered from how CloudBeaver serializes a
filter set via the `navSetFolderFilter` GraphQL mutation):

```json
"filters": [
  {
    "id": "packiot_analytics:packiot_analytics",
    "type": "org.jkiss.dbeaver.ext.postgresql.model.PostgreSchema",
    "enabled": true,
    "exclude": ["_timescaledb%", "timescaledb%"]
  }
]
```

- `id` = `<database>:<catalog>` (postgres: db name twice); `type` = the PostgreSchema
  model class so the filter matches schema objects; `exclude` uses **SQL LIKE** masks
  (`%`, not glob `*` — glob silently no-ops).
- Applied only to `packiot-analytics-ro` (that's where the TimescaleDB schemas live).
  `histdb-gateway-ro` has just `duckdb`/`live`/`public` — no extension clutter — so no
  filter is needed there.

### Proven from a FRESH boot (workspace `data-sources.json` deleted → pure seed import)

`navNodeChildren` on `packiot_analytics` returns exactly the 11 app schemas —
`bi, bronze, config, core, customer_reports, gold, identity, ops, public, serving,
silver` — with NO `_timescaledb*`/`timescaledb*` and NO `pg_catalog`/`information_schema`.
`histdb-gateway-ro` → `duckdb, live, public`. So the seed importer honors both the
navigator flags AND the `filters` block.
