"""Build a platform-native Rocam Desktop bundle with the active Python environment."""

from __future__ import annotations

from pathlib import Path
import importlib.util
import subprocess
import sys


def build_command(desktop_directory: Path) -> list[str]:
    """Return the reproducible PyInstaller command without changing the environment."""
    output = desktop_directory / "dist" / "app"
    build = desktop_directory / "build" / "app"
    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onedir",
        "--windowed",
        "--name",
        "RocamDesktop",
        "--distpath",
        str(output),
        "--workpath",
        str(build),
        "--specpath",
        str(build),
        "--runtime-hook",
        str(desktop_directory / "pyi_rth_portaudio.py"),
        "--hidden-import",
        "rocam_video",
        str(desktop_directory / "rocam_desktop.py"),
    ]
    if importlib.util.find_spec("av") is not None:
        command[-1:-1] = ["--collect-all", "av"]
    return command


def main() -> int:
    subprocess.run(build_command(Path(__file__).resolve().parent), check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
