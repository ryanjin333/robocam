import io
import os
import runpy
import struct
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler
from unittest.mock import patch

import rocam_audio
from rocam_audio import AudioError, audio_url, read_wav_header, run_audio


KEY = "a" * 32


def wav_header(rate=48000, *, channels=1, bits=16):
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 0xFFFFFFF7, b"WAVE", b"fmt ", 16, 1,
        channels, rate, rate * channels * bits // 8, channels * bits // 8,
        bits, b"data", 0xFFFFFFD3,
    )


class AudioTests(unittest.TestCase):
    def test_audio_url_uses_only_authenticated_connection_url(self):
        self.assertEqual(
            audio_url(f"http://phone:8765/?key={KEY}"),
            f"http://phone:8765/audio.wav?key={KEY}",
        )
        with self.assertRaises(AudioError) as caught:
            audio_url(f"http://phone/?key={KEY}&other=1")
        self.assertNotIn(KEY, str(caught.exception))

    def test_audio_url_accepts_compressed_video_connection(self):
        self.assertEqual(
            audio_url(f"http://phone/video.hevc?key={KEY}"),
            f"http://phone/audio.wav?key={KEY}",
        )

    def test_header_validates_pcm_format_and_rate(self):
        self.assertEqual(read_wav_header(io.BytesIO(wav_header(44100))), 44100)
        for header in (
            wav_header(channels=2), wav_header(bits=8),
            b"NOPE" + wav_header()[4:], wav_header()[:20],
        ):
            with self.subTest(header=header), self.assertRaises(AudioError):
                read_wav_header(io.BytesIO(header))

    def test_http_stream_reconnects_and_stops_with_bounded_reads(self):
        payloads = [b"\x01\x00\x02\x00", b"\x03\x00\x04\x00"]
        paths = []
        responses = []
        stop = threading.Event()
        streams = []
        statuses = []

        class Response(io.BytesIO):
            def __init__(self, payload):
                super().__init__(wav_header() + payload)
                self.read_sizes = []
                responses.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

            def read1(self, size):
                self.read_sizes.append(size)
                return self.read(min(size, 3))

        def opener(request, *, timeout):
            paths.append(request.full_url)
            self.assertLessEqual(timeout, 1.0)
            return Response(payloads[len(paths) - 1])

        class FakeStream:
            def __init__(self, **kwargs):
                self.options = kwargs
                self.writes = []
                self.closed = False
                streams.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.closed = True

            def write(self, data):
                self.writes.append(bytes(data))
                if sum(map(len, self.writes)) == 4 and len(streams) == 2:
                    stop.set()

        run_audio(
            f"http://phone:8765/?key={KEY}",
            "BlackHole 2ch", stop, statuses.append,
            opener=opener, stream_factory=FakeStream, retry_seconds=0,
        )

        self.assertEqual(paths, [f"http://phone:8765/audio.wav?key={KEY}"] * 2)
        self.assertEqual([b"".join(s.writes) for s in streams], payloads)
        self.assertTrue(all(s.closed for s in streams))
        self.assertTrue(all(all(n <= 4096 for n in r.read_sizes) for r in responses))
        self.assertTrue(all(s.options["device"] == "BlackHole 2ch" for s in streams))
        self.assertTrue(all(s.options["samplerate"] == 48000 for s in streams))
        self.assertTrue(any("reconnect" in status.lower() for status in statuses))
        self.assertNotIn(KEY, " ".join(statuses))

    def test_missing_microphone_reports_status_and_retries(self):
        stop = threading.Event()
        statuses = []

        def opener(*_, **__):
            raise HTTPError("redacted", 404, "Not Found", {}, io.BytesIO())

        def on_status(status):
            statuses.append(status)
            stop.set()

        run_audio(
            f"http://phone/?key={KEY}", "Loopback", stop, on_status,
            opener=opener, stream_factory=lambda **_: None,
        )
        self.assertTrue(any("microphone" in s.lower() for s in statuses))
        self.assertNotIn(KEY, " ".join(statuses))

    def test_default_http_opener_disables_proxies(self):
        with patch.dict(os.environ, {"http_proxy": "http://proxy.invalid:8080"}):
            isolated = runpy.run_path(rocam_audio.__file__)
        direct_opener = isolated["_DIRECT_OPENER"]
        proxy_handlers = [
            handler for handler in direct_opener.handlers
            if isinstance(handler, ProxyHandler)
        ]
        # An empty ProxyHandler is omitted by OpenerDirector after it prevents
        # build_opener from installing the environment-configured handler.
        self.assertEqual(proxy_handlers, [])

        stop = threading.Event()
        requests = []

        def direct_open(request, *, timeout):
            requests.append(request.full_url)
            raise HTTPError("redacted", 404, "Not Found", {}, io.BytesIO())

        def on_status(_status):
            stop.set()

        with patch.object(direct_opener, "open", side_effect=direct_open):
            isolated["run_audio"](f"http://phone/?key={KEY}", "Loopback", stop, on_status)
        self.assertEqual(requests, [f"http://phone/audio.wav?key={KEY}"])


if __name__ == "__main__":
    unittest.main()
