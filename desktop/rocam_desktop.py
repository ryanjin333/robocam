"""Small Tk desktop companion for publishing a Rocam feed as a virtual camera."""

from __future__ import annotations

from dataclasses import dataclass
from queue import Empty, Queue
import sys
import threading
from typing import Callable
from urllib.parse import urlsplit, urlunsplit
import webbrowser

from rocam_receiver import (
    ReceiverError,
    UDID_PATTERN,
    USB_SESSION_OPENER,
    UsbTransportError,
    discover_usb_session,
    receive,
    stream_url,
    usb_forwarder,
)


@dataclass(frozen=True)
class SessionConfig:
    connection_url: str
    usb: bool = False
    depth: bool = False
    fps: int = 30
    udid: str | None = None
    audio_output: str | None = None
    codec: str = "mjpeg"


class SessionController:
    """Run the blocking receiver lifecycle without requiring a Tk interpreter."""

    def __init__(
        self,
        *,
        receiver: Callable = receive,
        forwarder: Callable = usb_forwarder,
        audio_runner: Callable | None = None,
        session_discoverer: Callable = discover_usb_session,
        reconnect_wait: Callable[[float], None] | None = None,
    ) -> None:
        self._receiver = receiver
        self._forwarder = forwarder
        self._audio_runner = audio_runner
        self._session_discoverer = session_discoverer
        self._reconnect_wait = reconnect_wait
        self._lock = threading.Lock()
        self._messages: Queue[str] = Queue()
        self._state = "idle"
        self._stop_event: threading.Event | None = None
        self._thread: threading.Thread | None = None
        self._retiring_audio_thread: threading.Thread | None = None
        self._latest_video_status = ""
        self._audio_error: str | None = None
        self._control_url: str | None = None

    @property
    def is_active(self) -> bool:
        with self._lock:
            return self._state != "idle"

    @property
    def is_stopping(self) -> bool:
        with self._lock:
            return self._state == "stopping"

    @property
    def status_text(self) -> str:
        with self._lock:
            video_status = self._latest_video_status
            audio_error = self._audio_error
        if audio_error is None:
            return video_status
        if video_status:
            return f"{video_status}  Microphone: {audio_error}"
        return f"Microphone: {audio_error}"

    @property
    def has_camera_controls(self) -> bool:
        """Whether the current session has an authenticated control page."""
        with self._lock:
            return self._state == "running" and self._control_url is not None

    def open_camera_controls(self, opener: Callable[[str], bool]) -> bool:
        """Open the current control page without exposing its credential to the view."""
        with self._lock:
            if self._state != "running" or self._control_url is None:
                return False
            control_url = self._control_url
        try:
            return opener(control_url) is not False
        except Exception:
            return False

    def drain_messages(self) -> list[str]:
        messages = []
        while True:
            try:
                messages.append(self._messages.get_nowait())
            except Empty:
                if messages:
                    status = self.status_text
                    if status:
                        messages.append(status)
                return messages

    def start(self, config: SessionConfig) -> bool:
        """Validate then start one receiver worker. Raises only safe input errors."""
        video_url = self._validate(config)
        with self._lock:
            if self._retiring_audio_thread is not None:
                if self._retiring_audio_thread.is_alive():
                    return False
                self._retiring_audio_thread = None
            if self._state != "idle":
                return False
            stop_event = threading.Event()
            worker = threading.Thread(
                target=self._run,
                args=(config, video_url, stop_event),
                name="rocam-desktop",
                daemon=True,
            )
            self._stop_event = stop_event
            self._thread = worker
            self._state = "running"
            self._latest_video_status = ""
            self._audio_error = None
            self._control_url = None
        try:
            worker.start()
        except Exception:
            with self._lock:
                if self._thread is worker:
                    self._state = "idle"
                    self._stop_event = None
                    self._thread = None
            raise ReceiverError("Could not start the Rocam desktop worker.") from None
        return True

    def stop(self) -> bool:
        """Request cancellation without waiting on the receiver's network timeout."""
        with self._lock:
            if self._state == "idle":
                return False
            if self._state == "stopping":
                return True
            self._state = "stopping"
            self._control_url = None
            assert self._stop_event is not None
            self._stop_event.set()
        self._post("Stopping Rocam…")
        return True

    @staticmethod
    def _validate(config: SessionConfig) -> str:
        if not isinstance(config.fps, int) or not 1 <= config.fps <= 120:
            raise ReceiverError("FPS must be between 1 and 120.")
        if config.udid is not None and not config.usb:
            raise ReceiverError("USB must be enabled when an iPhone or iPad UDID is provided.")
        if config.udid is not None and not UDID_PATTERN.fullmatch(config.udid):
            raise ReceiverError("Invalid iPhone or iPad UDID. Use the value reported by idevice_id.")
        if config.audio_output is not None and not config.audio_output.strip():
            raise ReceiverError("Choose a named virtual microphone output device.")
        if config.codec not in ("mjpeg", "h264", "hevc"):
            raise ReceiverError("Choose MJPEG, H.264, or HEVC video.")
        if not config.connection_url.strip():
            if config.usb:
                return ""
            raise ReceiverError("Enter a Rocam Connection URL when USB forwarding is disabled.")
        # LiDAR has a distinct JPEG visualization. Keep the selected color codec
        # in the UI, but always choose MJPEG while LiDAR is active.
        return stream_url(config.connection_url.strip(), depth=config.depth, usb=config.usb,
                          codec="mjpeg" if config.depth else config.codec)

    def _post(self, message: str) -> None:
        with self._lock:
            self._latest_video_status = message
        self._messages.put(message)

    def _post_audio_status(self, message: str) -> None:
        self._messages.put(f"Microphone: {message}")

    def _set_audio_error(self, message: str) -> None:
        with self._lock:
            self._audio_error = message
        self._messages.put(f"Microphone error: {message}")

    def _run(self, config: SessionConfig, video_url: str, stop_event: threading.Event) -> None:
        failed = False
        try:
            self._post("Connecting to Rocam…")
            if config.usb:
                self._run_usb(config, video_url, stop_event)
            else:
                with self._forwarder(False, config.udid) as link_alive:
                    self._run_receiver_session(config, video_url, stop_event, link_alive)
        except ReceiverError as exc:
            failed = True
            self._post(f"Error: {exc}")
        except Exception:
            failed = True
            self._post("Rocam desktop receiver stopped unexpectedly.")
        finally:
            if not failed:
                self._post("Rocam stopped.")
            with self._lock:
                self._control_url = None
                self._state = "idle"
                self._stop_event = None
                self._thread = None

    @staticmethod
    def _session_stream_url(config: SessionConfig, connection_url: str) -> str:
        return stream_url(
            connection_url,
            depth=config.depth,
            usb=True,
            codec="mjpeg" if config.depth else config.codec,
        )

    @staticmethod
    def _control_page_url(video_url: str) -> str:
        """Derive the authenticated root page from a canonical receiver URL."""
        parsed = urlsplit(video_url)
        return urlunsplit((parsed.scheme, parsed.netloc, "/", parsed.query, ""))

    def _set_connection_state(
        self,
        usable: bool,
        video_url: str | None = None,
        config: SessionConfig | None = None,
    ) -> None:
        """Retain controls only while the receiver has a usable authenticated stream."""
        if usable and video_url is not None and config is not None:
            try:
                video_url = stream_url(
                    video_url,
                    depth=config.depth,
                    usb=config.usb,
                    codec="mjpeg" if config.depth else config.codec,
                )
            except ReceiverError:
                usable = False
        with self._lock:
            if not usable or self._state != "running":
                self._control_url = None
            elif video_url is not None:
                self._control_url = self._control_page_url(video_url)

    def _run_usb(self, config: SessionConfig, initial_video_url: str, stop_event: threading.Event) -> None:
        """Keep one worker alive while a cable or phone app comes and goes."""
        video_url = initial_video_url
        waiting_reported = False
        while not stop_event.is_set():
            try:
                with self._forwarder(True, config.udid) as link_alive:
                    if not video_url:
                        if not waiting_reported:
                            self._post("Waiting for the Rocam iPhone or iPad over USB…")
                            waiting_reported = True
                        video_url = self._session_stream_url(config, self._session_discoverer(link_alive))
                    waiting_reported = False
                    self._run_receiver_session(config, video_url, stop_event, link_alive)
                    return
            except UsbTransportError:
                self._set_connection_state(False)
                if stop_event.is_set():
                    return
                # A reconnect always asks the phone for a current key. This also
                # replaces a manually supplied USB key after the device returns.
                video_url = ""
                if not waiting_reported:
                    self._post("Waiting for the Rocam iPhone or iPad over USB…")
                    waiting_reported = True
                if self._reconnect_wait is None:
                    stop_event.wait(2.0)
                else:
                    self._reconnect_wait(2.0)

    def _run_receiver_session(
        self,
        config: SessionConfig,
        video_url: str,
        stop_event: threading.Event,
        link_alive: Callable[[], bool],
    ) -> None:
        audio_stop = threading.Event()
        audio_thread = self._start_audio(video_url, config.audio_output, audio_stop, usb=config.usb)

        def refresh_session() -> str:
            nonlocal audio_stop, audio_thread
            self._set_connection_state(False)
            refreshed_url = self._session_stream_url(config, self._session_discoverer(link_alive))
            if config.audio_output is not None:
                if not self._stop_audio(audio_stop, audio_thread):
                    self._set_audio_error("Microphone forwarding did not stop after its USB session expired.")
                    raise ReceiverError("Microphone forwarding did not stop safely for the refreshed USB session.")
                audio_stop = threading.Event()
                audio_thread = self._start_audio(refreshed_url, config.audio_output, audio_stop, usb=True)
            return refreshed_url

        try:
            if not stop_event.is_set():
                receiver_options = {
                    "fps": config.fps,
                    "stopped": stop_event.is_set,
                    "link_alive": link_alive,
                    "message": self._post,
                    "pause": stop_event.wait,
                    "codec": "mjpeg" if config.depth else config.codec,
                    "connection_state": lambda usable, current_url: self._set_connection_state(
                        usable, current_url, config
                    ),
                }
                if config.usb:
                    receiver_options.update(
                        refresh_session=refresh_session,
                        opener=USB_SESSION_OPENER,
                    )
                self._receiver(video_url, **receiver_options)
        finally:
            if not self._stop_audio(audio_stop, audio_thread):
                with self._lock:
                    self._retiring_audio_thread = audio_thread
                self._set_audio_error("Microphone forwarding is still stopping.")
                raise ReceiverError(
                    "Microphone forwarding is still stopping; reconnect after it exits."
                )

    def _start_audio(self, video_url: str, output_device: str | None,
                     stop_event: threading.Event, *, usb: bool) -> threading.Thread | None:
        if output_device is None:
            return None
        thread = threading.Thread(
            target=self._run_audio,
            args=(video_url, output_device, stop_event, usb),
            name="rocam-audio",
            daemon=True,
        )
        try:
            thread.start()
        except Exception:
            raise ReceiverError("Could not start microphone forwarding.") from None
        return thread

    @staticmethod
    def _stop_audio(stop_event: threading.Event, thread: threading.Thread | None) -> bool:
        stop_event.set()
        if thread is None:
            return True
        thread.join(timeout=3.0)
        return not thread.is_alive()

    def _run_audio(self, video_url: str, output_device: str, stop_event: threading.Event, usb: bool = False) -> None:
        try:
            if self._audio_runner is None:
                from rocam_audio import AudioError, run_audio

                runner = run_audio
            else:
                from rocam_audio import AudioError

                runner = self._audio_runner
            if usb and self._audio_runner is None:
                runner(
                    video_url,
                    output_device,
                    stop_event,
                    on_status=self._post_audio_status,
                    opener=USB_SESSION_OPENER,
                )
            else:
                runner(video_url, output_device, stop_event, on_status=self._post_audio_status)
        except AudioError as exc:
            self._set_audio_error(str(exc))
        except Exception:
            self._set_audio_error("Microphone forwarding stopped unexpectedly.")


class RocamDesktopApp:
    """Tk view that polls SessionController; workers never call Tk directly."""

    def __init__(self, root, tk, ttk) -> None:
        self.root = root
        self.tk = tk
        self.ttk = ttk
        self.controller = SessionController()
        self._closing = False
        self._advanced_visible = False
        self._restart_pending = False
        self._manually_stopped = False
        self._browser_opener = webbrowser.open

        root.title("Rocam Desktop")
        root.minsize(480, 300)
        root.columnconfigure(0, weight=1)
        root.protocol("WM_DELETE_WINDOW", self.close)

        self.url = tk.StringVar()
        self.usb = tk.BooleanVar(value=True)
        self.source = tk.StringVar(value="camera")
        self.fps = tk.StringVar(value="30")
        self.udid = tk.StringVar()
        self.audio_output = tk.StringVar()
        self.codec = tk.StringVar(value="mjpeg")
        self.status = tk.StringVar(value="Waiting for the Rocam iPhone or iPad over USB…")

        panel = ttk.Frame(root, padding=16)
        panel.grid(sticky="nsew")
        panel.columnconfigure(1, weight=1)

        ttk.Checkbutton(panel, text="Use USB forwarding", variable=self.usb,
                        command=self._restart_if_active).grid(row=0, column=0, sticky="w")
        source_frame = ttk.Frame(panel)
        source_frame.grid(row=0, column=1, sticky="e")
        ttk.Label(source_frame, text="Feed:").grid(row=0, column=0, padx=(0, 5))
        ttk.Radiobutton(source_frame, text="Camera", variable=self.source, value="camera",
                        command=self._restart_if_active).grid(row=0, column=1)
        ttk.Radiobutton(source_frame, text="LiDAR", variable=self.source, value="lidar",
                        command=self._restart_if_active).grid(row=0, column=2)

        self.advanced = ttk.Frame(panel)
        self.advanced.columnconfigure(1, weight=1)
        ttk.Label(self.advanced, text="Connection URL (Wi-Fi only)").grid(row=0, column=0, sticky="w")
        self.url_entry = ttk.Entry(self.advanced, textvariable=self.url)
        self.url_entry.grid(row=0, column=1, sticky="ew", padx=(8, 0))
        self.url_entry.bind("<FocusOut>", self._restart_if_active)
        ttk.Label(self.advanced, text="FPS (1–120)").grid(row=1, column=0, sticky="w", pady=(7, 0))
        fps_entry = ttk.Entry(self.advanced, textvariable=self.fps, width=8)
        fps_entry.grid(row=1, column=1, sticky="w", padx=(8, 0), pady=(7, 0))
        fps_entry.bind("<FocusOut>", self._restart_if_active)
        ttk.Label(self.advanced, text="Device UDID (USB only)").grid(row=2, column=0, sticky="w", pady=(7, 0))
        udid_entry = ttk.Entry(self.advanced, textvariable=self.udid)
        udid_entry.grid(row=2, column=1, sticky="ew", padx=(8, 0), pady=(7, 0))
        udid_entry.bind("<FocusOut>", self._restart_if_active)
        ttk.Label(self.advanced, text="Virtual audio output").grid(row=3, column=0, sticky="w", pady=(7, 0))
        audio_entry = ttk.Entry(self.advanced, textvariable=self.audio_output)
        audio_entry.grid(row=3, column=1, sticky="ew", padx=(8, 0), pady=(7, 0))
        audio_entry.bind("<FocusOut>", self._restart_if_active)
        ttk.Label(self.advanced, text="Color codec").grid(row=4, column=0, sticky="w", pady=(7, 0))
        codec_box = ttk.Combobox(self.advanced, textvariable=self.codec, state="readonly", width=12,
                                 values=("mjpeg", "h264", "hevc"))
        codec_box.grid(row=4, column=1, sticky="w", padx=(8, 0), pady=(7, 0))
        codec_box.bind("<<ComboboxSelected>>", self._restart_if_active)
        self.advanced_button = ttk.Button(panel, text="Advanced options", command=self.toggle_advanced)
        self.advanced_button.grid(row=1, column=0, sticky="w", pady=(10, 6))

        controls = ttk.Frame(panel)
        controls.grid(row=3, column=0, columnspan=2, sticky="ew", pady=(14, 0))
        self.start_button = ttk.Button(controls, text="Reconnect", command=self.start)
        self.start_button.grid(row=0, column=0, padx=(0, 6), sticky="w")
        self.stop_button = ttk.Button(controls, text="Stop", command=self.stop, state="disabled")
        self.stop_button.grid(row=0, column=1, sticky="w")
        self.controls_button = ttk.Button(controls, text="Camera controls", command=self.open_camera_controls,
                                          state="disabled")
        self.controls_button.grid(row=0, column=2, padx=(6, 0), sticky="w")
        ttk.Label(controls, textvariable=self.status, wraplength=440).grid(
            row=1, column=0, columnspan=3, sticky="ew", pady=(8, 0)
        )

        self.root.after(100, self.poll)
        self.root.after(0, self.start)

    def toggle_advanced(self) -> None:
        self._advanced_visible = not self._advanced_visible
        if self._advanced_visible:
            self.advanced.grid(row=2, column=0, columnspan=2, sticky="ew")
            self.advanced_button.configure(text="Hide advanced options")
        else:
            self.advanced.grid_remove()
            self.advanced_button.configure(text="Advanced options")

    def _config(self) -> SessionConfig:
        try:
            fps = int(self.fps.get().strip())
        except ValueError:
            raise ReceiverError("FPS must be a whole number between 1 and 120.") from None
        return SessionConfig(
            connection_url=self.url.get(),
            usb=self.usb.get(),
            depth=self.source.get() == "lidar",
            fps=fps,
            udid=self.udid.get().strip() or None,
            audio_output=self.audio_output.get().strip() or None,
            codec="mjpeg" if self.source.get() == "lidar" else self.codec.get(),
        )

    def start(self) -> None:
        self._manually_stopped = False
        try:
            started = self.controller.start(self._config())
        except ReceiverError as exc:
            self.status.set(f"Error: {exc}")
            return
        if not started:
            self.status.set("Rocam is already starting, running, or stopping.")
            return
        self._sync_controls()

    def stop(self) -> None:
        self._manually_stopped = True
        self.controller.stop()
        self._sync_controls()

    def open_camera_controls(self) -> None:
        if not self.controller.open_camera_controls(self._browser_opener):
            self.status.set("Could not open Camera controls in your default browser.")
        self._sync_controls()

    def _restart_if_active(self, *_args) -> None:
        if self.controller.is_active and not self.controller.is_stopping:
            self._restart_pending = True
            self.controller.stop()
            self._sync_controls()
        elif not self._closing and not getattr(self, "_manually_stopped", False):
            self.start()

    def _sync_controls(self) -> None:
        active = self.controller.is_active
        self.start_button.configure(state="disabled" if active else "normal")
        self.stop_button.configure(state="normal" if active and not self.controller.is_stopping else "disabled")
        self.controls_button.configure(
            state="normal" if active and not self.controller.is_stopping and self.controller.has_camera_controls else "disabled"
        )

    def poll(self) -> None:
        for message in self.controller.drain_messages():
            self.status.set(message)
        self._sync_controls()
        if getattr(self, "_restart_pending", False) and not self.controller.is_active and not self._closing:
            self._restart_pending = False
            self.start()
        if self._closing and not self.controller.is_active:
            self.root.destroy()
            return
        self.root.after(100, self.poll)

    def close(self) -> None:
        self._closing = True
        self.controller.stop()
        if self.controller.is_active:
            self.status.set("Stopping Rocam before closing…")
            self._sync_controls()
        else:
            self.root.destroy()


def main() -> int:
    """Open Rocam Desktop, with an actionable message on Python builds without Tk."""
    try:
        import tkinter as tk
        from tkinter import ttk
    except ImportError:
        print(
            "Rocam Desktop requires Tkinter. On macOS with Homebrew, install the python-tk package "
            "that matches your Python version; on Ubuntu install python3-tk; on Windows use the "
            "official Python installer with Tcl/Tk selected.",
            file=sys.stderr,
        )
        return 1
    root = tk.Tk()
    RocamDesktopApp(root, tk, ttk)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
