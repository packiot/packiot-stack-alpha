#!/usr/bin/env python3
"""leakgate.py — prove the anonymized output contains no tenant names, e-mails or IPv4s (ADR-0060 D5). Stdlib only.

  leakgate.py --tokens tokens.tsv data/*.csv.gz

The classification is a prediction; this is the check. Every field of every column (keep included) is scanned
for: any tenant token (case-insensitive, length >= MIN_TOKEN, same list the anonymizer scrubs with), an e-mail
address, or an IPv4 address. Any hit fails (exit 1). Output names file, column and count only, never the value,
so the gate's own log cannot leak what it found.
"""
import argparse
import csv
import gzip
import re
import sys
from collections import Counter
from pathlib import Path

MIN_TOKEN = 4
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


def scan(paths, tokens, out=sys.stdout):
    rx = re.compile("|".join(re.escape(t) for t in tokens), re.I) if tokens else None
    hits = Counter()
    for p in paths:
        with gzip.open(p, "rt", newline="") as f:
            reader = csv.reader(f)
            header = next(reader, [])
            for row in reader:
                for col, v in zip(header, row):
                    if not v or v == "\\N":
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
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    hits = scan(a.files, load_tokens(a.tokens))
    if hits:
        print(f"FAIL: {sum(hits.values())} leak(s) in {len({k[:2] for k in hits})} column(s)")
        return 1
    print(f"OK: no tokens, e-mails or IPv4s in {len(a.files)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
