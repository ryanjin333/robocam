import subprocess
import socket
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

if __import__("sys").platform != "linux":
    raise unittest.SkipTest("Linux systemd installer tests require Linux")

import install_linux


class LinuxInstallerTests(unittest.TestCase):
    def paths(self, root):
        return install_linux.Paths(
            data_dir=root / "Rocam data",
            unit_path=root / "systemd user" / "rocam-webcam.service",
        )

    def test_unit_uses_systemd_escaped_executable_path_and_no_udid_by_default(self):
        with tempfile.TemporaryDirectory() as temp:
            unit = install_linux.unit_text(self.paths(Path(temp)), None)

        self.assertIn(
            'ExecStart=:"' + str(Path(temp) / "Rocam data" / "venv/bin/rocam-webcam")
            + '" "--usb" "--fps" "20"',
            unit,
        )
        self.assertNotIn("--udid", unit)
        self.assertIn("Restart=on-failure", unit)
        self.assertIn("RestartSec=5", unit)
        self.assertIn("KillSignal=SIGINT", unit)
        self.assertIn("TimeoutStopSec=15", unit)

    def test_effective_unit_refuses_failed_fragment_or_dropin_inspection(self):
        paths = install_linux.Paths(Path("/tmp/rocam"), Path("/tmp/rocam.service"))
        failed = subprocess.CompletedProcess([], 1, stdout="")
        fragment = subprocess.CompletedProcess([], 0, stdout=f"{paths.unit_path}\n")

        with patch("install_linux.subprocess.run", return_value=failed):
            with self.assertRaisesRegex(install_linux.InstallerError, "inspect"):
                install_linux.systemctl_effective_unit(paths)
        with patch("install_linux.subprocess.run", side_effect=[fragment, failed]):
            with self.assertRaisesRegex(install_linux.InstallerError, "inspect"):
                install_linux.systemctl_effective_unit(paths)

    def test_port_check_allows_recent_time_wait_but_refuses_a_live_listener(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.listen(1)
        client = socket.create_connection(("127.0.0.1", port))
        accepted, _ = listener.accept()
        accepted.close()
        client.recv(1)
        client.close()
        listener.close()

        self.assertTrue(install_linux.port_available(port))

        live = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        live.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        live.bind(("127.0.0.1", port))
        live.listen(1)
        try:
            self.assertFalse(install_linux.port_available(port))
        finally:
            live.close()

    def test_unit_includes_only_valid_explicit_udid_as_a_separate_systemd_argument(self):
        with tempfile.TemporaryDirectory() as temp:
            unit = install_linux.unit_text(self.paths(Path(temp)), "00000000-0000000000000002")

        self.assertIn('"--udid" "00000000-0000000000000002"', unit)

    def test_unit_escapes_systemd_specifiers_and_rejects_control_characters(self):
        paths = install_linux.Paths(
            data_dir=Path("/tmp/Rocam %path $name"),
            unit_path=Path("/tmp/unit"),
        )
        unit = install_linux.unit_text(paths, None)

        self.assertIn('ExecStart=:"/tmp/Rocam %%path $name/venv/bin/rocam-webcam"', unit)
        with self.assertRaisesRegex(install_linux.InstallerError, "control"):
            install_linux.systemd_escape_arg("bad\npath")

    def test_udid_validation_happens_before_creating_the_venv(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            wheel = root / "rocam.whl"
            wheel.touch()
            with self.assertRaisesRegex(install_linux.InstallerError, "UDID"):
                install_linux.install(
                    wheel,
                    paths=self.paths(root),
                    udid="not-a-udid",
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                )

            install_linux.install(
                wheel,
                paths=self.paths(root),
                udid="00000000-0000000000000002",
                runner=lambda command, **kwargs: calls.append((command, kwargs)),
                port_available=lambda: True,
                effective_unit=lambda paths: True if paths.unit_path.exists() else None,
            )

        self.assertTrue(calls)

    def test_root_is_rejected_without_running_commands(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            result = install_linux.main(
                ["--wheel", str(Path(temp) / "rocam.whl")],
                geteuid=lambda: 0,
                runner=lambda command, **kwargs: calls.append((command, kwargs)),
            )

        self.assertEqual(result, 1)
        self.assertEqual(calls, [])

    def test_occupied_port_refuses_before_systemctl_or_install(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            wheel = root / "rocam.whl"
            wheel.touch()
            with self.assertRaisesRegex(install_linux.InstallerError, "127.0.0.1:8765"):
                install_linux.install(
                    wheel,
                    paths=self.paths(root),
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    port_available=lambda: False,
                    effective_unit=lambda _paths: None,
                )

        self.assertEqual(calls, [])

    def test_failed_start_restores_prior_owned_unit_and_stops_only_started_service(self):
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            if command[-2:] == ["start", "rocam-webcam.service"]:
                raise subprocess.CalledProcessError(1, command)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            original = install_linux.unit_text(paths, None)
            paths.unit_path.write_text(original)
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            wheel = root / "rocam.whl"
            wheel.touch()

            with self.assertRaises(subprocess.CalledProcessError):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=runner,
                    port_available=lambda: True,
                    service_active=lambda: False,
                    service_enabled=lambda: False,
                    effective_unit=lambda _paths: True,
                )

            self.assertEqual(paths.unit_path.read_text(), original)

        commands = [command for command, _kwargs in calls]
        self.assertIn(["systemctl", "--user", "stop", "rocam-webcam.service"], commands)
        self.assertIn(["systemctl", "--user", "daemon-reload"], commands)

    def test_failed_enable_removes_a_new_unit_and_its_enablement(self):
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            if command[-2:] == ["enable", "rocam-webcam.service"]:
                raise subprocess.CalledProcessError(1, command)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            wheel = root / "rocam.whl"
            wheel.touch()

            with self.assertRaises(subprocess.CalledProcessError):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=runner,
                    port_available=lambda: True,
                    effective_unit=lambda paths: True if paths.unit_path.exists() else None,
                )

            self.assertFalse(paths.unit_path.exists())
            self.assertFalse(paths.data_dir.exists())

        commands = [command for command, _kwargs in calls]
        self.assertIn(["systemctl", "--user", "disable", "rocam-webcam.service"], commands)

    def test_foreign_unit_and_data_are_refused_before_installation(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text("[Service]\\nExecStart=/foreign/receiver\\n")
            wheel = root / "rocam.whl"
            wheel.touch()

            with self.assertRaisesRegex(install_linux.InstallerError, "existing.*not managed"):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                )

            self.assertEqual(paths.unit_path.read_text(), "[Service]\\nExecStart=/foreign/receiver\\n")

        self.assertEqual(calls, [])

    def test_owned_active_service_is_stopped_for_update_and_restarted_after(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text(install_linux.unit_text(paths, None))
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            wheel = root / "rocam.whl"
            wheel.touch()
            install_linux.install(
                wheel,
                paths=paths,
                runner=lambda command, **kwargs: calls.append((command, kwargs)),
                port_available=lambda: True,
                service_active=lambda: True,
                service_enabled=lambda: True,
                effective_unit=lambda _paths: True,
            )

        commands = [command for command, _kwargs in calls]
        self.assertIn(["systemctl", "--user", "stop", "rocam-webcam.service"], commands)
        self.assertIn(["systemctl", "--user", "start", "rocam-webcam.service"], commands)
        self.assertNotIn(["systemctl", "--user", "enable", "--now", "rocam-webcam.service"], commands)

    def test_uninstall_preserves_owned_files_when_stop_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text(install_linux.unit_text(paths, None))
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")

            def failing_runner(command, **_kwargs):
                if command[-3:] == ["disable", "--now", "rocam-webcam.service"]:
                    raise subprocess.CalledProcessError(1, command)

            with self.assertRaises(subprocess.CalledProcessError):
                install_linux.uninstall(
                    paths=paths,
                    runner=failing_runner,
                    effective_unit=lambda _paths: True,
                )

            self.assertTrue(paths.unit_path.exists())
            self.assertTrue(paths.data_dir.exists())

    def test_uninstall_refuses_owned_data_when_a_unit_is_loaded_without_its_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")

            with self.assertRaisesRegex(install_linux.InstallerError, "loaded service"):
                install_linux.uninstall(
                    paths=paths,
                    runner=lambda *_args, **_kwargs: self.fail("must not run"),
                    effective_unit=lambda _paths: False,
                )

            self.assertTrue(paths.data_dir.exists())

    def test_symlinked_owned_data_is_refused(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            foreign_data = root / "foreign"
            foreign_data.mkdir()
            (foreign_data / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            paths.data_dir.symlink_to(foreign_data, target_is_directory=True)
            wheel = root / "rocam.whl"
            wheel.touch()

            with self.assertRaisesRegex(install_linux.InstallerError, "unsafe"):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                )

        self.assertEqual(calls, [])

    def test_loaded_foreign_or_dropin_unit_is_refused_before_stop(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text(install_linux.unit_text(paths, None))
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            wheel = root / "rocam.whl"
            wheel.touch()

            with self.assertRaisesRegex(install_linux.InstallerError, "loaded service"):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    service_active=lambda: True,
                    effective_unit=lambda _paths: False,
                )

        self.assertEqual(calls, [])

    def test_failed_upgrade_restores_the_existing_venv(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            paths.venv_dir.mkdir()
            (paths.venv_dir / "original").write_text("old package")
            wheel = root / "rocam.whl"
            wheel.touch()

            def runner(command, **_kwargs):
                if "pip" in command:
                    (paths.venv_dir / "original").unlink()
                    raise subprocess.CalledProcessError(1, command)

            with self.assertRaises(subprocess.CalledProcessError):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=runner,
                    port_available=lambda: True,
                    effective_unit=lambda _paths: None,
                )

            self.assertEqual((paths.venv_dir / "original").read_text(), "old package")

    def test_failed_start_restores_venv_before_restarting_previous_service(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text(install_linux.unit_text(paths, None))
            paths.data_dir.mkdir(parents=True)
            (paths.data_dir / install_linux.OWNERSHIP_FILE).write_text("owned\n")
            paths.venv_dir.mkdir()
            original = paths.venv_dir / "original"
            original.write_text("old package")
            wheel = root / "rocam.whl"
            wheel.touch()
            starts = 0

            def runner(command, **_kwargs):
                nonlocal starts
                if command[-2:] == ["start", "rocam-webcam.service"]:
                    starts += 1
                    if starts == 1:
                        original.unlink()
                        raise subprocess.CalledProcessError(1, command)
                    self.assertTrue(original.exists(), "previous service restarted before its venv was restored")

            with self.assertRaises(subprocess.CalledProcessError):
                install_linux.install(
                    wheel,
                    paths=paths,
                    runner=runner,
                    port_available=lambda: True,
                    service_active=lambda: True,
                    service_enabled=lambda: True,
                    effective_unit=lambda _paths: True,
                )

    def test_uninstall_refuses_foreign_unit_and_unowned_data(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = self.paths(root)
            paths.unit_path.parent.mkdir(parents=True)
            paths.unit_path.write_text("foreign")
            paths.data_dir.mkdir(parents=True)

            with self.assertRaisesRegex(install_linux.InstallerError, "not managed"):
                install_linux.uninstall(paths=paths, runner=lambda *_args, **_kwargs: self.fail("must not run"))

            self.assertTrue(paths.unit_path.exists())
            self.assertTrue(paths.data_dir.exists())


if __name__ == "__main__":
    unittest.main()
