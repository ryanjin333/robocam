import ctypes.util
import runpy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


class BuildAppTests(unittest.TestCase):
    def test_build_command_uses_current_python_and_desktop_output_paths(self):
        from build_app import build_command

        desktop = Path(__file__).resolve().parents[1]
        command = build_command(desktop)
        self.assertEqual(command[0], sys.executable)
        self.assertEqual(command[1:4], ["-m", "PyInstaller", "--noconfirm"])
        self.assertIn("--onedir", command)
        self.assertIn("--windowed", command)
        self.assertEqual(command[command.index("--name") + 1], "RocamDesktop")
        self.assertEqual(command[command.index("--distpath") + 1], str(desktop / "dist" / "app"))
        self.assertEqual(command[command.index("--workpath") + 1], str(desktop / "build" / "app"))
        self.assertEqual(command[command.index("--specpath") + 1], str(desktop / "build" / "app"))
        self.assertEqual(
            command[command.index("--runtime-hook") + 1],
            str(desktop / "pyi_rth_portaudio.py"),
        )
        self.assertEqual(command[-1], str(desktop / "rocam_desktop.py"))

    def test_source_archive_includes_portaudio_runtime_hook(self):
        desktop = Path(__file__).resolve().parents[1]
        self.assertIn("include pyi_rth_portaudio.py", (desktop / "MANIFEST.in").read_text())


class PortAudioRuntimeHookTests(unittest.TestCase):
    def setUp(self):
        self.hook = Path(__file__).resolve().parents[1] / "pyi_rth_portaudio.py"
        self.original_finder = ctypes.util.find_library

    def tearDown(self):
        ctypes.util.find_library = self.original_finder

    def test_frozen_linux_portaudio_uses_bundled_library_and_preserves_other_names(self):
        original_finder = Mock(return_value="system-library")
        ctypes.util.find_library = original_finder
        with tempfile.TemporaryDirectory() as temporary:
            bundled = Path(temporary) / "libportaudio.so.2"
            bundled.touch()
            with (
                patch.object(sys, "platform", "linux"),
                patch.object(sys, "frozen", True, create=True),
                patch.object(sys, "_MEIPASS", temporary, create=True),
            ):
                runpy.run_path(self.hook)
                self.assertEqual(ctypes.util.find_library("portaudio"), str(bundled))
                self.assertEqual(ctypes.util.find_library("other-library"), "system-library")
        original_finder.assert_called_once_with("other-library")

    def test_outside_frozen_linux_or_missing_bundled_library_leaves_finder_unchanged(self):
        for platform, frozen, bundled_exists in (
            ("linux", False, True),
            ("linux", True, False),
            ("darwin", True, True),
        ):
            with self.subTest(platform=platform, frozen=frozen, bundled_exists=bundled_exists):
                original_finder = Mock(return_value="system-library")
                ctypes.util.find_library = original_finder
                with tempfile.TemporaryDirectory() as temporary:
                    if bundled_exists:
                        (Path(temporary) / "libportaudio.so.2").touch()
                    with (
                        patch.object(sys, "platform", platform),
                        patch.object(sys, "frozen", frozen, create=True),
                        patch.object(sys, "_MEIPASS", temporary, create=True),
                    ):
                        runpy.run_path(self.hook)
                        self.assertEqual(ctypes.util.find_library("portaudio"), "system-library")
                original_finder.assert_called_once_with("portaudio")
