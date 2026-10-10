"""Linux V4L2 output backend used for Rocam's dedicated loopback camera.

``v4l2loopback`` 0.12.x only restores a capture device after a writer has
marked its output stream active.  pyvirtualcam's bundled Linux backend writes
to the output node but does not issue ``VIDIOC_STREAMON``.  This backend owns
that writer descriptor and performs the small V4L2 lifecycle explicitly.
"""

from __future__ import annotations

import errno
import fcntl
import glob
import math
import os
from pathlib import Path
import select
import struct
import sys
import time
from typing import Iterable


# Values from linux/videodev2.h.  The v4l2_format union is pointer-aligned, so
# its first member begins at byte 8 and the 64-bit structure is 208 bytes.
VIDIOC_QUERYCAP = 0x80685600
VIDIOC_S_FMT = 0xC0D05605
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_CAP_VIDEO_CAPTURE = 0x00000001
V4L2_CAP_VIDEO_OUTPUT = 0x00000002
V4L2_CAP_DEVICE_CAPS = 0x80000000
V4L2_PIX_FMT_RGB24 = int.from_bytes(b"RGB3", "little")
RGB_FOURCC = int.from_bytes(b"raw ", "little")

_CAPABILITY_SIZE = 104
_FORMAT_SIZE = 208
_MAX_DIMENSION = 8192
_LOOPBACK_DRIVER = "v4l2 loopback"
_ROCAM_CARD = "Rocam"


def _name(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def _capabilities(fd: int) -> tuple[str, str, int]:
    payload = bytearray(_CAPABILITY_SIZE)
    fcntl.ioctl(fd, VIDIOC_QUERYCAP, payload, True)
    driver = _name(payload[:16])
    card = _name(payload[16:48])
    capabilities = struct.unpack_from("<I", payload, 84)[0]
    device_capabilities = struct.unpack_from("<I", payload, 88)[0]
    if capabilities & V4L2_CAP_DEVICE_CAPS:
        capabilities = device_capabilities
    return driver, card, capabilities


def _open_flags() -> int:
    return os.O_WRONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)


def _is_rocam_output(fd: int) -> bool:
    driver, card, capabilities = _capabilities(fd)
    return (
        driver == _LOOPBACK_DRIVER
        and card == _ROCAM_CARD
        and bool(capabilities & V4L2_CAP_VIDEO_OUTPUT)
    )


def _kernel_card_name(path: str) -> str | None:
    """Read sysfs metadata before opening a video node.

    This keeps probing away from physical and foreign capture devices.
    """
    try:
        return (Path("/sys/class/video4linux") / os.path.basename(path) / "name").read_text().strip()
    except OSError:
        return None


def _video_sort_key(path: str) -> tuple[int, str]:
    suffix = path.rsplit("video", 1)[-1]
    return (int(suffix), path) if suffix.isdigit() else (float("inf"), path)


def find_rocam_device(device_paths: Iterable[str] | None = None) -> str | None:
    """Return the writable Rocam loopback output without probing other cameras."""
    paths = sorted(device_paths if device_paths is not None else glob.glob("/dev/video*"), key=_video_sort_key)
    for path in paths:
        if _kernel_card_name(path) != _ROCAM_CARD:
            continue
        try:
            fd = os.open(path, _open_flags())
        except OSError:
            continue
        try:
            if _is_rocam_output(fd):
                return path
        except OSError:
            pass
        finally:
            os.close(fd)
    return None


class RocamV4L2Backend:
    """Publish RGB frames to the dedicated ``Rocam`` v4l2loopback node."""

    def __init__(self, *, width: int, height: int, fps: float, fourcc: int, device: str | None, **_kwargs) -> None:
        if sys.byteorder != "little" or struct.calcsize("P") != 8:
            raise RuntimeError("Rocam's V4L2 backend requires a 64-bit little-endian Linux ABI")
        if (
            type(width) is not int
            or type(height) is not int
            or not (0 < width <= _MAX_DIMENSION and 0 < height <= _MAX_DIMENSION)
            or width * height > 16_777_216
        ):
            raise ValueError(f"unsupported virtual camera dimensions: {width}x{height}")
        if not isinstance(fps, (int, float)) or not math.isfinite(fps) or fps <= 0:
            raise ValueError("virtual camera FPS must be a positive finite number")
        if fourcc != RGB_FOURCC:
            raise ValueError("Rocam's V4L2 backend accepts RGB frames only")

        self._width = width
        self._height = height
        self._fps = float(fps)
        self._frame_size = width * height * 3
        self._fd: int | None = None
        self._streaming = False
        self._device = device or find_rocam_device()
        if self._device is None:
            raise RuntimeError("No writable Rocam v4l2loopback output was found.")

        try:
            self._fd = os.open(self._device, _open_flags())
            driver, card, capabilities = _capabilities(self._fd)
            if (
                driver != _LOOPBACK_DRIVER
                or card != _ROCAM_CARD
                or not capabilities & V4L2_CAP_VIDEO_OUTPUT
            ):
                raise RuntimeError(f"{self._device} is not the writable Rocam v4l2loopback output.")
            self._set_format()
            self._start_output()
        except BaseException:
            self.close()
            raise

    def _set_format(self) -> None:
        if self._fd is None:
            raise RuntimeError("virtual camera is closed")
        payload = bytearray(_FORMAT_SIZE)
        struct.pack_into(
            "<I",
            payload,
            0,
            V4L2_BUF_TYPE_VIDEO_OUTPUT,
        )
        struct.pack_into(
            "<12I",
            payload,
            8,
            self._width,
            self._height,
            V4L2_PIX_FMT_RGB24,
            1,  # V4L2_FIELD_NONE
            self._width * 3,
            self._frame_size,
            0,
            0,
            0,
            0,
            0,
            0,
        )
        fcntl.ioctl(self._fd, VIDIOC_S_FMT, payload, True)
        configured_width, configured_height, configured_fourcc = struct.unpack_from("<III", payload, 8)
        if (configured_width, configured_height, configured_fourcc) != (
            self._width,
            self._height,
            V4L2_PIX_FMT_RGB24,
        ):
            raise RuntimeError(f"{self._device} did not accept the requested RGB24 format.")

    def _start_output(self) -> None:
        if self._fd is None:
            raise RuntimeError("virtual camera is closed")
        try:
            fcntl.ioctl(self._fd, VIDIOC_STREAMON, struct.pack("<I", V4L2_BUF_TYPE_VIDEO_OUTPUT))
        except OSError as exc:
            raise RuntimeError(f"{self._device} could not start its V4L2 output stream") from exc
        self._streaming = True

    def close(self) -> None:
        """Stop the output stream and close its writer descriptor exactly once."""
        fd, self._fd = self._fd, None
        if fd is None:
            return
        try:
            if self._streaming:
                try:
                    fcntl.ioctl(fd, VIDIOC_STREAMOFF, struct.pack("<I", V4L2_BUF_TYPE_VIDEO_OUTPUT))
                except OSError:
                    pass
        finally:
            self._streaming = False
            os.close(fd)

    def send(self, frame) -> None:
        """Write one complete frame, retrying temporary nonblocking failures."""
        if self._fd is None:
            raise RuntimeError("virtual camera is closed")
        try:
            data = memoryview(frame).cast("B")
        except TypeError as exc:
            raise TypeError("virtual camera frames must expose contiguous bytes") from exc
        if data.nbytes != self._frame_size:
            raise ValueError(f"unexpected frame size: {data.nbytes} != {self._frame_size}")

        timeout = max(0.05, min(1.0, 2.0 / self._fps))
        deadline = time.monotonic() + timeout
        while True:
            fd = self._fd
            if fd is None:
                raise RuntimeError("virtual camera was closed while publishing a frame")
            try:
                written = os.write(fd, data)
            except InterruptedError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("virtual camera did not accept a frame in time") from None
                continue
            except BlockingIOError:
                written = 0
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    raise RuntimeError("virtual camera stopped accepting frames") from exc
                written = 0
            if written == self._frame_size:
                return
            if written:
                raise RuntimeError("virtual camera accepted a partial frame")
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
                raise RuntimeError("virtual camera did not accept a complete frame in time")

    def device(self) -> str:
        return self._device

    def native_fourcc(self) -> int:
        return RGB_FOURCC


def register_backend(pyvirtualcam) -> None:
    """Register through pyvirtualcam's public extension API."""
    pyvirtualcam.register_backend("rocam-v4l2", RocamV4L2Backend)
