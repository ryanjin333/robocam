"""Turn a Rocam MJPEG stream into an operating-system virtual camera."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import getpass
from io import BytesIO
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from typing import Callable, Iterator
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from rocam_video import VideoDecoderError, VideoFormatError


MAX_PART_BYTES = 16 * 1024 * 1024
MAX_HEADERS_BYTES = 8 * 1024
MAX_USB_SESSION_BYTES = 8 * 1024
KEY_PATTERN = re.compile(r"[0-9a-fA-F]{32}\Z")
UDID_PATTERN = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})\Z")
DIRECT_OPENER = build_opener(ProxyHandler({})).open


class _RejectRedirects(HTTPRedirectHandler):
    """Keep the USB bootstrap pinned to the paired-phone loopback service."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


USB_SESSION_OPENER = build_opener(ProxyHandler({}), _RejectRedirects()).open


class ReceiverError(Exception):
    """A user-facing receiver error with no session URL or key."""


class StreamFormatError(ReceiverError):
    """The peer sent an invalid or oversized MJPEG part."""


class UsbTransportError(ReceiverError):
    """A reconnectable loss of the local USB forwarding transport."""


class UsbBootstrapUnavailable(UsbTransportError):
    """The paired phone is reachable later, but its app session is not ready yet."""


class _UsbForwarderLink:
    """Opaque capability proving discovery runs inside our iproxy context."""

    def __init__(self, process) -> None:
        self._process = process

    def __call__(self) -> bool:
        return self._process.poll() is None


def discover_usb_session(link_alive: Callable[[], bool], *, opener: Callable | None = None,
                         timeout: float = 2.0) -> str:
    """Fetch a short-lived phone session only through the active local USB forwarder.

    The returned value is a regular Rocam connection URL so callers can select
    their own color/depth endpoint without handling the credential directly.
    """
    if not isinstance(link_alive, _UsbForwarderLink):
        raise ReceiverError("USB session discovery requires the active Rocam USB forwarder.")
    if not link_alive():
        raise UsbTransportError("USB forwarding stopped; reconnecting.")
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        raise ReceiverError("USB session discovery timeout must be positive.")
    request = Request(
        "http://127.0.0.1:8765/usb/session",
        headers={
            "Host": "127.0.0.1:8765",
            "X-Rocam-USB": "1",
            "User-Agent": "Rocam-Webcam/0.1",
        },
    )
    open_session = opener or USB_SESSION_OPENER
    try:
        with open_session(request, timeout=timeout) as response:
            response_url = getattr(response, "geturl", lambda: request.full_url)()
            parsed = urlsplit(response_url)
            if (
                parsed.scheme.lower() != "http"
                or parsed.hostname != "127.0.0.1"
                or parsed.port != 8765
                or parsed.path != "/usb/session"
                or parsed.query
                or parsed.fragment
            ):
                raise ReceiverError("Rocam USB session response was redirected.")
            content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise ReceiverError("Rocam USB session response has an invalid content type.")
            raw = response.read(MAX_USB_SESSION_BYTES + 1)
            if len(raw) > MAX_USB_SESSION_BYTES:
                raise ReceiverError("Rocam USB session response is too large.")
    except HTTPError as exc:
        code = exc.code
        exc.close()
        if 300 <= code < 400:
            raise ReceiverError("Rocam USB session response was redirected.") from None
        if code in (401, 403, 404) or 500 <= code < 600:
            raise UsbBootstrapUnavailable("Waiting for the Rocam iPhone or iPad app over USB.") from None
        raise ReceiverError(f"Rocam USB session request returned HTTP {code}.") from None
    except (URLError, OSError, TimeoutError, ValueError):
        raise UsbBootstrapUnavailable("Waiting for the Rocam iPhone or iPad over USB.") from None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ReceiverError("Rocam USB session response is not valid JSON.") from None
    if (
        not isinstance(payload, dict)
        or set(payload) != {"protocolVersion", "key"}
        or type(payload["protocolVersion"]) is not int
        or payload["protocolVersion"] != 1
        or not isinstance(payload["key"], str)
        or not KEY_PATTERN.fullmatch(payload["key"])
    ):
        raise ReceiverError("Rocam USB session response has an invalid schema.")
    return urlunsplit(("http", "127.0.0.1:8765", "/", urlencode({"key": payload["key"]}), ""))


def stream_url(connection_url: str, *, depth: bool = False, usb: bool = False, codec: str = "mjpeg") -> str:
    """Accept a Connection URL and select MJPEG, H.264, or HEVC without exposing its key."""
    try:
        parsed = urlsplit(connection_url)
        port = parsed.port  # Validate malformed ports before making a request.
        items = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
    except ValueError:
        raise ReceiverError("Invalid Rocam Connection URL.") from None
    if (
        parsed.scheme.lower() != "http"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or parsed.path not in ("", "/", "/stream", "/depth.mjpg", "/video.h264", "/video.hevc")
        or len(items) != 1
        or items[0][0] != "key"
        or not KEY_PATTERN.fullmatch(items[0][1])
    ):
        raise ReceiverError("Expected a Rocam HTTP Connection URL with a 32-character session key.")
    if port is not None and port == 0:
        raise ReceiverError("Invalid Rocam Connection URL port.")
    if codec not in ("mjpeg", "h264", "hevc"):
        raise ReceiverError("Choose MJPEG, H.264, or HEVC video.")
    if depth and codec != "mjpeg":
        raise ReceiverError("LiDAR depth uses the MJPEG stream. Choose MJPEG or remove --depth.")
    netloc = "127.0.0.1:8765" if usb else parsed.netloc
    path = "/depth.mjpg" if depth else {"mjpeg": "/stream", "h264": "/video.h264", "hevc": "/video.hevc"}[codec]
    return urlunsplit(("http", netloc, path, urlencode({"key": items[0][1]}), ""))


def _line(source, remaining: int) -> bytes:
    if remaining <= 0:
        raise StreamFormatError("MJPEG part headers exceed 8 KiB.")
    line = source.readline(remaining + 1)
    if len(line) > remaining or (line and not line.endswith(b"\n")):
        raise StreamFormatError("MJPEG part headers are too large or incomplete.")
    return line


def _read_exact(source, count: int) -> bytes:
    chunks = []
    while count:
        chunk = source.read(count)
        if not chunk:
            raise StreamFormatError("MJPEG frame ended early.")
        chunks.append(chunk)
        count -= len(chunk)
    return b"".join(chunks)


def mjpeg_frames(source) -> Iterator[bytes]:
    """Parse Rocam's bounded, Content-Length-delimited multipart stream."""
    boundary = _line(source, MAX_HEADERS_BYTES)
    while boundary:
        if boundary == b"--frame--\r\n":
            return
        if boundary != b"--frame\r\n":
            raise StreamFormatError("Unexpected MJPEG boundary.")
        remaining = MAX_HEADERS_BYTES
        headers: dict[bytes, bytes] = {}
        while True:
            line = _line(source, remaining)
            remaining -= len(line)
            if not line:
                raise StreamFormatError("MJPEG part headers ended early.")
            if line == b"\r\n":
                break
            if b":" not in line:
                raise StreamFormatError("Invalid MJPEG part header.")
            name, value = line.split(b":", 1)
            name = name.strip().lower()
            if name in headers:
                raise StreamFormatError("Duplicate MJPEG part header.")
            headers[name] = value.strip()
        length_text = headers.get(b"content-length", b"")
        if not length_text.isdigit():
            raise StreamFormatError("MJPEG part has no valid Content-Length.")
        try:
            length = int(length_text)
        except ValueError:
            raise StreamFormatError("MJPEG part has no valid Content-Length.") from None
        if not 0 < length <= MAX_PART_BYTES:
            raise StreamFormatError("MJPEG frame exceeds the 16 MiB limit.")
        if headers.get(b"content-type", b"").lower() != b"image/jpeg":
            raise StreamFormatError("MJPEG part is not a JPEG image.")
        frame = _read_exact(source, length)
        if _read_exact(source, 2) != b"\r\n":
            raise StreamFormatError("MJPEG frame has no trailing CRLF.")
        yield frame
        boundary = _line(source, MAX_HEADERS_BYTES)


def decode_jpeg(data: bytes):
    """Return a contiguous RGB ndarray for pyvirtualcam."""
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        raise ReceiverError("Missing desktop dependencies. Install this package with pip install -e ./desktop.") from None

    with Image.open(BytesIO(data)) as image:
        if image.width > 8192 or image.height > 8192:
            raise StreamFormatError("JPEG dimensions exceed 8192 pixels.")
        return np.ascontiguousarray(np.asarray(image.convert("RGB")))


def create_camera(width: int, height: int, fps: int):
    try:
        import pyvirtualcam
    except ImportError:
        raise ReceiverError("Missing desktop dependencies. Install this package with pip install -e ./desktop.") from None

    if sys.platform.startswith("linux"):
        from rocam_v4l2 import find_rocam_device, register_backend

        device = find_rocam_device()
        if device is None:
            raise ReceiverError(
                "No writable Rocam v4l2loopback output was found. "
                "Create the dedicated Rocam loopback camera before starting the receiver."
            )
        register_backend(pyvirtualcam)
        return pyvirtualcam.Camera(
            width=width,
            height=height,
            fps=fps,
            backend="rocam-v4l2",
            device=device,
        )

    return pyvirtualcam.Camera(width=width, height=height, fps=fps)


def _clear_camera(camera, dimensions: tuple[int, int]) -> bool:
    """Replace a stale image with black; request a reopen if the backend fails."""
    import numpy as np

    width, height = dimensions
    try:
        camera.send(np.zeros((height, width, 3), dtype=np.uint8))
        return True
    except Exception:
        try:
            camera.close()
        except Exception:
            raise ReceiverError("Virtual camera could not be cleared after connection loss.") from None
        return False


def receive(
    url: str,
    *,
    fps: int = 30,
    camera_factory: Callable = create_camera,
    decoder: Callable = decode_jpeg,
    opener: Callable | None = None,
    pause: Callable = time.sleep,
    stopped: Callable[[], bool] = lambda: False,
    link_alive: Callable[[], bool] = lambda: True,
    message: Callable[[str], None] = print,
    retry_seconds: float = 2.0,
    codec: str = "mjpeg",
    compressed_decoder=None,
    refresh_session: Callable[[], str] | None = None,
    refresh_before_attempt: bool = False,
    connection_state: Callable[[bool, str | None], None] | None = None,
) -> None:
    """Reconnect on network loss, reusing the webcam until dimensions change.

    JPEG behavior deliberately retains the injectable ``decoder`` used by older
    callers.  Compressed input decodes every access unit but only publishes at
    the virtual camera cadence, so a slow output backend does not stall reads.
    """
    if codec not in ("mjpeg", "h264", "hevc"):
        raise ReceiverError("Choose MJPEG, H.264, or HEVC video.")
    if refresh_before_attempt and refresh_session is None:
        raise ReceiverError("USB streaming requires a session refresh callback.")
    video_decoder = None
    if codec != "mjpeg":
        from rocam_video import AVDecoder, read_packet

        if compressed_decoder is None and not AVDecoder.available():
            raise ReceiverError(
                "H.264/HEVC reception requires the video extra. Install with: pip install './desktop[video]'."
            )
        video_decoder = compressed_decoder or AVDecoder()
    camera = None
    dimensions = None
    camera_is_black = False
    open_stream = opener or DIRECT_OPENER
    active_url = url

    def report_connection(usable: bool) -> None:
        """Report whether the current authenticated stream can serve controls.

        Callers use this to avoid retaining a credential while this receiver is
        reconnecting.  The URL is supplied only once its response headers have
        validated the authenticated stream.
        """
        if connection_state is not None:
            connection_state(usable, active_url if usable else None)

    def blackout() -> None:
        nonlocal camera, dimensions, camera_is_black
        if camera is not None and dimensions is not None and not camera_is_black:
            if not _clear_camera(camera, dimensions):
                camera = None
                dimensions = None
            else:
                camera_is_black = True

    try:
        while not stopped():
            if not link_alive():
                report_connection(False)
                raise UsbTransportError("USB forwarding stopped; reconnecting.")
            if refresh_before_attempt:
                # USB bootstrap expires quickly. Acquire it directly before every stream
                # request so an elapsed retry wait cannot invalidate the proof of transport.
                active_url = refresh_session()
                if stopped():
                    return
            try:
                request = Request(active_url, headers={"User-Agent": "Rocam-Webcam/0.1"})
                with open_stream(request, timeout=10) as response:
                    content_type = response.headers.get("Content-Type", "").lower()
                    if codec == "mjpeg":
                        if "multipart/x-mixed-replace" not in content_type or "boundary=frame" not in content_type:
                            raise StreamFormatError("Rocam did not return its MJPEG stream.")
                        packets = mjpeg_frames(response)
                    else:
                        if content_type.split(";", 1)[0].strip() != "application/x-rocam-video":
                            raise StreamFormatError("Rocam did not return its encoded video stream.")
                        packets = iter(lambda: read_packet(response), None)
                    report_connection(True)
                    next_publish = 0.0
                    for data in packets:
                        try:
                            if codec == "mjpeg":
                                decoded_frames = [decoder(data)]
                            else:
                                if data.codec != {"h264": 1, "hevc": 2}[codec]:
                                    raise StreamFormatError("Rocam encoded stream codec does not match its endpoint.")
                                decoded_frames = video_decoder.decode(data)
                        except (OSError, ValueError, TypeError, AttributeError, VideoDecoderError) as exc:
                            message(f"{exc} Reconnecting...")
                            if video_decoder is not None:
                                video_decoder.reset()
                            break
                        for frame in decoded_frames:
                            try:
                                height, width, channels = frame.shape
                            except (ValueError, TypeError, AttributeError):
                                raise StreamFormatError("Rocam sent an unreadable video frame.") from None
                            if channels != 3 or not 0 < width <= 8192 or not 0 < height <= 8192:
                                raise StreamFormatError("Rocam sent unsupported video dimensions.")
                            if stopped():
                                return
                            if dimensions != (width, height):
                                if camera is not None:
                                    blackout()
                                if camera is not None:
                                    camera.close()
                                camera = None
                                try:
                                    camera = camera_factory(width, height, fps)
                                except ReceiverError:
                                    raise
                                except Exception:
                                    raise ReceiverError(
                                        "Could not open a virtual camera. On Mac/Windows, install OBS Virtual Camera "
                                        "(on Mac, start and stop it once in OBS to register it). "
                                        "On Linux, install v4l2loopback."
                                    ) from None
                                dimensions = (width, height)
                                camera_is_black = False
                                message(f"Virtual camera ready at {width}x{height}, {fps} FPS.")
                            if stopped():
                                return
                            if codec != "mjpeg" and time.monotonic() < next_publish:
                                continue
                            try:
                                camera.send(frame)
                                camera_is_black = False
                                if codec == "mjpeg":
                                    camera.sleep_until_next_frame()
                                else:
                                    next_publish = time.monotonic() + 1.0 / fps
                            except Exception:
                                raise ReceiverError("Virtual camera stopped accepting frames.") from None
                            if stopped():
                                return
                report_connection(False)
                message("Stream disconnected; reconnecting...")
            except HTTPError as exc:
                code = exc.code
                exc.close()
                report_connection(False)
                if code == 403:
                    blackout()
                    if refresh_session is not None:
                        if refresh_before_attempt:
                            message("Rocam USB session expired; retrying...")
                            # Back off before the next bootstrap. The next loop then obtains a
                            # fresh proof directly before its authenticated stream request.
                            if stopped():
                                return
                            pause(retry_seconds)
                            if stopped():
                                return
                            continue
                        active_url = refresh_session()
                        message("Rocam USB session refreshed; reconnecting...")
                        if stopped():
                            return
                        pause(retry_seconds)
                        if stopped():
                            return
                        continue
                    raise ReceiverError("Rocam rejected the session key. Refresh the Connection URL on the iPhone or iPad.") from None
                if code == 404:
                    blackout()
                    raise ReceiverError("Stream unavailable. Select LiDAR on the iPhone or iPad for --depth.") from None
                message(f"Stream returned HTTP {code}; reconnecting...")
            except (URLError, OSError, TimeoutError, ValueError):
                report_connection(False)
                message("Connection lost; reconnecting...")
            except (StreamFormatError, VideoFormatError) as exc:
                report_connection(False)
                message(f"{exc} Reconnecting...")
                if video_decoder is not None:
                    video_decoder.reset()
            blackout()
            if not link_alive():
                report_connection(False)
                raise UsbTransportError("USB forwarding stopped; reconnecting.")
            if not stopped():
                pause(retry_seconds)
                if stopped():
                    return
    finally:
        try:
            report_connection(False)
            blackout()
        finally:
            if camera is not None:
                camera.close()


@contextmanager
def usb_forwarder(enabled: bool, udid: str | None = None):
    if udid is not None and not UDID_PATTERN.fullmatch(udid):
        raise ReceiverError("Invalid iPhone or iPad UDID. Use the value reported by idevice_id.")
    if udid is not None and not enabled:
        raise ReceiverError("--udid requires --usb.")
    if not enabled:
        yield lambda: True
        return
    executable = shutil.which("iproxy")
    if executable is None and sys.platform == "darwin":
        for candidate in ("/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"):
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                executable = candidate
                break
    if executable is None:
        raise ReceiverError("--usb requires iproxy on your PATH (Ubuntu: libusbmuxd-tools).")
    try:
        port_probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            port_probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            port_probe.bind(("127.0.0.1", 8765))
            port_probe.listen(1)
        finally:
            port_probe.close()
    except OSError:
        raise ReceiverError("USB forwarding cannot start because localhost port 8765 is already in use.") from None
    try:
        command = [executable, "--local"]
        if udid is not None:
            command.extend(["--udid", udid])
        command.extend(["--source", "127.0.0.1", "8765:8765"])
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        raise ReceiverError("Could not start iproxy. Check its installation.") from None
    try:
        time.sleep(0.3)
        if process.poll() is not None:
            raise UsbTransportError("Waiting for an iPhone or iPad USB connection.")
        yield _UsbForwarderLink(process)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def _connection_url(value: str | None) -> str:
    if value is not None:
        return value
    try:
        if sys.stdin.isatty():
            entered = getpass.getpass("Rocam Connection URL: ")
        else:
            entered = sys.stdin.readline()
    except (EOFError, OSError):
        raise ReceiverError("No Rocam Connection URL was provided.") from None
    if not entered.strip():
        raise ReceiverError("No Rocam Connection URL was provided.")
    return entered.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Publish Rocam's color or LiDAR feed as a desktop virtual webcam.",
        epilog=(
            "Install with: pip install -e ./desktop. Mac/Windows need OBS Virtual Camera; "
            "on Mac, start and stop the camera once in OBS to register it. "
            "Linux needs v4l2loopback. --usb also needs iproxy. "
            "For microphone forwarding, install pip install -e './desktop[audio]' "
            "and choose a virtual audio output device."
        ),
    )
    parser.add_argument(
        "connection_url", nargs="?",
        help="Full Connection URL; omit to enter privately or pipe it through stdin",
    )
    parser.add_argument("--depth", action="store_true", help="Use the LiDAR visualization")
    parser.add_argument("--codec", choices=("mjpeg", "h264", "hevc"), default="mjpeg",
                        help="Color transport codec (default: mjpeg)")
    parser.add_argument("--usb", action="store_true", help="Forward USB with iproxy to localhost:8765")
    parser.add_argument("--udid", metavar="UDID", help="Select an attached iPhone or iPad for --usb")
    parser.add_argument("--fps", type=int, default=30, help="Virtual webcam FPS (default: 30)")
    parser.add_argument(
        "--audio-output", metavar="DEVICE",
        help="Forward microphone audio to a named virtual audio output device",
    )
    args = parser.parse_args(argv)
    if not 1 <= args.fps <= 120:
        parser.error("--fps must be between 1 and 120")
    if args.udid is not None and not args.usb:
        parser.error("--udid requires --usb")
    if args.udid is not None and not UDID_PATTERN.fullmatch(args.udid):
        parser.error("--udid must be a valid iPhone or iPad UDID")
    try:
        if args.depth and args.codec != "mjpeg":
            parser.error("--depth requires --codec mjpeg; LiDAR uses the MJPEG visualization")
        if args.usb:
            connection_url = _connection_url(args.connection_url) if args.connection_url is not None else ""
            announced_wait = False
            while True:
                audio_stop = threading.Event()
                audio_thread = None
                try:
                    with usb_forwarder(True, args.udid) as link_alive:
                        if not connection_url:
                            connection_url = discover_usb_session(link_alive)
                        url = stream_url(connection_url, depth=args.depth, usb=True, codec=args.codec)

                        def stop_audio() -> bool:
                            audio_stop.set()
                            if audio_thread is not None:
                                audio_thread.join(timeout=3)
                                return not audio_thread.is_alive()
                            return True

                        def start_audio(session_url: str) -> threading.Thread | None:
                            if args.audio_output is None:
                                return None
                            from rocam_audio import AudioError, run_audio

                            def play_audio():
                                try:
                                    run_audio(
                                        session_url,
                                        args.audio_output,
                                        audio_stop,
                                        on_status=print,
                                        opener=USB_SESSION_OPENER,
                                    )
                                except AudioError as exc:
                                    print(f"Microphone error: {exc}", file=sys.stderr)
                                except Exception:
                                    print("Microphone forwarding stopped unexpectedly.", file=sys.stderr)

                            thread = threading.Thread(target=play_audio, name="rocam-audio", daemon=True)
                            thread.start()
                            return thread

                        audio_url: str | None = url if args.audio_output is not None else None
                        audio_thread = start_audio(url)

                        def refresh_session() -> str:
                            nonlocal audio_stop, audio_thread, audio_url
                            refreshed_url = stream_url(
                                discover_usb_session(link_alive), depth=args.depth, usb=True, codec=args.codec,
                            )
                            if args.audio_output is not None and refreshed_url != audio_url:
                                if audio_thread is not None and not stop_audio():
                                    raise ReceiverError("Microphone forwarding did not stop safely for the refreshed USB session.")
                                # Audio cleanup can outlive the short USB bootstrap proof.
                                refreshed_url = stream_url(
                                    discover_usb_session(link_alive), depth=args.depth, usb=True, codec=args.codec,
                                )
                                audio_stop = threading.Event()
                                audio_thread = start_audio(refreshed_url)
                                audio_url = refreshed_url
                            return refreshed_url

                        print("Connecting to Rocam. Press Ctrl+C to stop.")
                        try:
                            receive(
                                url,
                                fps=args.fps,
                                link_alive=link_alive,
                                codec="mjpeg" if args.depth else args.codec,
                                refresh_session=refresh_session,
                                refresh_before_attempt=True,
                                opener=USB_SESSION_OPENER,
                            )
                        finally:
                            if not stop_audio():
                                raise ReceiverError(
                                    "Microphone forwarding did not stop safely before USB reconnect."
                                )
                        break
                except UsbTransportError:
                    connection_url = ""
                    if not announced_wait:
                        print("Waiting for the Rocam iPhone or iPad over USB…", file=sys.stderr)
                        announced_wait = True
                    time.sleep(2.0)
        else:
            url = stream_url(_connection_url(args.connection_url), depth=args.depth, codec=args.codec)
            with usb_forwarder(False, args.udid) as link_alive:
                audio_stop = threading.Event()
                audio_thread = None
                if args.audio_output is not None:
                    from rocam_audio import AudioError, run_audio

                    def play_audio():
                        try:
                            run_audio(url, args.audio_output, audio_stop, on_status=print)
                        except AudioError as exc:
                            print(f"Microphone error: {exc}", file=sys.stderr)
                        except Exception:
                            print("Microphone forwarding stopped unexpectedly.", file=sys.stderr)

                    audio_thread = threading.Thread(target=play_audio, name="rocam-audio", daemon=True)
                    audio_thread.start()
                print("Connecting to Rocam. Press Ctrl+C to stop.")
                try:
                    receive(url, fps=args.fps, link_alive=link_alive, codec=args.codec)
                finally:
                    audio_stop.set()
                    if audio_thread is not None:
                        audio_thread.join(timeout=3)
    except KeyboardInterrupt:
        print("\nStopped.")
    except ReceiverError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
