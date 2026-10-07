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


if __name__ == "__main__":
    unittest.main()
