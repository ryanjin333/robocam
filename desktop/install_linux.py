#!/usr/bin/env python3
"""Install Rocam's USB webcam receiver as a per-user systemd service."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


SERVICE = "rocam-webcam.service"
OWNERSHIP_MARKER = "# Managed by Rocam install_linux.py\n"
OWNERSHIP_FILE = ".install_linux-owned"
UDID_PATTERN = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})\Z")


class InstallerError(RuntimeError):
    """Raised when the installer cannot safely continue."""


@dataclass(frozen=True)
class Paths:
    data_dir: Path
    unit_path: Path

    @property
    def venv_dir(self) -> Path:
        return self.data_dir / "venv"


def default_paths(home: Path | None = None) -> Paths:
    home = Path.home() if home is None else home
    return Paths(
        data_dir=home / ".local/share/rocam",
        unit_path=home / ".config/systemd/user" / SERVICE,
    )


def systemd_escape_arg(value: str | Path) -> str:
    """Quote one ExecStart argument using systemd's command-line syntax."""
    value = str(value)
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise InstallerError("systemd arguments cannot contain control characters")
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("%", "%%")
    )
    return f'"{escaped}"'


def unit_text(paths: Paths, udid: str | None) -> str:
    args = [paths.venv_dir / "bin/rocam-webcam", "--usb", "--fps", "30"]
    if udid is not None:
        args.extend(["--udid", udid])
    command = " ".join(systemd_escape_arg(argument) for argument in args)
    return f"""{OWNERSHIP_MARKER}[Unit]
Description=Rocam USB virtual webcam

[Service]
Type=simple
ExecStart=:{command}
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=15

[Install]
WantedBy=default.target
"""


def port_available(port: int = 8765) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        try:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", port))
            listener.listen(1)
        except OSError:
            return False
    return True


def run_checked(command: Sequence[str], **kwargs: object) -> subprocess.CompletedProcess[object]:
    return subprocess.run(command, check=True, **kwargs)


def write_atomic(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as temp:
            temp.write(contents)
            temp_name = temp.name
        os.chmod(temp_name, 0o644)
        os.replace(temp_name, path)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)


def daemon_reload(runner: Callable[..., object]) -> None:
    runner(["systemctl", "--user", "daemon-reload"])


def restore_unit(paths: Paths, previous: str | None, runner: Callable[..., object]) -> None:
    if previous is None:
        paths.unit_path.unlink(missing_ok=True)
    else:
        write_atomic(paths.unit_path, previous)
    try:
        daemon_reload(runner)
    except subprocess.CalledProcessError:
        pass


def ownership_path(paths: Paths) -> Path:
    return paths.data_dir / OWNERSHIP_FILE


def is_owned_unit(paths: Paths) -> bool:
    return (
        paths.unit_path.is_file()
        and not paths.unit_path.is_symlink()
        and paths.unit_path.read_text(encoding="utf-8").startswith(OWNERSHIP_MARKER)
    )


def is_owned_data(paths: Paths) -> bool:
    marker = ownership_path(paths)
    return (
        paths.data_dir.is_dir()
        and not paths.data_dir.is_symlink()
        and marker.is_file()
        and not marker.is_symlink()
        and marker.read_text(encoding="utf-8") == "owned\n"
    )


def reject_unsafe_paths(paths: Paths) -> None:
    for path in (paths.unit_path, paths.data_dir, paths.venv_dir, ownership_path(paths)):
        if path.is_symlink():
            raise InstallerError("unsafe symbolic-link installer destination")


def claim_data(paths: Paths) -> bool:
    if paths.data_dir.exists():
        if not is_owned_data(paths):
            raise InstallerError("existing Rocam data is not managed by this installer")
        return False
    paths.data_dir.mkdir(parents=True)
    write_atomic(ownership_path(paths), "owned\n")
    return True


def systemctl_active() -> bool:
    return subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", SERVICE],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def systemctl_enabled() -> bool:
    return subprocess.run(
        ["systemctl", "--user", "is-enabled", "--quiet", SERVICE],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def systemctl_effective_unit(paths: Paths) -> bool | None:
    def property_value(name: str) -> str | None:
        try:
            result = subprocess.run(
                ["systemctl", "--user", "show", "--value", "--property", name, SERVICE],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
        except OSError as error:
            raise InstallerError("systemctl --user is unavailable") from error
        if result.returncode != 0:
            raise InstallerError(f"could not inspect loaded service {name}")
        return result.stdout.strip()

    fragment = property_value("FragmentPath")
    if not fragment:
        return None
    drop_ins = property_value("DropInPaths")
    return fragment == str(paths.unit_path) and not drop_ins


def require_effective_unit(paths: Paths, effective_unit: Callable[[Paths], bool | None], *, expected: bool) -> None:
    if effective_unit(paths) is not expected:
        raise InstallerError("loaded service is not the installer-owned unit without drop-ins")


def backup_venv(paths: Paths) -> Path | None:
    backup = paths.data_dir / "venv.backup"
    if backup.exists() or backup.is_symlink():
        raise InstallerError("existing venv backup requires manual inspection")
    if not paths.venv_dir.exists():
        return None
    shutil.copytree(paths.venv_dir, backup, symlinks=True)
    return backup


def restore_venv(paths: Paths, backup: Path | None) -> None:
    if backup is None:
        return
    if paths.venv_dir.exists():
        shutil.rmtree(paths.venv_dir)
    shutil.copytree(backup, paths.venv_dir, symlinks=True)


def reject_root(geteuid: Callable[[], int]) -> None:
    if geteuid() == 0:
        raise InstallerError("run this installer as the desktop user, not root")


def validate_udid(udid: str | None) -> None:
    if udid is not None and not UDID_PATTERN.fullmatch(udid):
        raise InstallerError("--udid must be a valid iPhone or iPad UDID")


def restart_previous_service(runner: Callable[..., object]) -> None:
    try:
        runner(["systemctl", "--user", "start", SERVICE])
    except subprocess.CalledProcessError:
        pass


def install(
    wheel: Path,
    *,
    paths: Paths | None = None,
    udid: str | None = None,
    runner: Callable[..., object] = run_checked,
    port_available: Callable[[], bool] = port_available,
    geteuid: Callable[[], int] = os.geteuid,
    service_active: Callable[[], bool] = systemctl_active,
    service_enabled: Callable[[], bool] = systemctl_enabled,
    effective_unit: Callable[[Paths], bool | None] = systemctl_effective_unit,
) -> None:
    reject_root(geteuid)
    wheel = Path(wheel)
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise InstallerError("--wheel must name an existing wheel file")
    validate_udid(udid)

    paths = default_paths() if paths is None else paths
    reject_unsafe_paths(paths)
    if paths.unit_path.exists() and not is_owned_unit(paths):
        raise InstallerError("existing Rocam service is not managed by this installer")
    if paths.data_dir.exists() and not is_owned_data(paths):
        raise InstallerError("existing Rocam data is not managed by this installer")

    previous = paths.unit_path.read_text(encoding="utf-8") if paths.unit_path.exists() else None
    if previous is None:
        if effective_unit(paths) is not None:
            raise InstallerError("loaded service is not the installer-owned unit without drop-ins")
    else:
        require_effective_unit(paths, effective_unit, expected=True)
    was_active = previous is not None and service_active()
    was_enabled = previous is not None and service_enabled()
    stopped_owned_service = False
    if was_active:
        runner(["systemctl", "--user", "stop", SERVICE])
        stopped_owned_service = True
    if not port_available():
        if stopped_owned_service:
            restart_previous_service(runner)
        raise InstallerError("127.0.0.1:8765 is already in use; leave the existing receiver untouched")

    created_data = False
    start_attempted = False
    enable_attempted = False
    venv_backup: Path | None = None
    try:
        created_data = claim_data(paths)
        venv_backup = backup_venv(paths)
        runner([sys.executable, "-m", "venv", str(paths.venv_dir)])
        runner([
            str(paths.venv_dir / "bin/python"), "-m", "pip", "install", "--upgrade", "--force-reinstall", str(wheel),
        ])
        write_atomic(paths.unit_path, unit_text(paths, udid))
        daemon_reload(runner)
        require_effective_unit(paths, effective_unit, expected=True)
        enable_attempted = True
        runner(["systemctl", "--user", "enable", SERVICE])
        start_attempted = True
        runner(["systemctl", "--user", "start", SERVICE])
    except BaseException:
        if start_attempted:
            try:
                runner(["systemctl", "--user", "stop", SERVICE])
            except (OSError, subprocess.CalledProcessError) as error:
                raise InstallerError("could not stop Rocam after a failed start; files were left in place") from error
        if enable_attempted and not was_enabled:
            try:
                runner(["systemctl", "--user", "disable", SERVICE])
            except subprocess.CalledProcessError:
                pass
        restore_unit(paths, previous, runner)
        if venv_backup is not None:
            restore_venv(paths, venv_backup)
        if created_data and is_owned_data(paths):
            shutil.rmtree(paths.data_dir)
        if was_active or stopped_owned_service:
            restart_previous_service(runner)
        raise
    else:
        if venv_backup is not None:
            shutil.rmtree(venv_backup)


def uninstall(
    *,
    paths: Paths | None = None,
    runner: Callable[..., object] = run_checked,
    geteuid: Callable[[], int] = os.geteuid,
    effective_unit: Callable[[Paths], bool | None] = systemctl_effective_unit,
) -> None:
    reject_root(geteuid)
    paths = default_paths() if paths is None else paths
    reject_unsafe_paths(paths)
    unit_exists = paths.unit_path.exists()
    data_exists = paths.data_dir.exists()
    if unit_exists and not is_owned_unit(paths):
        raise InstallerError("existing Rocam service is not managed by this installer")
    if data_exists and not is_owned_data(paths):
        raise InstallerError("existing Rocam data is not managed by this installer")
    if not unit_exists and effective_unit(paths) is not None:
        raise InstallerError("loaded service is not the installer-owned unit without drop-ins")
    if unit_exists:
        require_effective_unit(paths, effective_unit, expected=True)
        runner(["systemctl", "--user", "disable", "--now", SERVICE])
        paths.unit_path.unlink()
        daemon_reload(runner)
    if data_exists:
        shutil.rmtree(paths.data_dir)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheel", type=Path, help="Path to the Rocam wheel built from this checkout")
    parser.add_argument("--udid", help="Optional USB iPhone or iPad UDID")
    parser.add_argument("--uninstall", action="store_true", help="Remove this user service and its venv")
    args = parser.parse_args(argv)
    if not args.uninstall and args.wheel is None:
        parser.error("--wheel is required unless --uninstall is used")
    if args.uninstall and args.udid:
        parser.error("--udid cannot be used with --uninstall")
    return args


def main(
    argv: Sequence[str] | None = None,
    *,
    runner: Callable[..., object] = run_checked,
    geteuid: Callable[[], int] = os.geteuid,
) -> int:
    try:
        args = parse_args(argv)
        if args.uninstall:
            uninstall(runner=runner, geteuid=geteuid)
        else:
            install(args.wheel, udid=args.udid, runner=runner, geteuid=geteuid)
    except InstallerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(f"error: {Path(error.cmd[0]).name} failed", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error.strerror or error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
