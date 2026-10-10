#!/usr/bin/env python3
"""Set up the Rocam USB webcam receiver on a fresh Ubuntu or Debian desktop."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

import install_linux


PACKAGE_NAMES = (
    "python3-venv",
    "python3-pip",
    "python3-build",
    "libusbmuxd-tools",
    "usbmuxd",
    "v4l2loopback-dkms",
    "v4l2loopback-utils",
    "v4l-utils",
)
MODULE_CONFIG = 'options v4l2loopback devices=1 card_label="Rocam" exclusive_caps=1\n'
MODULES_LOAD = "v4l2loopback\n"
UDEV_RULE = 'KERNEL=="video[0-9]*", ATTR{name}=="Rocam", TAG+="uaccess", MODE="0660", GROUP="video"\n'
_UDID_IN_UNIT = re.compile(r'"--udid" "([0-9a-fA-F-]+)"')


class SetupError(RuntimeError):
    """Raised when the host cannot be safely configured."""


@dataclass(frozen=True)
class SystemPaths:
    etc: Path

    @property
    def module_config(self) -> Path:
        return self.etc / "modprobe.d/rocam-v4l2loopback.conf"

    @property
    def modules_load(self) -> Path:
        return self.etc / "modules-load.d/rocam-v4l2loopback.conf"

    @property
    def udev_rule(self) -> Path:
        # uaccess is consumed by Ubuntu's later 73-seat-late.rules.
        return self.etc / "udev/rules.d/70-rocam-v4l2.rules"

    @property
    def modprobe_dirs(self) -> tuple[Path, ...]:
        if self.etc != Path("/etc"):
            return (self.module_config.parent,)
        return (
            Path("/etc/modprobe.d"),
            Path("/run/modprobe.d"),
            Path("/usr/local/lib/modprobe.d"),
            Path("/usr/lib/modprobe.d"),
            Path("/lib/modprobe.d"),
        )


def run_checked(command: Sequence[str], **kwargs: object) -> subprocess.CompletedProcess[object]:
    return subprocess.run(command, check=True, **kwargs)


def read_os_release(path: Path = Path("/etc/os-release")) -> str:
    return path.read_text(encoding="utf-8")


def require_debian_family(os_release: str, system_name: str) -> None:
    if system_name != "Linux":
        raise SetupError("Rocam setup supports Ubuntu or Debian Linux only.")
    fields: dict[str, str] = {}
    for line in os_release.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value.strip().strip('"')
    identifiers = {fields.get("ID", "").lower(), *fields.get("ID_LIKE", "").lower().split()}
    if not identifiers.intersection({"ubuntu", "debian"}):
        raise SetupError("Rocam setup supports Ubuntu or Debian Linux only.")


def reject_root(geteuid: Callable[[], int]) -> None:
    if geteuid() == 0:
        raise SetupError("run setup as the desktop user, not root")


def validate_managed_destinations(paths: SystemPaths) -> None:
    for path, expected in (
        (paths.module_config, MODULE_CONFIG),
        (paths.modules_load, MODULES_LOAD),
        (paths.udev_rule, UDEV_RULE),
    ):
        if path.is_symlink():
            raise SetupError(f"managed destination is a symbolic link: {path}")
        if path.exists() and (not path.is_file() or path.read_text(encoding="utf-8") != expected):
            raise SetupError(f"managed destination contains foreign configuration: {path}")


def reject_foreign_v4l2loopback_options(paths: SystemPaths) -> None:
    """Do not let a second module-options file change fresh-host behavior."""
    for directory in paths.modprobe_dirs:
        if not directory.is_dir():
            continue
        for candidate in directory.glob("*.conf"):
            if candidate == paths.module_config:
                continue
            try:
                contents = candidate.read_text(encoding="utf-8")
            except OSError as error:
                raise SetupError(f"cannot safely inspect existing v4l2loopback configuration: {candidate}") from error
            if re.search(r"^\s*options\s+v4l2loopback\b", contents, re.MULTILINE):
                raise SetupError(f"foreign v4l2loopback options already exist: {candidate}")


def has_owned_persistence(paths: SystemPaths) -> bool:
    return all(
        path.is_file() and not path.is_symlink() and path.read_text(encoding="utf-8") == contents
        for path, contents in ((paths.module_config, MODULE_CONFIG), (paths.modules_load, MODULES_LOAD))
    )


def install_managed_file(path: Path, contents: str, runner: Callable[..., object]) -> None:
    if path.exists():
        return
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as source:
        source.write(contents)
        temporary_name = source.name
    try:
        runner(["sudo", "install", "-o", "root", "-g", "root", "-m", "0644", temporary_name, str(path)])
    finally:
        Path(temporary_name).unlink(missing_ok=True)


def driver_is_loaded() -> bool:
    return Path("/sys/module/v4l2loopback").is_dir()


def find_rocam_card() -> str | None:
    for entry in sorted(Path("/sys/class/video4linux").glob("video*")):
        name = entry / "name"
        try:
            if name.read_text(encoding="utf-8").strip() == "Rocam":
                return f"/dev/{entry.name}"
        except OSError:
            continue
    return None


def verify_writable_camera(device: str) -> None:
    try:
        descriptor = os.open(device, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        raise SetupError(
            f"the desktop user cannot write {device}; ensure the Rocam rule is active or log out and back in after joining group video"
        ) from error
    os.close(descriptor)


def trusted_existing_install() -> bool:
    paths = install_linux.default_paths()
    if not install_linux.is_owned_unit(paths) or not install_linux.is_owned_data(paths):
        return False
    try:
        actual = paths.unit_path.read_text(encoding="utf-8")
    except OSError:
        return False
    matches = _UDID_IN_UNIT.findall(actual)
    if len(matches) > 1:
        return False
    expected = install_linux.unit_text(paths, matches[0] if matches else None)
    return hashlib.sha256(actual.encode()).digest() == hashlib.sha256(expected.encode()).digest()


def build_wheel(checkout: Path, runner: Callable[..., object], temporary: Path) -> Path:
    venv = temporary / "venv"
    wheelhouse = temporary / "wheelhouse"
    runner([sys.executable, "-m", "venv", "--system-site-packages", str(venv)])
    runner([str(venv / "bin/python"), "-m", "build", "--wheel", "--outdir", str(wheelhouse), str(checkout / "desktop")])
    wheels = sorted(wheelhouse.glob("rocam_webcam-*.whl"))
    if len(wheels) != 1:
        raise SetupError("building this checkout did not produce exactly one Rocam wheel")
    return wheels[0]


def plan(stdout: Callable[[str], None], kernel_release: str) -> None:
    stdout("sudo apt-get update")
    stdout("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y " + " ".join((*PACKAGE_NAMES, f"linux-headers-{kernel_release}")))
    stdout("sudo install managed Rocam v4l2loopback, modules-load, and udev files")
    stdout("sudo modprobe v4l2loopback  # only when it is not already loaded")
    stdout("build this checkout in a temporary virtual environment, then run the canonical per-user installer")


def setup(
    *,
    dry_run: bool = False,
    udid: str | None = None,
    paths: SystemPaths | None = None,
    checkout: Path | None = None,
    os_release: str | None = None,
    runner: Callable[..., object] = run_checked,
    write_file: Callable[[Path, str, Callable[..., object]], None] = install_managed_file,
    geteuid: Callable[[], int] = os.geteuid,
    driver_loaded: Callable[[], bool] = driver_is_loaded,
    find_rocam: Callable[[], str | None] = find_rocam_card,
    verify_access: Callable[[str], None] = verify_writable_camera,
    trusted_install: Callable[[], bool] = trusted_existing_install,
    kernel_release: str | None = None,
    stdout: Callable[[str], None] = print,
) -> int:
    reject_root(geteuid)
    install_linux.validate_udid(udid)
    require_debian_family(read_os_release() if os_release is None else os_release, platform.system() if os_release is None else "Linux")
    paths = SystemPaths(Path("/etc")) if paths is None else paths
    checkout = Path(__file__).resolve().parent.parent if checkout is None else checkout
    kernel_release = os.uname().release if kernel_release is None else kernel_release

    if trusted_install() and not dry_run:
        stdout("A trusted Rocam user service is already installed; no setup actions ran. Run --dry-run to inspect the setup plan.")
        return 0

    validate_managed_destinations(paths)
    reject_foreign_v4l2loopback_options(paths)
    loaded = driver_loaded()
    rocam_device = find_rocam()
    if loaded and rocam_device is None:
        raise SetupError(
            "v4l2loopback is already loaded without a Rocam card. Rocam will not unload, reload, or alter that driver; add a Rocam device during a maintenance window, then rerun setup."
        )
    if loaded and not has_owned_persistence(paths):
        raise SetupError(
            "the loaded Rocam card has no persistent Rocam module configuration. Do not guess the existing driver topology; add the owned configuration during a maintenance window, reboot, then rerun setup."
        )
    if dry_run:
        plan(stdout, kernel_release)
        return 0

    runner(["sudo", "apt-get", "update"])
    runner(["sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", *PACKAGE_NAMES, f"linux-headers-{kernel_release}"])
    if not loaded:
        write_file(paths.module_config, MODULE_CONFIG, runner)
        write_file(paths.modules_load, MODULES_LOAD, runner)
    write_file(paths.udev_rule, UDEV_RULE, runner)
    runner(["sudo", "udevadm", "control", "--reload-rules"])
    if not loaded:
        runner(["sudo", "modprobe", "v4l2loopback"])
        rocam_device = find_rocam()
        if rocam_device is None:
            raise SetupError("v4l2loopback loaded but did not create a Rocam card; do not start the receiver")
    else:
        runner(["sudo", "udevadm", "trigger", "--action=change", f"--name-match={Path(rocam_device).name}"])
    runner(["sudo", "udevadm", "settle"])

    try:
        verify_access(rocam_device)
    except OSError as error:
        raise SetupError(
            f"the desktop user cannot write {rocam_device}; ensure the Rocam rule is active or log out and back in after joining group video"
        ) from error
    with tempfile.TemporaryDirectory(prefix="rocam-wheel-") as temporary:
        wheel = build_wheel(checkout, runner, Path(temporary))
        # install_linux owns the per-user venv, unit file, and service lifecycle.
        install_linux.install(wheel, udid=udid)
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Print the Ubuntu/Debian setup plan without changing the host")
    parser.add_argument("--udid", help="Optional USB iPhone or iPad UDID")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        return setup(dry_run=args.dry_run, udid=args.udid)
    except (SetupError, install_linux.InstallerError) as error:
        print(f"error: {error}", file=sys.stderr)
    except subprocess.CalledProcessError as error:
        print(f"error: {Path(error.cmd[0]).name} failed", file=sys.stderr)
    except OSError as error:
        print(f"error: {error.strerror or error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
