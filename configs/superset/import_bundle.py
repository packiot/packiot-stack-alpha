# configs/superset/import_bundle.py
# ─────────────────────────────────────────────────────────────────────────────
# Build the importable Superset asset bundle (configs/superset/assets/**) into a
# single ZIP, injecting the read-only analytics DB password into the database
# asset's placeholder, ready for `superset import_dashboards -p <zip>`.
#
# WHY A SCRIPT (not an inline heredoc in compose.staging.yml): the DB password can
# contain arbitrary characters, so a str.replace() is safer than sed; and a nested
# shell heredoc inside a YAML block scalar is fragile (indentation/terminator
# rules). superset-init mounts this at /app/pythonpath/import_bundle.py and runs it
# BEFORE the import. The password comes from the environment (SUPERSET_DB_RO_PASSWORD,
# fed from Secrets Manager into .env) — it is NEVER written to git and never leaves
# the container's /tmp.
#
# Idempotent: rebuilding the ZIP every boot is cheap; the subsequent
# `superset import_dashboards` runs ImportDashboardsCommand(..., overwrite=True),
# so re-importing overwrites the same UUID-keyed entities in place (no dupes).

import os
import pathlib
import shutil
import sys
import zipfile

# Password placeholders committed in the DB assets (sqlalchemy_uri), each replaced
# at import time with the real credential from the environment. DISTINCT literals
# per asset so a shorter one can never partial-match another.
PLACEHOLDER = "XXXXXXXXXXXX"  # noqa: S105 (not a secret — the literal placeholder)

SRC = pathlib.Path(os.environ.get("SUPERSET_ASSETS_DIR", "/app/pythonpath/assets"))
STAGED = pathlib.Path("/tmp/assets")
ZIP_PATH = pathlib.Path(os.environ.get("SUPERSET_BUNDLE_ZIP", "/tmp/superset-bundle.zip"))
DB_ASSET = ("databases", "packiot_analytics.yaml")

# Per-DB-asset password injections: (asset_path, env_var, placeholder).
#   * packiot_analytics — the bi.* read-only superset_ro credential.
#   * historian_union   — the hist-gateway (pg_duckdb) HIST_GW_PASSWORD.
DB_INJECTIONS = [
    (("databases", "packiot_analytics.yaml"), "SUPERSET_DB_RO_PASSWORD", "XXXXXXXXXXXX"),
    (("databases", "historian_union.yaml"), "HIST_GW_PASSWORD", "YYYYYYYYYYYY"),
]


def main() -> int:
    if not SRC.is_dir():
        print(f"[import_bundle] assets dir not found: {SRC}", file=sys.stderr)
        return 1

    if STAGED.exists():
        shutil.rmtree(STAGED)
    shutil.copytree(SRC, STAGED)

    for asset_path, env_var, placeholder in DB_INJECTIONS:
        dbf = STAGED.joinpath(*asset_path)
        pw = os.environ.get(env_var, "")
        if not dbf.is_file():
            # An optional asset (e.g. historian_union) may not be present in every
            # bundle — skip quietly rather than fail the whole import.
            print(f"[import_bundle] note: DB asset absent, skipping: {dbf}")
            continue
        if pw:
            dbf.write_text(dbf.read_text().replace(placeholder, pw))
            print(f"[import_bundle] injected {env_var} into {asset_path[-1]}")
        else:
            print(f"[import_bundle] WARN: {env_var} unset — {asset_path[-1]} keeps "
                  "the placeholder; that connection will fail to authenticate until "
                  "it is set.", file=sys.stderr)

    # Zip with a single top-level `assets/` root (what the importer expects).
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(STAGED.rglob("*")):
            if f.is_file():
                z.write(f, pathlib.Path("assets") / f.relative_to(STAGED))
    print(f"[import_bundle] wrote {ZIP_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
