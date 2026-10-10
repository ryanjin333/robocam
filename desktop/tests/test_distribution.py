"""Offline tests for desktop release contracts and the macOS installer transaction."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAC_SETUP = ROOT / "desktop/setup_macos.sh"


@unittest.skipUnless(sys.platform != "win32", "macOS shell transaction tests are not portable to Windows")
class MacSetupTransactionTests(unittest.TestCase):
    def make_environment(self, root: Path, *, fail_pip: bool = False) -> dict[str, str]:
        bin_dir = root / "bin"
        prefix = root / "brew"
        bin_dir.mkdir()
        (prefix / "bin").mkdir(parents=True)

        def executable(name: str, body: str) -> None:
            path = bin_dir / name
            path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            path.chmod(0o755)

        executable("brew", 'if [ "$1" = "--prefix" ]; then printf "%s\\n" "$TEST_BREW_PREFIX"; fi\nexit 0\n')
        executable("launchctl", 'printf "%s\\n" "$*" >> "$TEST_LAUNCH_LOG"\nexit 0\n')
        executable("plutil", 'exit 0\n')
        (prefix / "bin/iproxy").write_text("#!/bin/sh\nprintf '%s\\n' '--local --source'\n", encoding="utf-8")
        (prefix / "bin/iproxy").chmod(0o755)
        executable(
            "python3.12",
            """if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  target="$3"; mkdir -p "$target/bin"
  cat > "$target/bin/python" <<'INNER'
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "pip" ]; then [ "${TEST_PIP_FAIL:-0}" = 1 ] && exit 1; exit 0; fi
exit 0
INNER
  cat > "$target/bin/rocam-webcam" <<'INNER'
#!/bin/sh
exit 0
INNER
  chmod +x "$target/bin/python" "$target/bin/rocam-webcam"
  exit 0
fi
exec "$REAL_PYTHON" "$@"
""",
        )
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(root / "home"),
                "PATH": f"{bin_dir}:{environment['PATH']}",
                "TEST_BREW_PREFIX": str(prefix),
                "TEST_LAUNCH_LOG": str(root / "launch.log"),
                "TEST_PIP_FAIL": "1" if fail_pip else "0",
                "REAL_PYTHON": sys.executable,
            }
        )
        return environment

    def run_setup(self, environment: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", MAC_SETUP, *args],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_failed_install_restores_owned_venv_and_launch_agent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.make_environment(root, fail_pip=True)
            data = root / "home/Library/Application Support/Rocam"
            launch = root / "home/Library/LaunchAgents/com.ryanjin.rocam.receiver.plist"
            (data / "venv").mkdir(parents=True)
            (data / ".rocam-owned").write_text("owned\n")
            (data / "venv/old-receiver").write_text("old\n")
            launch.parent.mkdir(parents=True)
            old_plist = b"<?xml version='1.0'?><plist>Rocam setup_macos.sh</plist>"
            launch.write_bytes(old_plist)
            wheel = root / "broken.whl"
            wheel.write_bytes(b"not a wheel")

            result = self.run_setup(environment, "--wheel", str(wheel))

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((data / "venv/old-receiver").read_text(), "old\n")
            self.assertEqual(launch.read_bytes(), old_plist)
            self.assertIn("bootstrap", (root / "launch.log").read_text())

    def test_success_writes_a_valid_owned_launch_agent_with_final_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment = self.make_environment(root)

            result = self.run_setup(environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            launch = root / "home/Library/LaunchAgents/com.ryanjin.rocam.receiver.plist"
            with launch.open("rb") as source:
                payload = plistlib.load(source)
            expected_venv = root / "home/Library/Application Support/Rocam/venv"
            self.assertEqual(payload["RocamManagedBy"], "Rocam setup_macos.sh")
            self.assertEqual(payload["ProgramArguments"], [str(expected_venv / "bin/rocam-webcam"), "--usb", "--fps", "20"])
            self.assertEqual(payload["EnvironmentVariables"]["PATH"].split(":")[0], str(root / "brew/bin"))
            self.assertTrue((expected_venv / "bin/rocam-webcam").is_file())


class DistributionWorkflowTests(unittest.TestCase):
    def test_ci_uses_native_platforms_and_release_is_tag_only(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        for runner in ("ubuntu-24.04", "macos-26", "windows-2025"):
            self.assertIn(runner, ci)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", ci)
        self.assertIn("tags: ['v*']", release)
        self.assertNotIn("workflow_dispatch", release)
        self.assertIn("--verify-tag", release)
        self.assertIn("contents: write", release)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is unavailable")
    def test_windows_scripts_parse_in_powershell(self):
        for relative in ("desktop/setup_windows.ps1", "desktop/package_windows_usb.ps1"):
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-Command", f"[void][scriptblock]::Create((Get-Content -Raw '{ROOT / relative}'))"],
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
