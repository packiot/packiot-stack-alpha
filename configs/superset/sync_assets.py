"""sync_assets.py — make EVERY dataset and chart asset authoritative: the YAML always wins.

WHY (two stacked causes, found 2026-10-07):
1. `superset import-dashboards` passes overwrite=True only to the DASHBOARD row. Superset 4.1.1
(commands/dashboard/importers/v1/__init__.py `_import`) imports each dependency with a hardcoded
`overwrite=False`, so a dataset or chart that already exists is never updated again. The bundle was
create-once: on 2026-10-07 31 of 55 charts and 1 of 13 datasets on staging differed from their YAML
(7 charts had a different viz_type since August; #1576's live_status columns/metric never landed), and
assets no dashboard references (historian_union/ev_all) were never imported at all. Same class of bug
sync_databases.py fixes for databases.
2. Even the dashboard overwrite never happened: superset-init imports as the guest-token minter, and
   bootstrap_guest_role.py scopes it down to GuestTokenMinter (no can_write) whenever another Admin
   exists. For a user without write permission the importers silently return the existing object.

WHAT: as an Admin user, run Superset's own ImportDatasetsCommand, ImportChartsCommand and
ImportDashboardsCommand over the staged bundle
(/tmp/assets, passwords already injected by import_bundle.py) with overwrite=True. The importers keep
their uuid matching, column/metric sync and dataset-id remapping; we only change the overwrite flag and
the scope (every asset, dashboard-referenced or not) and the identity. Databases are NOT touched here (the importers
import them with overwrite=False; sync_databases.py owns them). UI edits to a dataset, chart or dashboard
that has a YAML are overwritten on every boot: that is the point.

Then it VERIFIES against what Superset makes of each YAML: dataset columns + metrics; chart viz_type +
params after the importer's own transforms (filter_chart_annotations, migrate_chart: e.g. legacy
dist_bar becomes echarts_timeseries_bar on import); dashboard title + chart membership. Any difference
exits 1 (superset-init uses `set -e`), so drift and silent permission no-ops are loud.
Runs in superset-init after sync_databases.py and before normalize_query_context.py (which rebuilds
the charts' query_context against the final dataset ids).

Identity: SUPERSET_ASSET_SYNC_USER, else SUPERSET_ADMIN_USER, else the oldest active user holding the
Admin role. It must hold Admin (overwrite needs can_write on every asset type).
"""

import copy
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

import yaml

STAGED = pathlib.Path("/tmp/assets")
# Chart params Superset owns at runtime, not the asset: the datasource id is remapped from the uuid on
# import, and dashboard membership/slice id are assigned by the target.
RUNTIME_PARAMS = {"datasource", "dashboards", "slice_id"}


def _contents(kinds: tuple[str, ...], model_type: str) -> dict[str, str]:
    """The importer's input: {path relative to the bundle root: yaml text} + a metadata.yaml whose
    `type` matches the command (the dashboard bundle's metadata says Dashboard and would be rejected)."""
    out = {
        "metadata.yaml": yaml.safe_dump({
            "version": "1.0.0",
            "type": model_type,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }),
    }
    for kind in kinds:
        for f in sorted(STAGED.joinpath(kind).rglob("*.yaml")):
            out[str(f.relative_to(STAGED))] = f.read_text()
    return out


def _verify() -> list[str]:
    from superset.commands.chart.importers.v1.utils import filter_chart_annotations, migrate_chart
    from superset.connectors.sqla.models import SqlaTable
    from superset.extensions import db
    from superset.models.dashboard import Dashboard
    from superset.models.slice import Slice

    drift = []
    for f in sorted(STAGED.joinpath("datasets").rglob("*.yaml")):
        y = yaml.safe_load(f.read_text())
        t = db.session.query(SqlaTable).filter(SqlaTable.uuid == y["uuid"]).one_or_none()
        if t is None:
            drift.append(f"dataset {y['table_name']}: missing")
            continue
        want_c = {c["column_name"] for c in y.get("columns") or []}
        have_c = {c.column_name for c in t.columns}
        want_m = {m["metric_name"]: m["expression"] for m in y.get("metrics") or []}
        have_m = {m.metric_name: m.expression for m in t.metrics}
        if want_c != have_c or want_m != have_m:
            drift.append(f"dataset {y['table_name']}: columns +{sorted(want_c - have_c)} -{sorted(have_c - want_c)}, "
                         f"metrics differ {sorted(k for k in want_m.keys() | have_m.keys() if want_m.get(k) != have_m.get(k))}")
    for f in sorted(STAGED.joinpath("charts").rglob("*.yaml")):
        y = yaml.safe_load(f.read_text())
        s = db.session.query(Slice).filter(Slice.uuid == y["uuid"]).one_or_none()
        if s is None:
            drift.append(f"chart {y['slice_name']}: missing")
            continue
        # what import_chart stores for this YAML (commands/chart/importers/v1/utils.py)
        cfg = copy.deepcopy(y)
        filter_chart_annotations(cfg)
        cfg["params"] = json.dumps(cfg["params"])
        cfg = migrate_chart(cfg)
        want = json.loads(cfg["params"])
        have = json.loads(s.params or "{}")
        keys = sorted(k for k in want if k not in RUNTIME_PARAMS and have.get(k) != want[k])
        if keys or s.viz_type != cfg["viz_type"]:
            drift.append(f"chart {y['slice_name']}: viz_type {s.viz_type} (want {cfg['viz_type']}), params differ {keys}")
    for f in sorted(STAGED.joinpath("dashboards").rglob("*.yaml")):
        y = yaml.safe_load(f.read_text())
        d = db.session.query(Dashboard).filter(Dashboard.uuid == y["uuid"]).one_or_none()
        if d is None:
            drift.append(f"dashboard {y['dashboard_title']}: missing")
            continue
        want_charts = {v["meta"]["uuid"] for v in (y.get("position") or {}).values()
                       if isinstance(v, dict) and v.get("type") == "CHART" and v.get("meta", {}).get("uuid")}
        have_charts = {str(c.uuid) for c in d.slices}
        if d.dashboard_title != y["dashboard_title"] or want_charts != have_charts:
            drift.append(f"dashboard {y['dashboard_title']}: title {d.dashboard_title!r}, charts "
                         f"+{len(want_charts - have_charts)} -{len(have_charts - want_charts)}")
    return drift


def _sync_user(sm):
    """The Admin identity the importers run as (see module docstring)."""
    for var in ("SUPERSET_ASSET_SYNC_USER", "SUPERSET_ADMIN_USER"):
        name = os.environ.get(var, "").strip()
        if name:
            return sm.find_user(username=name), f"{var}={name}"
    admins = sorted((u for u in sm.get_all_users() if u.active and any(r.name == "Admin" for r in u.roles)),
                    key=lambda u: u.id)
    return (admins[0], f"oldest active Admin ({admins[0].username})") if admins else (None, "no active Admin user")


def main() -> int:
    from flask import g
    from superset.app import create_app

    app = create_app()
    with app.app_context():
        from superset import security_manager
        from superset.commands.chart.importers.v1 import ImportChartsCommand
        from superset.commands.dashboard.importers.v1 import ImportDashboardsCommand
        from superset.commands.dataset.importers.v1 import ImportDatasetsCommand

        user, how = _sync_user(security_manager)
        if user is None or not any(r.name == "Admin" for r in user.roles):
            print(f"[sync_assets] FAIL: need an Admin user to overwrite assets ({how})", file=sys.stderr)
            return 1
        g.user = user  # what `import-dashboards -u` does (cli/importexport.py)
        print(f"[sync_assets] importing as {how}")

        if not STAGED.joinpath("datasets").is_dir():
            print(f"[sync_assets] {STAGED}/datasets missing — run import_bundle.py first", file=sys.stderr)
            return 1
        # Datasets first (charts resolve their dataset by uuid), each with the databases they reference.
        for label, command, kinds, model_type in (
            ("datasets", ImportDatasetsCommand, ("databases", "datasets"), "SqlaTable"),
            ("charts", ImportChartsCommand, ("databases", "datasets", "charts"), "Slice"),
            ("dashboards", ImportDashboardsCommand, ("databases", "datasets", "charts", "dashboards"), "Dashboard"),
        ):
            contents = _contents(kinds, model_type)
            n = sum(1 for k in contents if k.startswith(f"{label}/"))
            command(contents, overwrite=True).run()
            print(f"[sync_assets] {label}: {n} asset(s) applied with overwrite")

        drift = _verify()
        for d in drift:
            print(f"[sync_assets] DRIFT {d}", file=sys.stderr)
        if drift:
            print(f"[sync_assets] FAIL: {len(drift)} asset(s) still differ from their YAML", file=sys.stderr)
            return 1
        print("[sync_assets] verified: every dataset, chart and dashboard matches its YAML")
    return 0


if __name__ == "__main__":
    sys.exit(main())
