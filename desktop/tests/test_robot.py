import io
import json
import struct
import unittest

import numpy as np
from PIL import Image

from rocam_robot import RobotFrameError, parse_robot_frame


class FragmentedStream:
    def __init__(self, body, fragment_size=13):
        self.body = body
        self.fragment_size = fragment_size
        self.offset = 0

    def read(self, size=-1):
        if self.offset >= len(self.body):
            return b""
        limit = self.fragment_size if size < 0 else min(size, self.fragment_size)
        chunk = self.body[self.offset:self.offset + limit]
        self.offset += len(chunk)
        return chunk


def fixture(*, color_width=2, color_height=1, depth_width=2, depth_height=1, metadata_patch=None,
            payload_patch=None):
    image = Image.new("RGB", (color_width, color_height), (20, 40, 60))
    encoded = io.BytesIO()
    image.save(encoded, format="JPEG")
    jpeg = encoded.getvalue()
    depth = np.array([[1.25, np.nan]], dtype="<f4")
    if depth_width * depth_height != 2:
        depth = np.arange(depth_width * depth_height, dtype="<f4").reshape(depth_height, depth_width)
    raw_depth = depth.astype("<f4", copy=False).tobytes()
    metadata = {
        "schemaVersion": 1,
        "sequence": 7,
        "colorJPEGBytes": len(jpeg),
        "depthBytes": len(raw_depth),
        "colorWidth": color_width,
        "colorHeight": color_height,
        "depthWidth": depth_width,
        "depthHeight": depth_height,
        "colorTimestamp": {"value": 100, "timescale": 30, "epoch": 0},
        "depthTimestamp": {"value": 100, "timescale": 30, "epoch": 0},
        "synchronized": True,
        "cameraCalibration": {
            "intrinsicMatrix": [1.0] * 9,
            "extrinsicMatrix": [1.0] * 12,
            "intrinsicMatrixReferenceDimensions": [2, 1],
        },
        "captureImageGeometry": {"deliveredImageEffectsApplied": False},
    }
    if metadata_patch:
        metadata.update(metadata_patch)
    header = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
    body = b"RCR1" + struct.pack(">I", len(header)) + header + jpeg + raw_depth
    return payload_patch(body) if payload_patch else body


class RobotFrameTests(unittest.TestCase):
    def test_parses_valid_jpeg_and_float32_nan_depth(self):
        result = parse_robot_frame(fixture())
        self.assertEqual(result.metadata["sequence"], 7)
        self.assertEqual(result.rgb.shape, (1, 2, 3))
        self.assertEqual(result.depth.shape, (1, 2))
        self.assertAlmostEqual(float(result.depth[0, 0]), 1.25)
        self.assertTrue(np.isnan(result.depth[0, 1]))

    def test_accepts_binary_stream(self):
        self.assertEqual(parse_robot_frame(io.BytesIO(fixture())).rgb.shape, (1, 2, 3))

    def test_accepts_fragmented_binary_stream(self):
        self.assertEqual(parse_robot_frame(FragmentedStream(fixture())).depth.shape, (1, 2))

    def test_rejects_truncated_and_trailing_bodies(self):
        body = fixture()
        for malformed in (body[:-1], body + b"x"):
            with self.subTest(length=len(malformed)):
                with self.assertRaises(RobotFrameError):
                    parse_robot_frame(malformed)

    def test_rejects_bad_magic_and_length_fields(self):
        body = fixture()
        for malformed in (b"NOPE" + body[4:], b"RCR1" + struct.pack(">I", 0) + body[8:]):
            with self.subTest(malformed=malformed[:8]):
                with self.assertRaises(RobotFrameError):
                    parse_robot_frame(malformed)

    def test_rejects_shape_and_declared_length_mismatches(self):
        for patch in (
            {"depthBytes": 4},
            {"colorJPEGBytes": 1},
            {"colorWidth": 3},
            {"depthWidth": 3},
            {"colorHeight": True},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(RobotFrameError):
                    parse_robot_frame(fixture(metadata_patch=patch))

    def test_rejects_invalid_schema_timestamp_and_jpeg(self):
        for patch in (
            {"schemaVersion": 2},
            {"colorTimestamp": {"value": 1, "timescale": 0, "epoch": 0}},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(RobotFrameError):
                    parse_robot_frame(fixture(metadata_patch=patch))
        def corrupt_jpeg(body):
            header_length = struct.unpack(">I", body[4:8])[0]
            jpeg_start = 8 + header_length
            return body[:jpeg_start] + b"BAD!" + body[jpeg_start + 4:]

        with self.assertRaises(RobotFrameError):
            parse_robot_frame(fixture(payload_patch=corrupt_jpeg))

    def test_validates_optional_color_sample_buffer_timestamp(self):
        timestamp = {"value": 101, "timescale": 30, "epoch": 0}
        result = parse_robot_frame(fixture(metadata_patch={"colorSampleBufferTimestamp": timestamp}))
        self.assertEqual(result.metadata["colorSampleBufferTimestamp"], timestamp)
        with self.assertRaises(RobotFrameError):
            parse_robot_frame(fixture(metadata_patch={
                "colorSampleBufferTimestamp": {"value": 101, "timescale": 0, "epoch": 0}
            }))

    def test_rejects_nonfinite_calibration_and_png_payload(self):
        with self.assertRaises(RobotFrameError):
            parse_robot_frame(fixture(metadata_patch={"cameraCalibration": {"intrinsicMatrix": [float("inf")] * 9}}))
        png = io.BytesIO()
        Image.new("RGB", (2, 1), (1, 2, 3)).save(png, format="PNG")
        body = fixture()
        header_length = struct.unpack(">I", body[4:8])[0]
        metadata = json.loads(body[8:8 + header_length])
        old_jpeg_bytes = metadata["colorJPEGBytes"]
        metadata["colorJPEGBytes"] = len(png.getvalue())
        header = json.dumps(metadata, separators=(",", ":")).encode()
        depth = body[8 + header_length + old_jpeg_bytes:]
        malformed = b"RCR1" + struct.pack(">I", len(header)) + header + png.getvalue() + depth
        with self.assertRaises(RobotFrameError):
            parse_robot_frame(malformed)

    def test_rejects_huge_matrix_integer_and_bad_rgb_matrix(self):
        body = fixture()
        header_length = struct.unpack(">I", body[4:8])[0]
        header = body[8:8 + header_length].decode()
        huge_integer = "9" * 5_000
        malformed_header = header.replace('"intrinsicMatrix":[1.0,', f'"intrinsicMatrix":[{huge_integer},', 1).encode()
        malformed = b"RCR1" + struct.pack(">I", len(malformed_header)) + malformed_header + body[8 + header_length:]
        with self.assertRaises(RobotFrameError):
            parse_robot_frame(malformed)
        with self.assertRaises(RobotFrameError):
            parse_robot_frame(fixture(metadata_patch={"rgbCameraIntrinsicMatrix": [1.0] * 8}))

    def test_preserves_matrix_geometry_metadata(self):
        result = parse_robot_frame(fixture())
        calibration = result.metadata["cameraCalibration"]
        self.assertEqual(len(calibration["intrinsicMatrix"]), 9)
        self.assertEqual(len(calibration["extrinsicMatrix"]), 12)
        self.assertEqual(calibration["intrinsicMatrixReferenceDimensions"], [2, 1])
