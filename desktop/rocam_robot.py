"""Decode Rocam's synchronized RGB/depth robot-frame response.

The endpoint body is intentionally self-contained: ``RCR1`` followed by a
big-endian JSON-header length, UTF-8 JSON, native JPEG bytes, and tightly
packed little-endian Float32 depth meters.  This module only parses that wire
format; it does not create a virtual camera or make network requests.
"""

from __future__ import annotations

from dataclasses import dataclass
import io
import json
import math
import struct
from typing import Any, BinaryIO, Mapping

import numpy as np
from PIL import Image, UnidentifiedImageError


_MAGIC = b"RCR1"
_PREFIX_BYTES = 8
_MAX_HEADER_BYTES = 1 * 1024 * 1024
_MAX_DIMENSION = 8_192
_MAX_COLOR_PIXELS = 16 * 1024 * 1024
_MAX_DEPTH_PIXELS = 8 * 1024 * 1024
_MAX_PACKET_BYTES = 32 * 1024 * 1024
_MAX_JPEG_BYTES = _MAX_PACKET_BYTES
_MAX_DEPTH_BYTES = _MAX_PACKET_BYTES
_MAX_BODY_BYTES = _MAX_PACKET_BYTES


class RobotFrameError(ValueError):
    """Raised when a robot-frame response is malformed or unsafe to decode."""


@dataclass(frozen=True)
class RobotFrame:
    """A validated robot snapshot with RGB uint8 and depth Float32 meter arrays."""

    metadata: dict[str, Any]
    rgb: np.ndarray
    depth: np.ndarray


def _integer(value: Any, field: str, *, positive: bool = False, signed: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RobotFrameError(f"{field} must be an integer")
    if positive and value <= 0:
        raise RobotFrameError(f"{field} must be positive")
    if not positive and not signed and value < 0:
        raise RobotFrameError(f"{field} must not be negative")
    return value


def _timestamp(metadata: Mapping[str, Any], name: str) -> None:
    value = metadata.get(name)
    if not isinstance(value, Mapping):
        raise RobotFrameError(f"{name} must be a CMTime object")
    _integer(value.get("value"), f"{name}.value", signed=True)
    _integer(value.get("timescale"), f"{name}.timescale", positive=True)
    _integer(value.get("epoch"), f"{name}.epoch", signed=True)


def _matrix(value: Any, name: str, count: int) -> None:
    if value is None:
        return
    if not isinstance(value, list) or len(value) != count:
        raise RobotFrameError(f"{name} must be null or a {count}-element array")
    for item in value:
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            raise RobotFrameError(f"{name} must contain numeric values")
        try:
            finite = math.isfinite(float(item))
        except (OverflowError, ValueError):
            finite = False
        if not finite:
            raise RobotFrameError(f"{name} must contain finite numeric values")


def _validate_calibration(value: Any) -> None:
    if value is None:
        return
    if not isinstance(value, Mapping):
        raise RobotFrameError("cameraCalibration must be an object or null")
    _matrix(value.get("intrinsicMatrix"), "cameraCalibration.intrinsicMatrix", 9)
    _matrix(value.get("extrinsicMatrix"), "cameraCalibration.extrinsicMatrix", 12)
    dimensions = value.get("intrinsicMatrixReferenceDimensions")
    if dimensions is not None:
        if not isinstance(dimensions, list) or len(dimensions) != 2:
            raise RobotFrameError("cameraCalibration.intrinsicMatrixReferenceDimensions must be null or [width, height]")
        _integer(dimensions[0], "cameraCalibration.intrinsicMatrixReferenceDimensions[0]", positive=True)
        _integer(dimensions[1], "cameraCalibration.intrinsicMatrixReferenceDimensions[1]", positive=True)


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value {value}")


def _body_bytes(body: bytes | bytearray | memoryview | BinaryIO) -> bytes:
    if hasattr(body, "read"):
        parts = bytearray()
        while len(parts) <= _MAX_BODY_BYTES:
            chunk = body.read(min(64 * 1024, _MAX_BODY_BYTES + 1 - len(parts)))
            if not isinstance(chunk, (bytes, bytearray, memoryview)):
                raise RobotFrameError("binary stream returned a non-bytes value")
            if not chunk:
                break
            parts.extend(chunk)
        data = parts
    else:
        data = body
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise RobotFrameError("robot frame must be bytes or a binary stream")
    result = bytes(data)
    if len(result) > _MAX_BODY_BYTES:
        raise RobotFrameError("robot frame is too large")
    return result


def parse_robot_frame(body: bytes | bytearray | memoryview | BinaryIO) -> RobotFrame:
    """Parse one complete ``/robot.frame`` body or a readable binary stream.

    NaN depth values are retained because they are legitimate invalid depth
    samples.  The function rejects any trailing data, declared-length mismatch,
    unsupported schema, malformed timestamp, or image/depth geometry mismatch.
    """

    data = _body_bytes(body)
    if len(data) < _PREFIX_BYTES or data[:4] != _MAGIC:
        raise RobotFrameError("missing RCR1 magic")
    header_length = struct.unpack(">I", data[4:8])[0]
    if header_length == 0 or header_length > _MAX_HEADER_BYTES or len(data) < _PREFIX_BYTES + header_length:
        raise RobotFrameError("invalid JSON header length")
    try:
        metadata = json.loads(data[_PREFIX_BYTES:_PREFIX_BYTES + header_length].decode("utf-8"),
                              parse_constant=_reject_json_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise RobotFrameError("invalid JSON header") from error
    if not isinstance(metadata, dict):
        raise RobotFrameError("JSON header must be an object")
    if _integer(metadata.get("schemaVersion"), "schemaVersion") != 1:
        raise RobotFrameError("unsupported schemaVersion")
    _integer(metadata.get("sequence"), "sequence")
    color_bytes = _integer(metadata.get("colorJPEGBytes"), "colorJPEGBytes", positive=True)
    depth_bytes = _integer(metadata.get("depthBytes"), "depthBytes", positive=True)
    if color_bytes > _MAX_JPEG_BYTES or depth_bytes > _MAX_DEPTH_BYTES:
        raise RobotFrameError("declared payload is too large")
    color_width = _integer(metadata.get("colorWidth"), "colorWidth", positive=True)
    color_height = _integer(metadata.get("colorHeight"), "colorHeight", positive=True)
    depth_width = _integer(metadata.get("depthWidth"), "depthWidth", positive=True)
    depth_height = _integer(metadata.get("depthHeight"), "depthHeight", positive=True)
    for name, width, height, maximum_pixels in (("color", color_width, color_height, _MAX_COLOR_PIXELS),
                                                 ("depth", depth_width, depth_height, _MAX_DEPTH_PIXELS)):
        if width > _MAX_DIMENSION or height > _MAX_DIMENSION or width * height > maximum_pixels:
            raise RobotFrameError(f"{name} dimensions exceed bounds")
    if depth_bytes != depth_width * depth_height * np.dtype("<f4").itemsize:
        raise RobotFrameError("depthBytes does not match depth geometry")
    _timestamp(metadata, "colorTimestamp")
    _timestamp(metadata, "depthTimestamp")
    if "colorSampleBufferTimestamp" in metadata:
        _timestamp(metadata, "colorSampleBufferTimestamp")
    if metadata.get("synchronized") is not True:
        raise RobotFrameError("robot frame must be synchronized")
    _validate_calibration(metadata.get("cameraCalibration"))
    _matrix(metadata.get("rgbCameraIntrinsicMatrix"), "rgbCameraIntrinsicMatrix", 9)
    if not isinstance(metadata.get("captureImageGeometry"), Mapping):
        raise RobotFrameError("captureImageGeometry must be an object")

    payload_start = _PREFIX_BYTES + header_length
    payload_end = payload_start + color_bytes + depth_bytes
    if payload_end != len(data) or payload_end > _MAX_PACKET_BYTES:
        raise RobotFrameError("payload lengths do not match body")
    jpeg = data[payload_start:payload_start + color_bytes]
    try:
        with Image.open(io.BytesIO(jpeg)) as image:
            if image.format != "JPEG":
                raise RobotFrameError("payload is not a JPEG")
            if image.width != color_width or image.height != color_height:
                raise RobotFrameError("JPEG dimensions do not match metadata")
            if image.width * image.height > _MAX_COLOR_PIXELS:
                raise RobotFrameError("JPEG dimensions exceed bounds")
            rgb = np.asarray(image.convert("RGB")).copy()
    except RobotFrameError:
        raise
    except (UnidentifiedImageError, OSError, ValueError) as error:
        raise RobotFrameError("invalid JPEG payload") from error
    depth = np.frombuffer(data, dtype="<f4", count=depth_width * depth_height,
                          offset=payload_start + color_bytes).reshape((depth_height, depth_width))
    return RobotFrame(metadata=metadata, rgb=rgb, depth=depth)
