"""Bounded parser and optional PyAV decoder for Rocam encoded video streams.

The wire payload is deliberately small: one Annex-B access unit follows each
fixed-size header.  This module never gives a URL to PyAV; networking remains
in :mod:`rocam_receiver` so credentials cannot leak through decoder errors.
"""

from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import BinaryIO


MAGIC = b"RCV1"
CODEC_H264 = 1
CODEC_HEVC = 2
FLAG_KEYFRAME = 1
FLAG_DISCONTINUITY = 2
MAX_PAYLOAD_BYTES = 16 * 1024 * 1024
MAX_DIMENSION = 8192
MAX_PIXELS = 16_777_216
HEADER = struct.Struct(">4sBBHIIIIQ")


class VideoFormatError(Exception):
    """The peer sent invalid encoded video framing."""


class VideoDecoderError(Exception):
    """An optional video decoder is unavailable or could not decode video."""


@dataclass(frozen=True)
class VideoPacket:
    codec: int
    flags: int
    width: int
    height: int
    sequence: int
    pts_us: int
    payload: bytes

    @property
    def keyframe(self) -> bool:
        return bool(self.flags & FLAG_KEYFRAME)

    @property
    def discontinuity(self) -> bool:
        return bool(self.flags & FLAG_DISCONTINUITY)


def _read_exact(source: BinaryIO, count: int) -> bytes:
    parts: list[bytes] = []
    while count:
        block = source.read(count)
        if not block:
            raise VideoFormatError("Rocam encoded video ended mid-packet.")
        parts.append(block)
        count -= len(block)
    return b"".join(parts)


def _validate(codec: int, flags: int, reserved: int, length: int, width: int, height: int) -> None:
    if codec not in (CODEC_H264, CODEC_HEVC):
        raise VideoFormatError("Rocam sent an unsupported video codec.")
    if flags & ~(FLAG_KEYFRAME | FLAG_DISCONTINUITY) or reserved:
        raise VideoFormatError("Rocam sent invalid video packet flags.")
    if not 0 < length <= MAX_PAYLOAD_BYTES:
        raise VideoFormatError("Rocam encoded video exceeds the 16 MiB packet limit.")
    if not 0 < width <= MAX_DIMENSION or not 0 < height <= MAX_DIMENSION or width * height > MAX_PIXELS:
        raise VideoFormatError("Rocam sent unsupported encoded video dimensions.")


def read_packet(source: BinaryIO) -> VideoPacket:
    """Read one complete bounded RCV1 packet without speculative allocation."""
    magic, codec, flags, reserved, length, width, height, sequence, pts_us = HEADER.unpack(_read_exact(source, HEADER.size))
    if magic != MAGIC:
        raise VideoFormatError("Rocam sent unknown encoded video framing.")
    _validate(codec, flags, reserved, length, width, height)
    return VideoPacket(codec, flags, width, height, sequence, pts_us, _read_exact(source, length))


class PacketReader:
    """Small state-free reader used by the receiver and parser tests."""

    def __init__(self, source: BinaryIO) -> None:
        self.source = source

    def read(self) -> VideoPacket:
        return read_packet(self.source)


def codec_name(codec: int) -> str:
    if codec == CODEC_H264:
        return "h264"
    if codec == CODEC_HEVC:
        return "hevc"
    raise VideoFormatError("Rocam sent an unsupported video codec.")


class AVDecoder:
    """Decode access units while refusing dependent frames after a stream gap."""

    def __init__(self) -> None:
        self._context = None
        self._codec: int | None = None
        self._dimensions: tuple[int, int] | None = None
        self._sequence: int | None = None
        self._waiting_for_keyframe = True

    @staticmethod
    def available() -> bool:
        try:
            import av  # noqa: F401
        except ImportError:
            return False
        return True

    def reset(self) -> None:
        self._context = None
        self._codec = None
        self._dimensions = None
        self._sequence = None
        self._waiting_for_keyframe = True

    def _new_context(self, packet: VideoPacket) -> None:
        try:
            import av
        except ImportError:
            raise VideoDecoderError(
                "H.264/HEVC reception requires the video extra. Install with: pip install './desktop[video]'."
            ) from None
        try:
            self._context = av.CodecContext.create(codec_name(packet.codec), "r")
            # Enforce the wire image ceiling inside FFmpeg too: SPS dimensions are
            # parsed before the decoded ndarray shape can be inspected.
            self._context.options = {"max_pixels": str(MAX_PIXELS), "threads": "1"}
            self._context.thread_count = 1
        except Exception:
            raise VideoDecoderError("PyAV could not create an H.264/HEVC decoder.") from None
        self._codec = packet.codec
        self._dimensions = (packet.width, packet.height)

    def decode(self, packet: VideoPacket):
        """Return RGB frames. Gaps force a reset and a subsequent keyframe."""
        dimensions = (packet.width, packet.height)
        changed = self._codec != packet.codec or self._dimensions != dimensions
        gap = self._sequence is not None and packet.sequence != (self._sequence + 1) & 0xFFFFFFFF
        if packet.discontinuity or changed or gap:
            self.reset()
        if self._waiting_for_keyframe and not packet.keyframe:
            return []
        if self._context is None:
            self._new_context(packet)
        self._waiting_for_keyframe = False
        self._sequence = packet.sequence
        try:
            import av
            decoded = self._context.decode(av.Packet(packet.payload))
        except Exception:
            self.reset()
            raise VideoDecoderError("Rocam sent an encoded video access unit that PyAV could not decode.") from None
        frames = []
        for frame in decoded:
            try:
                array = frame.to_ndarray(format="rgb24")
            except Exception:
                self.reset()
                raise VideoDecoderError("Rocam decoded video into an unreadable frame.") from None
            if array.ndim != 3 or array.shape[2] != 3 or array.shape[1] != packet.width or array.shape[0] != packet.height:
                self.reset()
                raise VideoDecoderError("Rocam decoded video dimensions do not match its packet header.")
            frames.append(array)
        return frames
