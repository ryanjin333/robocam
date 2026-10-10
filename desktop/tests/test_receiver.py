import io
import types
import threading
import unittest
from contextlib import nullcontext, redirect_stderr, redirect_stdout
from unittest.mock import patch
from urllib.error import HTTPError

import numpy as np
from urllib.request import ProxyHandler

from rocam_receiver import (
    MAX_PART_BYTES,
    DIRECT_OPENER,
    ReceiverError,
    StreamFormatError,
    decode_jpeg,
    create_camera,
    discover_usb_session,
    mjpeg_frames,
    main,
    receive,
    stream_url,
    usb_forwarder,
)


KEY = "a" * 32


def part(payload: bytes) -> bytes:
    return (
        b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
        + str(len(payload)).encode()
        + b"\r\n\r\n"
        + payload
        + b"\r\n"
    )


class _MalformedSessionResponse(io.BytesIO):
    headers = {"Content-Type": "text/plain"}

    def __init__(self):
        super().__init__(b"not a session")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def geturl(self):
        return "http://127.0.0.1:8765/usb/session"


class UrlTests(unittest.TestCase):
    def test_full_connection_url_and_depth_or_usb(self):
        base = f"http://192.168.1.7:8765/?key={KEY}"
        self.assertEqual(stream_url(base), f"http://192.168.1.7:8765/stream?key={KEY}")
        self.assertEqual(stream_url(base, depth=True), f"http://192.168.1.7:8765/depth.mjpg?key={KEY}")
        self.assertEqual(stream_url(base, usb=True), f"http://127.0.0.1:8765/stream?key={KEY}")

    def test_selects_compressed_endpoint_and_rejects_depth_mix(self):
        base = f"http://192.168.1.7:8765/video.h264?key={KEY}"
        self.assertEqual(stream_url(base, codec="h264"), f"http://192.168.1.7:8765/video.h264?key={KEY}")
        self.assertEqual(stream_url(base, codec="hevc"), f"http://192.168.1.7:8765/video.hevc?key={KEY}")
        with self.assertRaises(ReceiverError):
            stream_url(base, depth=True, codec="h264")

    def test_invalid_url_never_exposes_key(self):
        for url in (f"https://phone/?key={KEY}", f"http://phone/?key={KEY}&x=1", "http://phone/?key=bad"):
            with self.subTest(url=url), self.assertRaises(ReceiverError) as caught:
                stream_url(url)
            self.assertNotIn(KEY, str(caught.exception))


class ParserTests(unittest.TestCase):
    def test_reads_content_length_even_when_jpeg_contains_boundary(self):
        first = b"\xff\xd8--frame\r\n\xff\xd9"
        second = b"\xff\xd8\xff\xd9"
        stream = io.BytesIO(part(first) + part(second) + b"--frame--\r\n")
        self.assertEqual(list(mjpeg_frames(stream)), [first, second])

    def test_rejects_oversized_or_truncated_frame(self):
        oversized = b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(MAX_PART_BYTES + 1).encode() + b"\r\n\r\n"
        truncated = b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\nabc"
        for stream in (oversized, truncated):
            with self.subTest(stream=stream), self.assertRaises(StreamFormatError):
                list(mjpeg_frames(io.BytesIO(stream)))

    def test_rejects_oversized_headers(self):
        stream = b"--frame\r\nX: " + b"x" * 9000 + b"\r\n\r\n"
        with self.assertRaises(StreamFormatError):
            list(mjpeg_frames(io.BytesIO(stream)))

    def test_decodes_jpeg_to_rgb_array(self):
        from PIL import Image

        image = Image.new("RGB", (4, 3), (255, 0, 0))
        data = io.BytesIO()
        image.save(data, format="JPEG")
        frame = decode_jpeg(data.getvalue())
        self.assertEqual(frame.shape, (3, 4, 3))
        self.assertTrue(frame.flags["C_CONTIGUOUS"])


class ReceiverTests(unittest.TestCase):
    def test_linux_camera_uses_only_the_rocam_v4l2_backend(self):
        camera_calls = []
        registrations = []
        virtualcam = types.SimpleNamespace(
            Camera=lambda **kwargs: camera_calls.append(kwargs) or object(),
            register_backend=lambda name, backend: registrations.append((name, backend)),
        )
        backend = types.SimpleNamespace(
            find_rocam_device=lambda: "/dev/video11",
            RocamV4L2Backend=object,
            register_backend=lambda virtualcam_module: virtualcam_module.register_backend("rocam-v4l2", object),
        )
        with (
            patch.dict("sys.modules", {"pyvirtualcam": virtualcam, "rocam_v4l2": backend}),
            patch("rocam_receiver.sys.platform", "linux"),
        ):
            create_camera(640, 480, 20)

        self.assertEqual(registrations, [("rocam-v4l2", object)])
        self.assertEqual(
            camera_calls,
            [{"width": 640, "height": 480, "fps": 20, "backend": "rocam-v4l2", "device": "/dev/video11"}],
        )

    def test_linux_camera_refuses_to_fall_back_to_a_foreign_device(self):
        virtualcam = types.SimpleNamespace(Camera=lambda **_kwargs: self.fail("must not choose pyvirtualcam default"))
        backend = types.SimpleNamespace(find_rocam_device=lambda: None, register_backend=lambda _virtualcam: None)
        with (
            patch.dict("sys.modules", {"pyvirtualcam": virtualcam, "rocam_v4l2": backend}),
            patch("rocam_receiver.sys.platform", "linux"),
            self.assertRaisesRegex(ReceiverError, "Rocam.*v4l2loopback"),
        ):
            create_camera(640, 480, 20)

    def test_compressed_missing_decoder_fails_before_network(self):
        with patch("rocam_video.AVDecoder.available", return_value=False):
            with self.assertRaisesRegex(ReceiverError, "video extra"):
                receive(f"http://phone/video.h264?key={KEY}", codec="h264", opener=lambda *_: self.fail("network"))

    def test_compressed_decode_does_not_sleep_reader(self):
        from rocam_video import CODEC_H264, FLAG_KEYFRAME, HEADER

        payload = b"\x00\x00\x00\x01\x67\x64\x00\x1f"
        encoded = HEADER.pack(b"RCV1", CODEC_H264, FLAG_KEYFRAME, 0, len(payload), 3, 2, 1, 0) + payload

        class Response(io.BytesIO):
            headers = {"Content-Type": "application/x-rocam-video"}
            def __enter__(self): return self
            def __exit__(self, *_): self.close()

        class Decoder:
            def decode(self, _packet): return [np.full((2, 3, 3), 40, dtype=np.uint8)]
            def reset(self): pass

        sent, sleeps = [], []
        class Camera:
            def __init__(self, *_): pass
            def send(self, frame): sent.append(frame.copy())
            def sleep_until_next_frame(self): sleeps.append(True)
            def close(self): pass

        receive(f"http://phone/video.h264?key={KEY}", codec="h264", compressed_decoder=Decoder(),
                opener=lambda *_args, **_kwargs: Response(encoded), camera_factory=Camera,
                stopped=lambda: len(sent) == 1, pause=lambda _: None, message=lambda _: None)
        self.assertEqual(len(sent), 2)  # live frame and final blackout
        self.assertEqual(sleeps, [])
    def test_stop_during_camera_creation_does_not_publish_live_frame(self):
        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        stopped = threading.Event()
        sent = []

        class Camera:
            def send(self, frame):
                sent.append(frame.copy())

            def sleep_until_next_frame(self):
                pass

            def close(self):
                pass

        def make_camera(*_args):
            stopped.set()
            return Camera()

        receive(
            f"http://phone/stream?key={KEY}",
            opener=lambda *_args, **_kwargs: Response(part(b"one") + b"--frame--\r\n"),
            decoder=lambda _: np.full((2, 3, 3), 100, dtype=np.uint8),
            camera_factory=make_camera,
            stopped=stopped.is_set,
            message=lambda _: None,
        )
        self.assertFalse(any(np.all(frame == 100) for frame in sent))

    def test_stop_after_decode_does_not_publish_frame_or_retry(self):
        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        stopped = threading.Event()
        sent = []
        pauses = []

        class Camera:
            def __init__(self, *_):
                pass

            def send(self, frame):
                sent.append(frame.copy())

            def sleep_until_next_frame(self):
                pass

            def close(self):
                pass

        def decode(_data):
            stopped.set()
            return np.full((2, 3, 3), 100, dtype=np.uint8)

        receive(
            f"http://phone/stream?key={KEY}",
            opener=lambda *_args, **_kwargs: Response(part(b"one") + b"--frame--\r\n"),
            decoder=decode,
            camera_factory=Camera,
            stopped=stopped.is_set,
            pause=pauses.append,
            message=lambda _: None,
        )
        self.assertEqual(sent, [])
        self.assertEqual(pauses, [])

    def test_forbidden_response_does_not_reveal_key(self):
        url = f"http://phone/stream?key={KEY}"

        def forbidden(*_args, **_kwargs):
            raise HTTPError(url, 403, f"Forbidden: {KEY}", {}, None)

        with self.assertRaises(ReceiverError) as caught:
            receive(url, opener=forbidden, message=lambda _: None)
        self.assertNotIn(KEY, str(caught.exception))

    def test_forbidden_stream_refreshes_session_without_exposing_keys(self):
        next_key = "b" * 32

        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}
            def __enter__(self): return self
            def __exit__(self, *_): self.close()

        requests = []
        sent = []
        def opener(request, **_kwargs):
            requests.append(request.full_url)
            if len(requests) == 1:
                raise HTTPError(request.full_url, 403, "expired", {}, None)
            return Response(part(b"one") + b"--frame--\r\n")

        class Camera:
            def __init__(self, *_): pass
            def send(self, frame): sent.append(frame.copy())
            def sleep_until_next_frame(self): pass
            def close(self): pass

        messages = []
        receive(
            f"http://127.0.0.1:8765/stream?key={KEY}",
            opener=opener,
            decoder=lambda _: np.full((2, 3, 3), 100, dtype=np.uint8),
            camera_factory=Camera,
            refresh_session=lambda: f"http://127.0.0.1:8765/stream?key={next_key}",
            stopped=lambda: len(sent) == 1,
            message=messages.append,
            pause=lambda _: None,
        )
        self.assertEqual(requests, [
            f"http://127.0.0.1:8765/stream?key={KEY}",
            f"http://127.0.0.1:8765/stream?key={next_key}",
        ])
        self.assertNotIn(KEY, " ".join(messages))
        self.assertNotIn(next_key, " ".join(messages))

    def test_session_refresh_waits_before_retry_and_honors_stop(self):
        stopped = threading.Event()
        refreshes = []
        pauses = []

        def forbidden(request, **_kwargs):
            raise HTTPError(request.full_url, 403, "expired", {}, None)

        def pause(seconds):
            pauses.append(seconds)
            stopped.set()

        receive(
            f"http://127.0.0.1:8765/stream?key={KEY}",
            opener=forbidden,
            refresh_session=lambda: refreshes.append(True) or f"http://127.0.0.1:8765/stream?key={'b' * 32}",
            stopped=stopped.is_set,
            pause=pause,
            message=lambda _: None,
        )
        self.assertEqual(len(refreshes), 1)
        self.assertEqual(pauses, [2.0])

    def test_connection_state_clears_and_restores_controls_during_internal_retry(self):
        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}
            def __enter__(self): return self
            def __exit__(self, *_): self.close()

        responses = iter((
            Response(part(b"one") + b"--frame--\r\n"),
            Response(part(b"two") + b"--frame--\r\n"),
        ))
        live_frames = []
        states = []

        class Camera:
            def __init__(self, *_): pass
            def send(self, frame):
                if np.any(frame):
                    live_frames.append(frame.copy())
            def sleep_until_next_frame(self): pass
            def close(self): pass

        receive(
            f"http://127.0.0.1:8765/stream?key={KEY}",
            opener=lambda *_args, **_kwargs: next(responses),
            decoder=lambda _: np.full((2, 3, 3), 100, dtype=np.uint8),
            camera_factory=Camera,
            stopped=lambda: len(live_frames) == 2,
            pause=lambda _: None,
            message=lambda _: None,
            link_alive=lambda: True,
            connection_state=lambda usable, url: states.append((usable, url)),
        )
        self.assertEqual([usable for usable, _ in states], [True, False, True, False])
        self.assertEqual(states[0][1], states[2][1])

    def test_reconnects_and_reopens_camera_on_size_change(self):
        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

        cameras = []
        connections = iter((Response(part(b"one")), Response(part(b"two"))))
        sent = []

        class Camera:
            def __init__(self, width, height, fps):
                self.size = (width, height)
                self.fps = fps
                self.closed = False
                cameras.append(self)

            def send(self, frame):
                sent.append((self.size, frame.copy()))

            def sleep_until_next_frame(self):
                pass

            def close(self):
                self.closed = True

        receive(
            f"http://phone/stream?key={KEY}",
            opener=lambda *_args, **_kwargs: next(connections),
            decoder=lambda data: (
                np.full((480, 640, 3), 100, dtype=np.uint8)
                if data == b"one" else np.full((720, 1280, 3), 200, dtype=np.uint8)
            ),
            camera_factory=Camera,
            pause=lambda _: None,
            stopped=lambda: len(sent) == 3,
            message=lambda _: None,
        )
        self.assertEqual([camera.size for camera in cameras], [(640, 480), (1280, 720)])
        self.assertEqual([camera.fps for camera in cameras], [20, 20])
        self.assertTrue(all(camera.closed for camera in cameras))
        self.assertEqual([size for size, _ in sent], [(640, 480), (640, 480), (1280, 720), (1280, 720)])
        self.assertTrue(np.all(sent[0][1] == 100))
        self.assertTrue(np.all(sent[1][1] == 0))  # No stale image while reconnecting.
        self.assertTrue(np.all(sent[2][1] == 200))  # Live video resumes.
        self.assertTrue(np.all(sent[3][1] == 0))  # Stop leaves no stale image.

    def test_ctrl_c_clears_last_frame(self):
        sent = []

        class Response(io.BytesIO):
            headers = {"Content-Type": "multipart/x-mixed-replace; boundary=frame"}

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

            def readline(self, size=-1):
                if self.tell() == len(self.getvalue()):
                    raise KeyboardInterrupt
                return super().readline(size)

        class Camera:
            def __init__(self, *_):
                pass

            def send(self, frame):
                sent.append(frame.copy())

            def sleep_until_next_frame(self):
                pass

            def close(self):
                pass

        with self.assertRaises(KeyboardInterrupt):
            receive(
                f"http://phone/stream?key={KEY}",
                opener=lambda *_args, **_kwargs: Response(part(b"one")),
                decoder=lambda _: np.full((2, 3, 3), 100, dtype=np.uint8),
                camera_factory=Camera,
                message=lambda _: None,
            )
        self.assertEqual(len(sent), 2)
        self.assertTrue(np.all(sent[0] == 100))
        self.assertTrue(np.all(sent[1] == 0))

    def test_http_error_response_is_closed(self):
        error = HTTPError(f"http://phone/stream?key={KEY}", 403, "Forbidden", {}, None)
        with (
            patch.object(error, "close", wraps=error.close) as close,
            self.assertRaises(ReceiverError),
        ):
            receive(f"http://phone/stream?key={KEY}", opener=lambda *_args, **_kwargs: (_ for _ in ()).throw(error))
        close.assert_called_once()

    def test_default_opener_has_no_proxy_handler(self):
        self.assertFalse(any(isinstance(handler, ProxyHandler) for handler in DIRECT_OPENER.__self__.handlers))


class UsbTests(unittest.TestCase):
    def test_usb_session_discovery_requires_the_forwarder_context(self):
        opened = []

        with self.assertRaisesRegex(ReceiverError, "USB forwarder"):
            discover_usb_session(lambda: True, opener=lambda *_args, **_kwargs: opened.append(True))
        self.assertEqual(opened, [])

    def test_usb_session_discovery_uses_loopback_headers_and_validates_response(self):
        class Process:
            def poll(self):
                return None
            def terminate(self):
                pass
            def wait(self, timeout=None):
                return 0

        class Response(io.BytesIO):
            headers = {"Content-Type": "application/json; charset=utf-8"}
            def __enter__(self): return self
            def __exit__(self, *_): self.close()
            def geturl(self): return "http://127.0.0.1:8765/usb/session"

        requests = []
        def opener(request, *, timeout):
            requests.append((request, timeout))
            return Response((f'{{"protocolVersion":1,"key":"{KEY}"}}').encode())

        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.subprocess.Popen", return_value=Process()),
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True) as link:
                self.assertEqual(discover_usb_session(link, opener=opener), f"http://127.0.0.1:8765/?key={KEY}")
        self.assertEqual(requests[0][0].full_url, "http://127.0.0.1:8765/usb/session")
        self.assertEqual(requests[0][0].get_header("Host"), "127.0.0.1:8765")
        self.assertEqual(requests[0][0].get_header("X-rocam-usb"), "1")
        self.assertIsNone(requests[0][0].get_header("Origin"))
        self.assertIsNone(requests[0][0].get_header("Sec-fetch-site"))

    def test_usb_session_discovery_rejects_redirect_and_malformed_payload_without_key(self):
        class Process:
            def poll(self): return None
            def terminate(self): pass
            def wait(self, timeout=None): return 0

        def redirect(*_args, **_kwargs):
            raise HTTPError("http://127.0.0.1:8765/usb/session", 302, "redirect", {}, None)

        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.subprocess.Popen", return_value=Process()),
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True) as link:
                for opener in (redirect, lambda *_args, **_kwargs: _MalformedSessionResponse()):
                    with self.subTest(opener=opener), self.assertRaises(ReceiverError) as caught:
                        discover_usb_session(link, opener=opener)
                    self.assertNotIn(KEY, str(caught.exception))

    def test_iproxy_uses_local_to_device_port_syntax_and_stops(self):
        class Process:
            terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                return 0

        process = Process()
        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.subprocess.Popen", return_value=process) as launch,
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True) as alive:
                self.assertTrue(alive())
            self.assertTrue(process.terminated)
        self.assertEqual(
            launch.call_args.args[0],
            ["/usr/bin/iproxy", "--local", "--source", "127.0.0.1", "8765:8765"],
        )

    def test_iproxy_selects_requested_iphone(self):
        udid = "00000000-0000000000000001"

        class Process:
            def poll(self):
                return None

            def terminate(self):
                pass

            def wait(self, timeout=None):
                return 0

        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.subprocess.Popen", return_value=Process()) as launch,
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True, udid):
                pass
        self.assertEqual(
            launch.call_args.args[0],
            [
                "/usr/bin/iproxy",
                "--local",
                "--udid",
                udid,
                "--source",
                "127.0.0.1",
                "8765:8765",
            ],
        )

    def test_iproxy_uses_homebrew_path_for_finder_launched_macos_app(self):
        class Process:
            def poll(self): return None
            def terminate(self): pass
            def wait(self, timeout=None): return 0

        with (
            patch("rocam_receiver.shutil.which", return_value=None),
            patch("rocam_receiver.sys.platform", "darwin"),
            patch("rocam_receiver.os.path.isfile", side_effect=lambda path: path == "/opt/homebrew/bin/iproxy"),
            patch("rocam_receiver.os.access", return_value=True),
            patch("rocam_receiver.subprocess.Popen", return_value=Process()) as launch,
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True):
                pass
        self.assertEqual(launch.call_args.args[0][0], "/opt/homebrew/bin/iproxy")

    def test_iproxy_reports_a_busy_usb_port_without_retrying(self):
        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.socket.socket", side_effect=OSError("busy")),
            self.assertRaisesRegex(ReceiverError, "port 8765 is already in use"),
        ):
            with usb_forwarder(True):
                pass

    def test_iproxy_forwarder_can_reopen_after_its_listener_closes(self):
        import socket

        class Process:
            def __init__(self):
                self._closed = False
                self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.listener.bind(("127.0.0.1", 8765))
                self.listener.listen(1)

            def poll(self): return 0 if self._closed else None
            def terminate(self):
                self._closed = True
                self.listener.close()
            def wait(self, timeout=None): return 0

        processes = []
        def launch(*_args, **_kwargs):
            process = Process()
            processes.append(process)
            return process

        with (
            patch("rocam_receiver.shutil.which", return_value="/usr/bin/iproxy"),
            patch("rocam_receiver.subprocess.Popen", side_effect=launch),
            patch("rocam_receiver.time.sleep"),
        ):
            with usb_forwarder(True):
                with socket.create_connection(("127.0.0.1", 8765), timeout=1):
                    pass
            with usb_forwarder(True):
                pass
        self.assertEqual(len(processes), 2)


class CliTests(unittest.TestCase):
    def test_usb_without_url_discovers_session_without_prompting(self):
        discovered = []
        received = []

        with (
            patch("rocam_receiver.usb_forwarder", return_value=nullcontext(lambda: True)),
            patch("rocam_receiver.discover_usb_session", side_effect=lambda link: discovered.append(link) or f"http://127.0.0.1:8765/?key={KEY}"),
            patch("rocam_receiver._connection_url") as prompt,
            patch("rocam_receiver.receive", side_effect=lambda url, **kwargs: received.append((url, kwargs))),
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(main(["--usb"]), 0)
        prompt.assert_not_called()
        self.assertEqual(len(discovered), 1)
        self.assertEqual(received[0][0], f"http://127.0.0.1:8765/stream?key={KEY}")
        self.assertTrue(callable(received[0][1]["refresh_session"]))

    def test_cli_accepts_120_fps(self):
        with (
            patch("rocam_receiver.receive") as video,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(main([f"http://phone:8765/?key={KEY}", "--fps", "120"]), 0)
        self.assertEqual(video.call_args.kwargs["fps"], 120)

    def test_cli_rejects_fps_above_120(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([f"http://phone:8765/?key={KEY}", "--fps", "121"])

    def test_omitted_url_prompts_privately(self):
        class TtyInput:
            def isatty(self):
                return True

        with (
            patch("rocam_receiver.sys.stdin", TtyInput()),
            patch("rocam_receiver.getpass.getpass", return_value=f"http://phone:8765/?key={KEY}") as prompt,
            patch("rocam_receiver.receive") as video,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(main([]), 0)
        prompt.assert_called_once()
        self.assertEqual(video.call_args.args[0], f"http://phone:8765/stream?key={KEY}")

    def test_omitted_url_accepts_stdin_without_echoing_key(self):
        output = io.StringIO()
        with (
            patch("rocam_receiver.sys.stdin", io.StringIO(f"http://phone:8765/?key={KEY}\n")),
            patch("rocam_receiver.receive") as video,
            redirect_stdout(output),
        ):
            self.assertEqual(main([]), 0)
        self.assertEqual(video.call_args.args[0], f"http://phone:8765/stream?key={KEY}")
        self.assertNotIn(KEY, output.getvalue())

    def test_udid_requires_usb(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main([f"http://phone:8765/?key={KEY}", "--udid", "00000000-0000000000000001"])

    def test_audio_option_uses_normalized_usb_url_and_stops(self):
        urls = []
        audio_calls = []

        def fake_audio(url, device, stop_event, on_status, **_kwargs):
            audio_calls.append((url, device, stop_event))

        with (
            patch("rocam_receiver.usb_forwarder", return_value=nullcontext(lambda: True)),
            patch("rocam_receiver.receive", side_effect=lambda url, **_: urls.append(url)),
            patch("rocam_audio.run_audio", side_effect=fake_audio),
            redirect_stdout(io.StringIO()),
        ):
            result = main([f"http://phone:8765/?key={KEY}", "--usb", "--depth", "--audio-output", "BlackHole 2ch"])
        self.assertEqual(result, 0)
        self.assertEqual(urls, [f"http://127.0.0.1:8765/depth.mjpg?key={KEY}"])
        self.assertEqual([(url, device) for url, device, _ in audio_calls], [(urls[0], "BlackHole 2ch")])
        self.assertTrue(audio_calls[0][2].is_set())

    def test_without_audio_option_does_not_start_audio(self):
        with (
            patch("rocam_receiver.receive"),
            patch("rocam_audio.run_audio") as audio,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(main([f"http://phone:8765/?key={KEY}"]), 0)
        audio.assert_not_called()

    def test_unexpected_audio_error_does_not_expose_session_key(self):
        errors = io.StringIO()
        with (
            patch("rocam_receiver.receive"),
            patch("rocam_audio.run_audio", side_effect=RuntimeError(KEY)),
            redirect_stdout(io.StringIO()),
            redirect_stderr(errors),
        ):
            self.assertEqual(main([f"http://phone:8765/?key={KEY}", "--audio-output", "BlackHole 2ch"]), 0)
        self.assertIn("Microphone forwarding stopped unexpectedly", errors.getvalue())
        self.assertNotIn(KEY, errors.getvalue())


if __name__ == "__main__":
    unittest.main()
