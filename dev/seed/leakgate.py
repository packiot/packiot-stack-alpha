#!/usr/bin/env python3
"""leakgate.py — prove the anonymized output contains no tenant names, e-mails or IPv4s (ADR-0060 D5). Stdlib only.

  leakgate.py --tokens tokens.tsv [--columns columns.tsv] data/*.csv.gz

The classification is a prediction; this is the check. Every field of every column (keep included) is scanned
for: any tenant token (case-insensitive, length >= MIN_TOKEN, same list the anonymizer scrubs with), an e-mail
address, or an IPv4 address. Any hit fails (exit 1). Output names file, column and count only, never the value,
so the gate's own log cannot leak what it found.

--columns (the extract's live inventory: schema, table, kind, column, type) skips columns whose type cannot hold
a name: integers, floats, booleans, uuids, dates/times. 543 of tenant 3's 7,011 tokens are letterless (numeric
product names), and they "occurred" inside long integer ids (check_number, id_equipment_event) by coincidence:
43 false hits on the first full seed (2026-10-07). Text columns are still scanned for every token.
"""
import argparse
import csv
import gzip
import re
import sys
from collections import Counter
from pathlib import Path

MIN_TOKEN = 4
# column types that cannot carry a name / e-mail / address (validate.py KEEP_BY_TYPE)
NAMELESS_TYPES = {
    "integer", "bigint", "smallint", "real", "double precision", "numeric", "boolean", "uuid", "oid",
    "date", "timestamp with time zone", "timestamp without time zone", "time without time zone", "interval",
}
EMAIL = re.compile(r"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}", re.I)
IPV4 = re.compile(r"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])")


def load_tokens(path):
    toks = set()
    for line in Path(path).read_text().splitlines():
        if line.strip():
            raw = line.split("\t", 1)[1].strip().lower()
            if len(raw) >= MIN_TOKEN:
                toks.add(raw)
    return sorted(toks, key=len, reverse=True)


class TokenIndex:
    """Case-insensitive "does any token occur in this string" in O(len(string)).

    The first version compiled every token into ONE alternation regex and ran it on every cell. Python's
    backtracking re tries each alternative at each position, so the full seed (7,239 tokens, 1.2M bronze rows)
    spent > 50 min in this gate and hit the job timeout. Every token is >= MIN_TOKEN chars, so index the tokens
    by their first MIN_TOKEN chars: at each position of the lowered string, one dict lookup yields the few
    candidates that can start there. Same semantics as the regex (proven in test_leakgate.py)."""

    def __init__(self, tokens):
        self.by_prefix = {}
        for t in tokens:
            self.by_prefix.setdefault(t[:MIN_TOKEN], []).append(t)

    def search(self, value):
        if not self.by_prefix:
            return False
        v = value.lower()
        get = self.by_prefix.get
        for i in range(len(v) - MIN_TOKEN + 1):
            cands = get(v[i:i + MIN_TOKEN])
            if cands and any(v.startswith(t, i) for t in cands):
                return True
        return False


def load_types(path):
    """{(table, column): type} from the extract inventory (schema \t table \t kind \t column \t type)."""
    types = {}
    if path:
        for line in Path(path).read_text().splitlines():
            if line.strip():
                s, t, _k, c, ty = line.split("\t")
                types[(f"{s}.{t}", c)] = ty
    return types


def scan(paths, tokens, out=sys.stdout, types=None):
    rx = TokenIndex(tokens) if tokens else None
    types = types or {}
    hits = Counter()
    for p in paths:
        table = Path(p).name[:-len(".csv.gz")] if Path(p).name.endswith(".csv.gz") else Path(p).name
        with gzip.open(p, "rt", newline="") as f:
            reader = csv.reader(f)
            header = next(reader, [])
            skip = [types.get((table, c)) in NAMELESS_TYPES for c in header]
            for row in reader:
                for col, v, nameless in zip(header, row, skip):
                    if nameless or not v or v == "\\N":
                        continue
                    if rx and rx.search(v):
                        hits[(Path(p).name, col, "token")] += 1
                    if EMAIL.search(v):
                        hits[(Path(p).name, col, "email")] += 1
                    if IPV4.search(v):
                        hits[(Path(p).name, col, "ipv4")] += 1
    for (f, col, kind), n in sorted(hits.items()):
        print(f"LEAK {kind:5s} {n:7d}  {f} :: {col}", file=out)
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--columns", help="live column inventory TSV: skip name-less column types")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    hits = scan(a.files, load_tokens(a.tokens), types=load_types(a.columns))
    if hits:
        print(f"FAIL: {sum(hits.values())} leak(s) in {len({k[:2] for k in hits})} column(s)")
        return 1
    print(f"OK: no tokens, e-mails or IPv4s in {len(a.files)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
