"""Tests for validate.py rule 5 (generators) — run: python3 -m unittest dev/seed/test_validate.py"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run(gen_dir):
    r = subprocess.run([sys.executable, str(HERE / "validate.py"), "--generators", str(gen_dir)],
                       capture_output=True, text=True)
    return r.returncode, r.stdout


class GeneratorRule(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gen = self.tmp / "generators"
        shutil.copytree(HERE / "generators", self.gen)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_committed_generators_pass(self):
        code, out = run(self.gen)
        self.assertEqual(code, 0, out)

    def test_replace_table_without_generator_fails(self):
        (self.gen / "core.device_bindings.sql").unlink()
        code, out = run(self.gen)
        self.assertEqual(code, 1)
        self.assertIn("core.device_bindings is mode replace but has no generators/core.device_bindings.sql", out)

    def test_stray_generator_fails(self):
        (self.gen / "core.areas.sql").write_text("-- not a replace table\n")
        code, out = run(self.gen)
        self.assertEqual(code, 1)
        self.assertIn("generators/core.areas.sql exists but core.areas is not mode replace", out)

    def test_missing_dir_fails_for_every_replace_table(self):
        code, out = run(self.tmp / "nope")
        self.assertEqual(code, 1)
        self.assertIn("identity.users is mode replace", out)


if __name__ == "__main__":
    unittest.main()
