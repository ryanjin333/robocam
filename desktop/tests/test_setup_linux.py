import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

if __import__("sys").platform != "linux":
    raise unittest.SkipTest("Linux setup tests require Linux")

import install_linux
import setup_linux


class LinuxSetupTests(unittest.TestCase):
    def paths(self, root):
        return setup_linux.SystemPaths(root / "etc")

    def test_dry_run_validates_debian_and_never_runs_or_writes(self):
        calls = []
        writes = []
        with tempfile.TemporaryDirectory() as temp:
            result = setup_linux.setup(
                dry_run=True,
                paths=self.paths(Path(temp)),
                os_release='ID=debian\n',
                runner=lambda command, **kwargs: calls.append((command, kwargs)),
                write_file=lambda *_args: writes.append(True),
                geteuid=lambda: 1000,
                stdout=lambda _line: None,
            )

        self.assertEqual(result, 0)
        self.assertEqual(calls, [])
        self.assertEqual(writes, [])

    def test_non_debian_platform_is_rejected_before_any_command(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(setup_linux.SetupError, "Ubuntu or Debian"):
                setup_linux.setup(
                    paths=self.paths(Path(temp)),
                    os_release='ID=fedora\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                )

        self.assertEqual(calls, [])

    def test_root_is_rejected_before_any_command(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(setup_linux.SetupError, "desktop user"):
                setup_linux.setup(
                    paths=self.paths(Path(temp)),
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 0,
                )

        self.assertEqual(calls, [])

    def test_foreign_managed_destination_is_refused_before_sudo(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            paths.module_config.parent.mkdir(parents=True)
            paths.module_config.write_text("options v4l2loopback devices=2\n")
            with self.assertRaisesRegex(setup_linux.SetupError, "foreign"):
                setup_linux.setup(
                    paths=paths,
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                )

        self.assertEqual(calls, [])

    def test_foreign_v4l2loopback_options_are_refused_before_sudo(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            paths.module_config.parent.mkdir(parents=True)
            (paths.module_config.parent / "existing-camera.conf").write_text(
                'options v4l2loopback devices=2 card_label="Other,Rocam"\n'
            )
            with self.assertRaisesRegex(setup_linux.SetupError, "foreign v4l2loopback"):
                setup_linux.setup(
                    paths=paths,
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                )

        self.assertEqual(calls, [])

    def test_loaded_driver_without_rocam_is_refused_without_modifying_it(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(setup_linux.SetupError, "already loaded"):
                setup_linux.setup(
                    paths=self.paths(Path(temp)),
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                    driver_loaded=lambda: True,
                    find_rocam=lambda: None,
                )

        self.assertEqual(calls, [])

    def test_loaded_rocam_without_persistent_owned_configuration_is_refused(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(setup_linux.SetupError, "persistent Rocam module configuration"):
                setup_linux.setup(
                    paths=self.paths(Path(temp)),
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                    driver_loaded=lambda: True,
                    find_rocam=lambda: "/dev/video11",
                )

        self.assertEqual(calls, [])

    def test_existing_rocam_card_is_reused_and_checked_before_installing_service(self):
        calls = []
        checked_nodes = []
        wheel = Path("/tmp/wheelhouse/rocam_webcam-0.1.0-py3-none-any.whl")
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            paths.module_config.parent.mkdir(parents=True)
            paths.modules_load.parent.mkdir(parents=True)
            paths.module_config.write_text(setup_linux.MODULE_CONFIG)
            paths.modules_load.write_text(setup_linux.MODULES_LOAD)
            with patch.object(setup_linux, "build_wheel", return_value=wheel) as build, \
                 patch.object(setup_linux.install_linux, "install") as install:
                setup_linux.setup(
                    paths=paths,
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                    driver_loaded=lambda: True,
                    find_rocam=lambda: "/dev/video11",
                    verify_access=lambda path: checked_nodes.append(path),
                )

        build.assert_called_once()
        install.assert_called_once_with(wheel, udid=None)
        self.assertEqual(checked_nodes, ["/dev/video11"])
        self.assertNotIn(["sudo", "modprobe", "v4l2loopback"], [command for command, _kwargs in calls])
        self.assertTrue(any("v4l2loopback-dkms" in command for command, _kwargs in calls))

    def test_loaded_rocam_with_owned_persistence_can_be_reused(self):
        calls = []
        wheel = Path("/tmp/wheelhouse/rocam_webcam-0.1.0-py3-none-any.whl")
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            paths.module_config.parent.mkdir(parents=True)
            paths.modules_load.parent.mkdir(parents=True)
            paths.module_config.write_text(setup_linux.MODULE_CONFIG)
            paths.modules_load.write_text(setup_linux.MODULES_LOAD)
            with patch.object(setup_linux, "build_wheel", return_value=wheel), \
                 patch.object(setup_linux.install_linux, "install") as install:
                setup_linux.setup(
                    paths=paths,
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    geteuid=lambda: 1000,
                    driver_loaded=lambda: True,
                    find_rocam=lambda: "/dev/video11",
                    verify_access=lambda _path: None,
                )

        install.assert_called_once_with(wheel, udid=None)

    def test_failed_sudo_stops_before_wheel_build_or_service_install(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            with patch.object(setup_linux, "build_wheel") as build, \
                 patch.object(setup_linux.install_linux, "install") as install:
                with self.assertRaises(subprocess.CalledProcessError):
                    setup_linux.setup(
                        paths=paths,
                        os_release='ID=ubuntu\n',
                        runner=lambda command, **_kwargs: (_ for _ in ()).throw(
                            subprocess.CalledProcessError(1, command)
                        ),
                        geteuid=lambda: 1000,
                        driver_loaded=lambda: False,
                        find_rocam=lambda: "/dev/video11",
                    )

        build.assert_not_called()
        install.assert_not_called()

    def test_fresh_setup_installs_a_narrow_active_console_access_rule_before_service(self):
        calls = []
        writes = []
        wheel = Path("/tmp/wheelhouse/rocam_webcam-0.1.0-py3-none-any.whl")
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(setup_linux, "build_wheel", return_value=wheel), \
                 patch.object(setup_linux.install_linux, "install") as install:
                setup_linux.setup(
                    paths=self.paths(Path(temp)),
                    os_release='ID=ubuntu\n',
                    runner=lambda command, **kwargs: calls.append((command, kwargs)),
                    write_file=lambda path, contents, _runner: writes.append((path, contents)),
                    geteuid=lambda: 1000,
                    driver_loaded=lambda: False,
                    find_rocam=lambda: "/dev/video11",
                    verify_access=lambda _path: None,
                )

        self.assertIn((self.paths(Path(temp)).udev_rule, setup_linux.UDEV_RULE), writes)
        self.assertEqual(self.paths(Path(temp)).udev_rule.name, "70-rocam-v4l2.rules")
        self.assertIn('TAG+="uaccess"', setup_linux.UDEV_RULE)
        self.assertIn(["sudo", "udevadm", "settle"], [command for command, _kwargs in calls])
        install.assert_called_once_with(wheel, udid=None)

    def test_trusted_existing_install_requires_dry_run_and_performs_no_work(self):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            result = setup_linux.setup(
                paths=self.paths(Path(temp)),
                os_release='ID=ubuntu\n',
                runner=lambda command, **kwargs: calls.append((command, kwargs)),
                geteuid=lambda: 1000,
                trusted_install=lambda: True,
                stdout=lambda _line: None,
            )

        self.assertEqual(result, 0)
        self.assertEqual(calls, [])

    def test_incorrect_existing_service_is_not_treated_as_trusted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            service_paths = install_linux.Paths(root / "data", root / "rocam-webcam.service")
            service_paths.unit_path.write_text(install_linux.OWNERSHIP_MARKER + "[Service]\nExecStart=/foreign\n")
            with patch.object(setup_linux.install_linux, "default_paths", return_value=service_paths), \
                 patch.object(setup_linux.install_linux, "is_owned_unit", return_value=True), \
                 patch.object(setup_linux.install_linux, "is_owned_data", return_value=True):
                self.assertFalse(setup_linux.trusted_existing_install())

    def test_access_failure_prevents_calling_canonical_installer(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = self.paths(Path(temp))
            paths.module_config.parent.mkdir(parents=True)
            paths.modules_load.parent.mkdir(parents=True)
            paths.module_config.write_text(setup_linux.MODULE_CONFIG)
            paths.modules_load.write_text(setup_linux.MODULES_LOAD)
            with patch.object(setup_linux, "build_wheel") as build, \
                 patch.object(setup_linux.install_linux, "install") as install:
                with self.assertRaisesRegex(setup_linux.SetupError, "cannot write"):
                    setup_linux.setup(
                        paths=paths,
                        os_release='ID=ubuntu\n',
                        runner=lambda *_args, **_kwargs: None,
                        geteuid=lambda: 1000,
                        driver_loaded=lambda: True,
                        find_rocam=lambda: "/dev/video11",
                        verify_access=lambda _path: (_ for _ in ()).throw(PermissionError()),
                    )

        build.assert_not_called()
        install.assert_not_called()


if __name__ == "__main__":
    unittest.main()
