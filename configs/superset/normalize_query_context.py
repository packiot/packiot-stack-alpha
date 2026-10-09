# configs/superset/normalize_query_context.py
# ─────────────────────────────────────────────────────────────────────────────
# Repair each imported chart's `query_context`, run by superset-init AFTER
# `superset import-dashboards` (the charts + datasets must exist first).
#
# WHY THIS EXISTS
# ───────────────
# `superset import-dashboards` reliably imports a chart's `params` (form_data), but
# it does NOT round-trip the chart's `query_context`: that blob embeds a NUMERIC
# `datasource.id`, and the importer remaps datasets by UUID, not by the numeric id
# baked into query_context. When the baked id does not match the id the dataset
# landed on in THIS metadata DB, Superset drops the query_context on import — so
# `slices.query_context` ends up NULL for most charts.
#
# A NULL query_context is invisible on the dashboard render path (the React client
# rebuilds a query context from form_data and POSTs it), but it hard-fails every
# consumer that reads the STORED context:
#   * GET /api/v1/chart/<id>/data/   → 400 "Chart has no query context saved."
#   * CSV / Excel export, Alerts & Reports (screenshot/CSV), and any programmatic
#     chart-data pull all go through that stored-context path.
#
# THE FIX
# ───────
# The asset YAMLs (the source of truth, mounted at $SUPERSET_ASSETS_DIR) DO carry a
# complete query_context — only its env-specific `datasource.id` is stale. So for
# every chart YAML we:
#   1. resolve the dataset by its stable `dataset_uuid` → the LIVE numeric id in
#      THIS metadata DB (instance-agnostic — no hardcoded ids), and
#   2. rewrite query_context.datasource.id + form_data.datasource to that id,
#   3. persist it onto the Slice.
#
# Idempotent (re-running rewrites to the same resolved ids) and env-portable (ids
# are resolved live, never committed). Mounted read-only at
# /app/pythonpath/normalize_query_context.py.

import json
import os
import pathlib
import sys

import yaml

from superset.app import create_app

ASSETS_DIR = pathlib.Path(os.environ.get("SUPERSET_ASSETS_DIR", "/app/pythonpath/assets"))


def main() -> int:
    charts_dir = ASSETS_DIR / "charts"
    if not charts_dir.is_dir():
        print(f"[normalize_qctx] charts dir not found: {charts_dir}", file=sys.stderr)
        return 1

    app = create_app()
    with app.app_context():
        from superset import db  # noqa: WPS433 (import inside app context)
        from superset.connectors.sqla.models import SqlaTable
        from superset.models.slice import Slice

        # dataset_uuid -> live numeric id (this metadata DB)
        ds_by_uuid = {str(t.uuid): t.id for t in db.session.query(SqlaTable).all()}
        slice_by_uuid = {str(s.uuid): s for s in db.session.query(Slice).all()}

        fixed = 0
        skipped = []
        for f in sorted(charts_dir.glob("*.yaml")):
            y = yaml.safe_load(f.read_text())
            suuid = str(y.get("uuid", ""))
            dsuuid = str(y.get("dataset_uuid", ""))
            qc_raw = y.get("query_context")
            sl = slice_by_uuid.get(suuid)
            dsid = ds_by_uuid.get(dsuuid)
            if sl is None or dsid is None or not qc_raw:
                skipped.append((f.name, sl is not None, dsid, bool(qc_raw)))
                continue

            qc = json.loads(qc_raw)
            qc.setdefault("datasource", {})["id"] = dsid
            qc["datasource"]["type"] = "table"
            fd = qc.setdefault("form_data", {})
            fd["datasource"] = f"{dsid}__table"
            fd["slice_id"] = sl.id
            qc["result_format"] = "json"
            qc["result_type"] = "full"

            sl.query_context = json.dumps(qc)
            db.session.merge(sl)
            fixed += 1

        db.session.commit()
        print(f"[normalize_qctx] repaired query_context on {fixed} charts")
        if skipped:
            print(f"[normalize_qctx] skipped {len(skipped)}: {skipped}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
