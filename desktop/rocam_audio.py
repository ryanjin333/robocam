"""Forward Rocam's live PCM audio to a named virtual audio output device."""

from __future__ import annotations

import struct
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import ProxyHandler, Request, build_opener

from rocam_receiver import ReceiverError, stream_url


CHUNK_BYTES = 4096
WAV_HEADER_BYTES = 44
_DIRECT_OPENER = build_opener(ProxyHandler({}))


def _open_direct(request, *, timeout: float):
    """Open a camera connection without honoring HTTP proxy settings."""
    return _DIRECT_OPENER.open(request, timeout=timeout)


class AudioError(Exception):
    """A user-facing audio error without a connection URL or session key."""


class AudioFormatError(AudioError):
    """Rocam did not return the expected PCM WAV stream."""


def audio_url(connection_url: str) -> str:
    """Select the audio endpoint from a validated Rocam Connection URL."""
    try:
        video_url = stream_url(connection_url)
    except ReceiverError:
        raise AudioError("Invalid Rocam Connection URL for microphone audio.") from None
    parsed = urlsplit(video_url)
    return urlunsplit((parsed.scheme, parsed.netloc, "/audio.wav", parsed.query, ""))


def _read_exact(source, size: int) -> bytes:
    chunks = []
    while size:
        chunk = source.read(size)
        if not chunk:
            raise AudioFormatError("Rocam sent an incomplete WAV header.")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def read_wav_header(source) -> int:
    """Validate Rocam's fixed 44-byte mono PCM header and return its sample rate."""
    header = _read_exact(source, WAV_HEADER_BYTES)
    riff, riff_size, wave, fmt, fmt_size, encoding, channels, rate, byte_rate, align, bits, data, data_size = struct.unpack(
        "<4sI4s4sIHHIIHH4sI", header
    )
    if (
        riff != b"RIFF" or riff_size < 36 or wave != b"WAVE"
        or fmt != b"fmt " or fmt_size != 16 or encoding != 1
        or channels != 1 or not 8000 <= rate <= 192000
        or byte_rate != rate * 2 or align != 2 or bits != 16
        or data != b"data" or data_size == 0
    ):
        raise AudioFormatError("Rocam sent an unsupported microphone WAV format.")
    return rate


def _open_output_stream(**options):
    try:
        import sounddevice
    except ImportError:
        raise AudioError("Microphone forwarding requires sounddevice. Install the audio extra and retry.") from None
    return sounddevice.RawOutputStream(**options)


def run_audio(
    connection_url: str,
    output_device: str,
    stop_event,
    on_status: Callable[[str], None] = lambda _: None,
    *,
    opener: Callable = _open_direct,
    stream_factory: Callable | None = None,
    retry_seconds: float = 2.0,
) -> None:
    """Play live audio until stopped, reconnecting after network or microphone loss.

    ``output_device`` must name an OS audio output such as BlackHole, VB-CABLE,
    or a Linux loopback sink. The caller can expose that output as a microphone.
    """
    if not isinstance(output_device, str) or not output_device.strip():
        raise AudioError("Choose a named virtual microphone output device.")
    if retry_seconds < 0:
        raise AudioError("Audio retry delay must be nonnegative.")
    url = audio_url(connection_url)
    make_stream = stream_factory or _open_output_stream
    while not stop_event.is_set():
        try:
            request = Request(url, headers={"User-Agent": "Rocam-Microphone/0.1"})
            with opener(request, timeout=1.0) as response:
                rate = read_wav_header(response)
                try:
                    stream = make_stream(
                        samplerate=rate, channels=1, dtype="int16",
                        device=output_device,
                    )
                except AudioError:
                    raise
                except Exception:
                    raise AudioError(
                        "Could not open the named virtual microphone output device. "
                        "Check that it is installed and available."
                    ) from None
                try:
                    with stream:
                        on_status(f"Microphone audio ready at {rate} Hz.")
                        pending = b""
                        read_chunk = getattr(response, "read1", response.read)
                        while not stop_event.is_set():
                            chunk = read_chunk(CHUNK_BYTES)
                            if not chunk:
                                break
                            samples = pending + chunk
                            aligned = len(samples) & ~1
                            if aligned:
                                try:
                                    stream.write(samples[:aligned])
                                except Exception:
                                    raise AudioError("Virtual microphone output stopped accepting audio.") from None
                            pending = samples[aligned:]
                except AudioError:
                    raise
                except Exception:
                    raise AudioError("Virtual microphone output stopped accepting audio.") from None
            if not stop_event.is_set():
                on_status("Microphone audio disconnected; reconnecting...")
        except HTTPError as exc:
            code = exc.code
            exc.close()
            if code == 403:
                raise AudioError("Rocam rejected the session key. Refresh the Connection URL on the iPhone or iPad.") from None
            if code == 404:
                on_status("Microphone is off or unavailable on the iPhone or iPad; waiting to reconnect...")
            else:
                on_status(f"Microphone stream returned HTTP {code}; reconnecting...")
        except (URLError, OSError, TimeoutError):
            on_status("Microphone connection lost; reconnecting...")
        except AudioFormatError:
            on_status("Invalid microphone audio stream; reconnecting...")
        if not stop_event.is_set():
            stop_event.wait(retry_seconds)
