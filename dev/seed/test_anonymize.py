#!/usr/bin/env python3
"""Tests for anonymize.py — run: python3 -m unittest dev/seed/test_anonymize.py"""
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import anonymize as A  # noqa: E402  # pyright: ignore[reportMissingImports]

KEY = b"test-key"
CLS = """columns:
  core.t.nm_equipment: {class: pseudonym, why: "x", scan: []}
  core.t.cd_machine: {class: pseudonym, why: "x", scan: []}
  core.t.cd_equipment: {class: pseudonym, why: "x", scan: []}
  core.t.topic: {class: scrub, why: "x", scan: []}
  core.t.notes: {class: null, why: "x", scan: []}
  core.t.code: {class: keep, why: "x", scan: []}
"""
TOKENS = [("equipment", "Line 1"), ("equipment", "Line 10"), ("client", "Acme Corp"), ("site", "L1")]


def run_csv(text, tokens=TOKENS, key=KEY):
    with tempfile.TemporaryDirectory() as d:
        cls = Path(d, "c.yml")
        cls.write_text(CLS)
        tok = Path(d, "t.tsv")
        tok.write_text("".join(f"{c}\t{v}\n" for c, v in tokens))
        out = io.StringIO()
        A.run("core.t", cls, tok, key, io.StringIO(text), out)
        return out.getvalue().splitlines()


class AnonymizeTest(unittest.TestCase):
    def test_pseudonym_is_deterministic_and_shared_across_columns(self):
        a = A.Anonymizer(KEY, [])
        self.assertEqual(a.apply("pseudonym", "cd_machine", "L01-XYZ"), a.apply("pseudonym", "cd_equipment", "L01-XYZ"))
        self.assertEqual(a.apply("pseudonym", "cd_machine", "L01-XYZ"), a.apply("pseudonym", "cd_machine", " l01-xyz "))
        self.assertNotEqual(A.Anonymizer(b"other", []).pseudo("L01-XYZ", "EQ"), a.pseudo("L01-XYZ", "EQ"))
        self.assertRegex(a.pseudo("Line 1", "Equipment"), r"^Equipment [0-9a-f]{6}$")

    def test_scrub_longest_first_and_case_insensitive(self):
        a = A.Anonymizer(KEY, TOKENS)
        out = a.scrub("spBv1.0/acme corp/LINE 10/node")
        self.assertNotIn("10", out.replace(a.pseudo("Line 10", "Equipment"), ""))
        self.assertIn(a.pseudo("Line 10", "Equipment"), out)      # not "<Line 1 pseudo>0"
        self.assertIn(a.pseudo("Acme Corp", "Client"), out)
        self.assertNotIn("acme", out.lower().replace(a.pseudo("Acme Corp", "Client").lower(), ""))

    def test_scrubbed_token_matches_the_name_column_pseudonym(self):
        a = A.Anonymizer(KEY, TOKENS)
        self.assertEqual(a.scrub("Line 1"), a.apply("pseudonym", "nm_equipment", "Line 1"))

    def test_short_tokens_are_not_scrubbed(self):
        a = A.Anonymizer(KEY, TOKENS)
        self.assertEqual(a.scrub("L1 is down"), "L1 is down")

    def test_null_empty_and_keep(self):
        lines = run_csv('nm_equipment,topic,notes,code,extra\n\\N,,secret note,A1,7\nLine 1,x/Line 1,,B2,\\N\n')
        self.assertEqual(lines[0], "nm_equipment,topic,notes,code,extra")
        self.assertEqual(lines[1], "\\N,,\\N,A1,7")                      # NULL stays NULL, "" stays "", null class → NULL
        a = A.Anonymizer(KEY, TOKENS)
        self.assertEqual(lines[2], f"{a.pseudo('Line 1', 'Equipment')},x/{a.pseudo('Line 1', 'Equipment')},\\N,B2,\\N")

    def test_missing_key_refuses(self):
        with self.assertRaises(SystemExit):
            A.Anonymizer(b"", [])


if __name__ == "__main__":
    unittest.main()
