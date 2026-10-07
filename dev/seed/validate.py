#!/usr/bin/env python3
"""validate.py — fail-closed check of the dev-seed manifest + column classification (ADR-0060 D4/D5).

Usage:
  dev/seed/validate.py                      # against the committed snapshot dev/seed/schema-columns.tsv
  dev/seed/validate.py --columns FILE       # against a live inventory (same TSV shape), e.g. from the seed job

Exit 0 only if:
  1. every base table (table / hypertable) in the inventory is listed in manifest.yml, and nothing stale is listed;
  2. every text/json/array column of a table whose rows are copied (mode rows|full) is classified, and nothing stale is;
  3. every other column of a copied table has a type on the keep-by-type list (a NEW type fails);
  4. `where:` clauses only use :tenant / :since and contain no statement separators or DML/DDL keywords.
Lines the parser does not understand are errors, never skipped: a lenient validator would be fail-open.
Stdlib only, so the seed job needs no dependencies.
"""
import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEXT_TYPES = {"character varying", "character", "text", "json", "jsonb", "ARRAY", "USER-DEFINED"}
KEEP_BY_TYPE = {
    "integer", "bigint", "smallint", "real", "double precision", "numeric", "boolean", "uuid", "oid",
    "date", "timestamp with time zone", "timestamp without time zone", "time without time zone",
    "interval", "tstzrange",
}
MODES = {"rows", "full", "replace", "schema_only"}
CLASSES = {"keep", "pseudonym", "scrub", "null"}
FORBIDDEN = re.compile(r";|--|\b(insert|update|delete|drop|alter|create|truncate|grant|copy|call|do)\b", re.I)

MANIFEST_LINE = re.compile(r'^  (\w+)\.(\w+): \{mode: (\w+)(?:, where: "([^"]*)")?\}(?:  # .*)?$')
CLASS_LINE = re.compile(r'^  (\w+)\.(\w+)\.(\w+): \{class: (\w+), why: "([^"]+)", scan: \[[0-9, ]*\]\}$')


def parse(path, line_re, header_keys):
    """Return matched groups per entry line; any other non-comment, non-header line is an error."""
    entries, errors = [], []
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if any(line.startswith(k) for k in header_keys):
            continue
        m = line_re.match(line)
        if not m:
            errors.append(f"{path.name}:{n}: unparseable line: {line[:100]}")
            continue
        entries.append((n, m.groups()))
    return entries, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--columns", type=Path, default=HERE / "schema-columns.tsv")
    ap.add_argument("--manifest", type=Path, default=HERE / "manifest.yml")
    ap.add_argument("--classification", type=Path, default=HERE / "classification.yml")
    a = ap.parse_args()
    errors = []

    # inventory: schema \t table \t kind \t column \t type
    cols, kinds = {}, {}
    for line in a.columns.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        s, t, k, c, ty = line.split("\t")
        kinds[(s, t)] = k
        cols.setdefault((s, t), []).append((c, ty))
    base = {st for st, k in kinds.items() if k in ("table", "hypertable")}

    entries, e = parse(a.manifest, MANIFEST_LINE, ("tenant:", "window_days:", "tables:"))
    errors += e
    modes = {}
    for n, (s, t, mode, where) in entries:
        if (s, t) in modes:
            errors.append(f"manifest:{n}: duplicate table {s}.{t}")
        modes[(s, t)] = mode
        if mode not in MODES:
            errors.append(f"manifest:{n}: {s}.{t}: unknown mode {mode!r}")
        if mode == "rows" and not where:
            errors.append(f"manifest:{n}: {s}.{t}: mode rows needs a where clause")
        if mode != "rows" and where:
            errors.append(f"manifest:{n}: {s}.{t}: where is only valid with mode rows")
        if where:
            if FORBIDDEN.search(where):
                errors.append(f"manifest:{n}: {s}.{t}: forbidden token in where: {where}")
            for p in re.findall(r":(\w+)", where):
                if p not in ("tenant", "since"):
                    errors.append(f"manifest:{n}: {s}.{t}: unknown parameter :{p}")
    for st in sorted(base - set(modes)):
        errors.append(f"manifest: table {st[0]}.{st[1]} is not listed (fail-closed: every base table needs a mode)")
    for st in sorted(set(modes) - base):
        errors.append(f"manifest: {st[0]}.{st[1]} is listed but not a base table in the inventory (stale?)")

    entries, e = parse(a.classification, CLASS_LINE, ("columns:",))
    errors += e
    classified = {}
    for n, (s, t, c, cls, _why) in entries:
        if (s, t, c) in classified:
            errors.append(f"classification:{n}: duplicate column {s}.{t}.{c}")
        classified[(s, t, c)] = cls
        if cls not in CLASSES:
            errors.append(f"classification:{n}: {s}.{t}.{c}: unknown class {cls!r}")

    needed = set()
    for st, mode in modes.items():
        if mode not in ("rows", "full") or st not in cols:
            continue
        for c, ty in cols[st]:
            if ty in TEXT_TYPES:
                needed.add((*st, c))
                if (*st, c) not in classified:
                    errors.append(f"classification: {st[0]}.{st[1]}.{c} ({ty}) is copied but not classified")
            elif ty not in KEEP_BY_TYPE:
                errors.append(f"classification: {st[0]}.{st[1]}.{c} has type {ty!r}, not on the keep-by-type list")
    for k in sorted(set(classified) - needed):
        errors.append(f"classification: {'.'.join(k)} is classified but not a copied text column (stale?)")

    if errors:
        print(f"FAIL: {len(errors)} problem(s)")
        for err in errors:
            print("  " + err)
        return 1
    copied = sum(1 for m in modes.values() if m in ("rows", "full"))
    print(f"OK: {len(modes)} tables ({copied} copied), {len(classified)} classified text columns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
