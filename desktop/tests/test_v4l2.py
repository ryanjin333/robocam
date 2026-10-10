import errno
import os
import struct
import unittest
from unittest.mock import patch

if __import__("sys").platform != "linux":
    raise unittest.SkipTest("V4L2 tests require Linux")

import numpy as np

import rocam_v4l2


def _querycap(buffer, *, card=b"Rocam", driver=b"v4l2 loopback", capabilities=0x2):
    buffer[:16] = driver.ljust(16, b"\0")
    buffer[16:48] = card.ljust(32, b"\0")
    struct.pack_into("<I", buffer, 84, capabilities)


class V4L2BackendTests(unittest.TestCase):
    def test_discovers_only_writable_rocam_loopback_output(self):
        opened = []

        def open_device(path, _flags):
            opened.append(path)
            return {"/dev/video0": 10, "/dev/video1": 11, "/dev/video2": 12}[path]

        def ioctl(fd, request, buffer, *_args):
            self.assertEqual(request, rocam_v4l2.VIDIOC_QUERYCAP)
            if fd == 10:
                _querycap(buffer, card=b"LeHome", capabilities=rocam_v4l2.V4L2_CAP_VIDEO_CAPTURE)
            elif fd == 11:
                _querycap(buffer, card=b"Rocam", driver=b"uvcvideo")
            else:
                _querycap(buffer)

        with (
            patch("rocam_v4l2.os.open", side_effect=open_device),
            patch("rocam_v4l2.os.close") as close,
            patch("rocam_v4l2.fcntl.ioctl", side_effect=ioctl),
            patch("rocam_v4l2._kernel_card_name", side_effect=["LeHome", "Other", "Rocam"]),
        ):
            self.assertEqual(
                rocam_v4l2.find_rocam_device(("/dev/video0", "/dev/video1", "/dev/video2")),
                "/dev/video2",
            )

        self.assertEqual(opened, ["/dev/video2"])
        self.assertEqual(close.call_args_list, [((12,),)])

    def test_streams_on_writer_descriptor_before_writing(self):
        calls = []

        def ioctl(fd, request, buffer, *_args):
            calls.append((fd, request, bytes(buffer)))
            if request == rocam_v4l2.VIDIOC_QUERYCAP:
                _querycap(buffer)

        with (
            patch("rocam_v4l2.os.open", return_value=44),
            patch("rocam_v4l2.os.close") as close,
            patch("rocam_v4l2.fcntl.ioctl", side_effect=ioctl),
            patch("rocam_v4l2.os.write", return_value=12) as write,
        ):
            backend = rocam_v4l2.RocamV4L2Backend(
                width=2,
                height=2,
                fps=20,
                fourcc=rocam_v4l2.RGB_FOURCC,
                device="/dev/video11",
            )
            backend.send(np.arange(12, dtype=np.uint8))
            backend.close()

        self.assertEqual([fd for fd, _request, _buffer in calls], [44, 44, 44, 44])
        self.assertEqual(
            [request for _fd, request, _buffer in calls],
            [
                rocam_v4l2.VIDIOC_QUERYCAP,
                rocam_v4l2.VIDIOC_S_FMT,
                rocam_v4l2.VIDIOC_STREAMON,
                rocam_v4l2.VIDIOC_STREAMOFF,
            ],
        )
        configured = calls[1][2]
        self.assertEqual(struct.unpack_from("<I", configured, 0), (rocam_v4l2.V4L2_BUF_TYPE_VIDEO_OUTPUT,))
        self.assertEqual(struct.unpack_from("<III", configured, 8), (2, 2, rocam_v4l2.V4L2_PIX_FMT_RGB24))
        self.assertEqual(calls[2][2], struct.pack("<I", rocam_v4l2.V4L2_BUF_TYPE_VIDEO_OUTPUT))
        write.assert_called_once_with(44, bytes(range(12)))
        close.assert_called_once_with(44)

    def test_partial_write_fails_without_publishing_a_second_frame_tail(self):
        def ioctl(_fd, request, buffer, *_args):
            if request == rocam_v4l2.VIDIOC_QUERYCAP:
                _querycap(buffer)

        writes = []
        def write(_fd, data):
            writes.append(bytes(data))
            return 3

        with (
            patch("rocam_v4l2.os.open", return_value=44),
            patch("rocam_v4l2.os.close"),
            patch("rocam_v4l2.fcntl.ioctl", side_effect=ioctl),
            patch("rocam_v4l2.os.write", side_effect=write),
        ):
            backend = rocam_v4l2.RocamV4L2Backend(
                width=2, height=2, fps=20, fourcc=rocam_v4l2.RGB_FOURCC, device="/dev/video11"
            )
            with self.assertRaisesRegex(RuntimeError, "partial"):
                backend.send(np.arange(12, dtype=np.uint8))
            backend.close()

        self.assertEqual(writes, [bytes(range(12))])

    def test_explicit_non_rocam_output_is_rejected_before_configuration(self):
        calls = []

        def ioctl(_fd, request, buffer, *_args):
            calls.append(request)
            if request == rocam_v4l2.VIDIOC_QUERYCAP:
                _querycap(buffer, card=b"LeHome")

        with (
            patch("rocam_v4l2.os.open", return_value=44),
            patch("rocam_v4l2.os.close") as close,
            patch("rocam_v4l2.fcntl.ioctl", side_effect=ioctl),
            self.assertRaisesRegex(RuntimeError, "Rocam"),
        ):
            rocam_v4l2.RocamV4L2Backend(
                width=2, height=2, fps=20, fourcc=rocam_v4l2.RGB_FOURCC, device="/dev/video10"
            )

        self.assertEqual(calls, [rocam_v4l2.VIDIOC_QUERYCAP])
        close.assert_called_once_with(44)

    def test_failed_stream_start_closes_the_writer_descriptor(self):
        def ioctl(_fd, request, buffer, *_args):
            if request == rocam_v4l2.VIDIOC_QUERYCAP:
                _querycap(buffer)
            if request == rocam_v4l2.VIDIOC_STREAMON:
                raise OSError(errno.EIO, "stream start failed")

        with (
            patch("rocam_v4l2.os.open", return_value=44),
            patch("rocam_v4l2.os.close") as close,
            patch("rocam_v4l2.fcntl.ioctl", side_effect=ioctl),
            self.assertRaisesRegex(RuntimeError, "stream"),
        ):
            rocam_v4l2.RocamV4L2Backend(
                width=2, height=2, fps=20, fourcc=rocam_v4l2.RGB_FOURCC, device="/dev/video11"
            )

        close.assert_called_once_with(44)


if __name__ == "__main__":
    unittest.main()
