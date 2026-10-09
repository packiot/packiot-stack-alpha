#!/usr/bin/env python3
"""Tests for leakgate.py — run: python3 -m unittest dev/seed/test_leakgate.py"""
import gzip
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import leakgate as L  # noqa: E402  # pyright: ignore[reportMissingImports]


def gz(d, name, text):
    p = Path(d, name)
    with gzip.open(p, "wt") as f:
        f.write(text)
    return str(p)


class LeakGateTest(unittest.TestCase):
    def test_clean_file_passes(self):
        with tempfile.TemporaryDirectory() as d:
            p = gz(d, "core.t.csv.gz", "a,b\nEquipment 3f9a1c,10.5\n\\N,\n")
            self.assertEqual(L.scan([p], ["acme corp"], io.StringIO()), {})

    def test_token_in_a_keep_column_is_caught_case_insensitively(self):
        with tempfile.TemporaryDirectory() as d:
            p = gz(d, "core.t.csv.gz", "label,v\nstop at ACME Corp line,1\n")
            hits = L.scan([p], ["acme corp"], io.StringIO())
            self.assertEqual(hits[("core.t.csv.gz", "label", "token")], 1)

    def test_email_and_ipv4_are_caught_but_versions_and_decimals_are_not(self):
        with tempfile.TemporaryDirectory() as d:
            p = gz(d, "x.csv.gz", "a,b,c,d\nops@client.com,10.10.10.89,1.2.3,3.14\n")
            hits = L.scan([p], [], io.StringIO())
            self.assertEqual(set(k[1:] for k in hits), {("a", "email"), ("b", "ipv4")})

    def test_output_never_prints_the_value(self):
        with tempfile.TemporaryDirectory() as d:
            p = gz(d, "x.csv.gz", "a\nsecret-acme-corp-value\n")
            out = io.StringIO()
            L.scan([p], ["acme corp", "acme-corp"], out)
            self.assertNotIn("secret", out.getvalue())
            self.assertIn("x.csv.gz :: a", out.getvalue())


    def test_nameless_column_types_are_skipped_text_still_scanned(self):
        # 2026-10-07 full seed: a numeric product name ("4021335") "occurred" inside integer ids by coincidence
        with tempfile.TemporaryDirectory() as d:
            p = gz(d, "silver.t.csv.gz", "check_number,label\n9940213357,lot 4021335 ok\n")
            types = {("silver.t", "check_number"): "bigint", ("silver.t", "label"): "text"}
            hits = L.scan([p], ["4021335"], io.StringIO(), types=types)
            self.assertEqual(set(hits), {("silver.t.csv.gz", "label", "token")})   # bigint skipped, text caught
            # without the inventory the gate stays maximally strict (old behaviour)
            hits = L.scan([p], ["4021335"], io.StringIO())
            self.assertEqual(len(hits), 2)

    def test_load_types_reads_the_extract_inventory(self):
        with tempfile.TemporaryDirectory() as d:
            inv = Path(d, "columns.tsv")
            inv.write_text("silver\tt\thypertable\tcheck_number\tbigint\nsilver\tt\thypertable\tlabel\ttext\n")
            self.assertEqual(L.load_types(str(inv)), {("silver.t", "check_number"): "bigint", ("silver.t", "label"): "text"})
            self.assertEqual(L.load_types(None), {})

class TokenIndexEquivalence(unittest.TestCase):
    """The prefix index must answer exactly what the old one-big-regex answered (case-insensitive substring)."""

    def test_matches_the_regex_on_random_strings(self):
        import random, re
        rnd = random.Random(7)
        alpha = "abcdeLINE 10-xyz/ÁÉçãXYZ"
        tokens = sorted({"".join(rnd.choice(alpha) for _ in range(rnd.randint(4, 9))).lower() for _ in range(300)},
                        key=len, reverse=True)
        tokens = [t for t in tokens if len(t) >= L.MIN_TOKEN]
        rx = re.compile("|".join(re.escape(t) for t in tokens), re.I)
        idx = L.TokenIndex(tokens)
        for _ in range(20000):
            v = "".join(rnd.choice(alpha) for _ in range(rnd.randint(0, 40)))
            if rnd.random() < 0.3:   # plant a token, sometimes upper-cased, at a random position
                t = rnd.choice(tokens)
                t = t.upper() if rnd.random() < 0.5 else t
                k = rnd.randint(0, len(v))
                v = v[:k] + t + v[k:]
            self.assertEqual(bool(rx.search(v)), idx.search(v), v)

    def test_empty_index_and_short_strings(self):
        self.assertFalse(L.TokenIndex([]).search("anything"))
        self.assertFalse(L.TokenIndex(["acme"]).search("acm"))
        self.assertTrue(L.TokenIndex(["acme corp"]).search("x/ACME CORP/y"))


if __name__ == "__main__":
    unittest.main()
