#!/usr/bin/env python3
"""anonymize.py — streaming CSV anonymizer for the dev seed (ADR-0060 D5). Stdlib only.

Reads one table's `COPY … TO STDOUT (FORMAT csv, HEADER)` on stdin, writes the anonymized CSV on stdout.

  anonymize.py --table core.equipments --tokens tokens.tsv  < raw.csv > clean.csv
  DEVSEED_HMAC_KEY must be set (never a default: a missing key must not produce guessable pseudonyms).

Per column (from classification.yml; non-text columns are `keep` by type):
  keep       copied as-is
  pseudonym  "<Prefix> <hex6>" from HMAC-SHA256(key, value) — same value → same pseudonym in every table,
             so cd_machine and cd_equipment still join, and "Line 01" reads as "Equipment 3f9a1c"
  scrub      every known sensitive token inside the string replaced (case-insensitive, longest first)
             by the same pseudonym the name column gets
  null       emitted as NULL (unquoted empty field in COPY csv)
tokens.tsv: `<category>\t<raw value>` lines (enterprise/site/area/equipment/client/product names of the tenant),
produced by the extractor; tokens shorter than MIN_TOKEN characters are not scrubbed (too generic to match safely).
"""
import argparse
import csv
import hashlib
import hmac
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIN_TOKEN = 4
CLASS_LINE = re.compile(r'^  (\w+)\.(\w+)\.(\w+): \{class: (\w+), why: "[^"]+", scan: \[[0-9, ]*\]\}$')

# Readable prefix per pseudonymized column. Columns holding the same kind of value share a prefix,
# so the same input string yields the same pseudonym everywhere.
PREFIX = {
    "nm_enterprise": "Enterprise", "nm_site": "Site", "cd_site": "Site", "nm_area": "Area", "cd_area": "Area",
    "nm_equipment": "Equipment", "cd_equipment": "EQ", "cd_machine": "EQ", "source_cd": "EQ", "target_cd": "EQ",
    "nm_client": "Client", "nm_product": "Product", "cd_product": "PRD", "nm_product_family": "Family",
    "nm_production_order": "PO", "id_order_text": "ORD", "id_order": "ORD", "id_order_quality": "ORD",
    "box_code": "BOX", "tenant_code": "TENANT", "nm_user_role": "Role",
}
# Token category (from the extractor's tokens.tsv) → the prefix its pseudonym uses inside scrubbed text.
TOKEN_PREFIX = {"enterprise": "Enterprise", "site": "Site", "area": "Area", "equipment": "Equipment",
                "equipment_code": "EQ", "client": "Client", "product": "Product", "product_family": "Family"}


def load_classes(path, table):
    schema, name = table.split(".", 1)
    out = {}
    for line in Path(path).read_text().splitlines():
        m = CLASS_LINE.match(line)
        if m and m[1] == schema and m[2] == name:
            out[m[3]] = m[4]
    return out


class Anonymizer:
    def __init__(self, key: bytes, tokens):
        if not key:
            raise SystemExit("DEVSEED_HMAC_KEY is empty: refusing to build guessable pseudonyms")
        self.key = key
        pairs = {}
        for cat, raw in tokens:
            raw = raw.strip()
            if len(raw) >= MIN_TOKEN and raw.lower() not in pairs:
                pairs[raw.lower()] = self.pseudo(raw, TOKEN_PREFIX.get(cat, "X"))
        self.pairs = pairs
        alts = sorted(pairs, key=len, reverse=True)          # longest first: "Line 10" before "Line 1"
        self.rx = re.compile("|".join(re.escape(a) for a in alts), re.I) if alts else None

    def pseudo(self, value: str, prefix: str) -> str:
        h = hmac.new(self.key, value.strip().lower().encode(), hashlib.sha256).hexdigest()
        return f"{prefix} {h[:6]}"

    def scrub(self, value: str) -> str:
        if not self.rx:
            return value
        return self.rx.sub(lambda m: self.pairs[m.group(0).lower()], value)

    def apply(self, cls: str, column: str, value):
        if value is None:
            return None
        if cls == "keep":
            return value
        if cls == "null":
            return None
        if cls == "pseudonym":
            return self.pseudo(value, PREFIX.get(column, "X")) if value != "" else value
        if cls == "scrub":
            return self.scrub(value)
        raise SystemExit(f"unknown class {cls!r} for {column}")


def run(table, classification, tokens_path, key, inp, out):
    classes = load_classes(classification, table)
    tokens = []
    if tokens_path:
        for line in Path(tokens_path).read_text().splitlines():
            if line.strip():
                cat, raw = line.split("\t", 1)
                tokens.append((cat, raw))
    anon = Anonymizer(key, tokens)
    reader = csv.reader(inp)
    header = next(reader, None)
    if header is None:   # the upstream COPY failed (its error is printed above); don't hide it behind StopIteration
        raise SystemExit(f"anonymize: no CSV header on stdin for {table} (did the COPY fail?)")
    cls_for = [classes.get(c, "keep") for c in header]   # unlisted = non-text by validate.py's contract
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(header)
    n = 0
    for row in reader:
        # NULL contract: extractor and loader both use COPY … (FORMAT csv, NULL '\N'), so NULL travels as
        # \N and an empty string stays an empty field (csv.reader alone could not tell them apart).
        vals = [None if v == "\\N" else v for v in row]
        outv = [anon.apply(cls_for[i], header[i], v) for i, v in enumerate(vals)]
        writer.writerow(["\\N" if v is None else v for v in outv])
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", required=True)
    ap.add_argument("--classification", default=str(HERE / "classification.yml"))
    ap.add_argument("--tokens")
    a = ap.parse_args()
    key = os.environ.get("DEVSEED_HMAC_KEY", "").encode()
    n = run(a.table, a.classification, a.tokens, key, sys.stdin, sys.stdout)
    print(f"{a.table}: {n} rows", file=sys.stderr)


if __name__ == "__main__":
    main()
