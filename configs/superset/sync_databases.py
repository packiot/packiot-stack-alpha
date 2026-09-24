"""sync_databases.py — make EVERY database asset authoritative, dashboard or not.

WHY: `superset import-dashboards` imports a database asset ONLY as a dependency of a
dashboard. A connection no dashboard uses (historian_union: its only dataset has no
chart) was therefore NEVER imported — editing its YAML changed nothing anywhere. The
live record had been hand-made (different uuid, same name) and silently pointed at
`postgres@hist-gateway/postgres`: the gateway SUPERUSER, on a database that stopped
holding the historian objects when it was renamed to packiot_historian (#274). Nobody
noticed because nothing queried it. (Found 2026-09-24, T3/T4.)

WHAT: for each staged asset in /tmp/assets/databases/*.yaml (import_bundle.py has
already injected the password), find the live Database by uuid, else by
database_name, and apply the asset's sqlalchemy_uri + the safety flags. Creates the
record when absent. Idempotent; runs in superset-init right after import-dashboards.
Never prints a URI (it carries the password).
"""

import pathlib
import sys

import yaml

STAGED = pathlib.Path("/tmp/assets/databases")
FLAGS = ("expose_in_sqllab", "allow_run_async", "allow_ctas", "allow_cvas", "allow_dml",
         "allow_file_upload", "cache_timeout")


def main() -> int:
    from superset.app import create_app

    app = create_app()
    with app.app_context():
        from superset.extensions import db
        from superset.models.core import Database

        if not STAGED.is_dir():
            print(f"[sync_databases] {STAGED} missing — run import_bundle.py first", file=sys.stderr)
            return 1
        for f in sorted(STAGED.glob("*.yaml")):
            spec = yaml.safe_load(f.read_text())
            name, uri, uuid = spec["database_name"], spec["sqlalchemy_uri"], spec.get("uuid")
            if "XXXXXXXXXXXX" in uri or "YYYYYYYYYYYY" in uri:
                print(f"[sync_databases] SKIP {name}: password placeholder not injected (env unset)")
                continue
            rec = None
            if uuid:
                rec = db.session.query(Database).filter(Database.uuid == uuid).one_or_none()
            if rec is None:
                rec = db.session.query(Database).filter(Database.database_name == name).one_or_none()
            created = rec is None
            if created:
                rec = Database(database_name=name)
                db.session.add(rec)
            rec.set_sqlalchemy_uri(uri)
            for k in FLAGS:
                if k in spec:
                    setattr(rec, k, spec[k])
            db.session.commit()
            user = uri.split("//", 1)[1].split(":", 1)[0]
            target = uri.rsplit("@", 1)[-1]
            print(f"[sync_databases] {'created' if created else 'synced'} {name} (id={rec.id}) -> {user}@{target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
