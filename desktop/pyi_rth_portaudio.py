"""Find the bundled PortAudio library when running a frozen Linux application."""

import ctypes.util
from pathlib import Path
import sys


if sys.platform.startswith("linux") and getattr(sys, "frozen", False):
    bundled_library = Path(sys._MEIPASS) / "libportaudio.so.2"
    if bundled_library.is_file():
        original_find_library = ctypes.util.find_library

        def find_library(name: str):
            if name == "portaudio":
                return str(bundled_library)
            return original_find_library(name)

        ctypes.util.find_library = find_library
