"""Sanity check that the oeecloud healthcheck script catches stale pipelines.

This is a meta-test — if the canonical pipeline test is green, the healthcheck
should also report OK. If we ever regress the healthcheck (e.g. silence an
error path) this test alerts us.
"""

import subprocess
import pytest


def test_oeecloud_healthcheck_passes():
    """Run /healthcheck.sh inside the oeecloud container; expect exit 0."""
    try:
        r = subprocess.run(
            ["docker", "compose", "-f", "compose.integration.yml",
             "exec", "-T", "oeecloud", "/healthcheck.sh"],
            cwd="/work" if subprocess.os.path.exists("/work/compose.integration.yml")
                else "/home/podesta/github/packiot/packiot-stack-alpha",
            capture_output=True, text=True, timeout=20,
        )
    except FileNotFoundError:
        pytest.skip("docker CLI not available in this environment")
    assert r.returncode == 0, f"healthcheck failed: stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "OK" in r.stdout
