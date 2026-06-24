# db/init — local-dev Postgres bootstrap schema

These SQL files are mounted into `postgres:/docker-entrypoint-initdb.d/` by
`compose.development.yml` only. They run **once**, on the first boot of the
local-dev Postgres container, to create the core OEE schema + seed enough
rows to exercise the pipeline end-to-end.

| File | Purpose |
|---|---|
| `00-schema.sql` | Core hierarchy + production tables (enterprises, sites, areas, equipments, production_orders, equipment_values, packml_register, …). Aligned with the prod schema dumped in `edge-api/schema.sql` — column names + types match. Omits prod-only aggregation tables (`agg_*`) and `_quality` signal columns. |
| `01-seed.sql` | Demo enterprise (id=1), sample machines, packml topics, and downtime reasons. Enough to boot edge-nodered with `ID_ENTERPRISE=1` and see data flow. |

## Where these came from (history)

Originally lived at `oeecloud-node-red/db/` inside the `oeecloud-node-red`
submodule. When that submodule was decommissioned (2026-06-24, replaced by
`services/oeecloud-worker`), the schema files were lifted into the parent
repo so local dev keeps working without the dead submodule.

The staging + prod Postgres instances bootstrap differently — staging uses
`db/Dockerfile` + `db/docker-entrypoint-initdb.d/00-init-extensions.sh`
(extensions only, real schema arrives via migrations from edge-node-red);
prod is a separate DB EC2 with its own schema lineage. These `db/init/`
files are **dev-only**.

## Maintenance

If the prod schema picks up a new core table that local dev needs, add it
to `00-schema.sql`. For one-off seed rows, prefer extending `01-seed.sql`
over creating a new file (init order is alphabetical — keep the prefix
discipline if you do split).
