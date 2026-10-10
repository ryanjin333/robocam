import threading
import time
import unittest
from contextlib import contextmanager
from unittest.mock import patch

from rocam_receiver import ReceiverError
from rocam_audio import AudioError


KEY = "a" * 32


def wait_until(predicate, timeout=1.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for worker")


class ControllerTests(unittest.TestCase):
    def test_usb_allows_blank_config_and_discovers_session_inside_forwarder(self):
        from rocam_desktop import SessionConfig, SessionController

        events = []

        @contextmanager
        def forwarder(enabled, udid):
            events.append(("forwarder", enabled, udid))
            yield lambda: True

        def discover(link):
            self.assertTrue(link())
            events.append(("discover",))
            return f"http://127.0.0.1:8765/?key={KEY}"

        def receiver(url, **kwargs):
            events.append(("receiver", url, kwargs["refresh_session"]()))

        controller = SessionController(receiver=receiver, forwarder=forwarder, session_discoverer=discover)
        self.assertTrue(controller.start(SessionConfig("", usb=True)))
        wait_until(lambda: not controller.is_active)
        self.assertEqual(events, [
            ("forwarder", True, None),
            ("discover",),
            ("discover",),
            ("receiver", f"http://127.0.0.1:8765/stream?key={KEY}", f"http://127.0.0.1:8765/stream?key={KEY}"),
        ])

    def test_blank_non_usb_config_is_rejected(self):
        from rocam_desktop import SessionConfig, SessionController

        with self.assertRaisesRegex(ReceiverError, "Connection URL"):
            SessionController().start(SessionConfig("", usb=False))

    def test_usb_transport_loss_reopens_forwarder_without_duplicate_receiver(self):
        from rocam_desktop import SessionConfig, SessionController
        from rocam_receiver import UsbTransportError

        forwarder_calls = []
        receiver_calls = []

        @contextmanager
        def forwarder(enabled, udid):
            forwarder_calls.append((enabled, udid))
            yield lambda: True

        def receiver(url, **kwargs):
            receiver_calls.append(url)
            if len(receiver_calls) == 1:
                raise UsbTransportError("lost")
            kwargs["stopped"]()

        controller = SessionController(
            receiver=receiver,
            forwarder=forwarder,
            session_discoverer=lambda _link: f"http://127.0.0.1:8765/?key={KEY}",
            reconnect_wait=lambda _seconds: None,
        )
        self.assertTrue(controller.start(SessionConfig("", usb=True)))
        wait_until(lambda: not controller.is_active)
        self.assertEqual(len(forwarder_calls), 2)
        self.assertEqual(len(receiver_calls), 2)

    def test_usb_transport_loss_stops_when_hung_audio_cannot_be_cleaned_up(self):
        from rocam_desktop import SessionConfig, SessionController
        from rocam_receiver import UsbTransportError

        audio_started = threading.Event()
        release_audio = threading.Event()
        audio_calls = []

        @contextmanager
        def forwarder(*_args):
            yield lambda: True

        def audio_runner(*_args, **_kwargs):
            audio_calls.append(None)
            audio_started.set()
            release_audio.wait()

        controller = SessionController(
            receiver=lambda *_args, **_kwargs: (_ for _ in ()).throw(UsbTransportError("lost")),
            forwarder=forwarder,
            audio_runner=audio_runner,
            session_discoverer=lambda _link: f"http://127.0.0.1:8765/?key={KEY}",
            reconnect_wait=lambda _seconds: None,
        )
        self.assertTrue(controller.start(SessionConfig("", usb=True, audio_output="Loopback")))
        self.assertTrue(audio_started.wait(1))
        wait_until(lambda: not controller.is_active, timeout=4.0)
        self.assertEqual(len(audio_calls), 1)
        self.assertIn("still stopping", controller.status_text)
        release_audio.set()

    def test_h264_config_reaches_receiver_and_lidar_falls_back_to_mjpeg(self):
        from rocam_desktop import SessionConfig, SessionController

        calls = []
        def receiver(url, **kwargs): calls.append((url, kwargs["codec"]))
        controller = SessionController(receiver=receiver)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}", codec="h264")))
        wait_until(lambda: not controller.is_active)
        self.assertEqual(calls, [(f"http://phone/video.h264?key={KEY}", "h264")])
        calls.clear()
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}", depth=True, codec="hevc")))
        wait_until(lambda: not controller.is_active)
        self.assertEqual(calls, [(f"http://phone/depth.mjpg?key={KEY}", "mjpeg")])

    def test_controller_accepts_120_fps_and_rejects_121(self):
        from rocam_desktop import SessionConfig, SessionController

        controller = SessionController(receiver=lambda *_args, **_kwargs: None)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}", fps=120)))
        wait_until(lambda: not controller.is_active)
        with self.assertRaisesRegex(ReceiverError, "1 and 120"):
            controller.start(SessionConfig(f"http://phone/?key={KEY}", fps=121))

    def test_start_delivers_video_status_and_cleans_up_usb(self):
        from rocam_desktop import SessionConfig, SessionController

        events = []

        @contextmanager
        def forwarder(enabled, udid):
            events.append(("forwarder", enabled, udid))
            try:
                yield lambda: True
            finally:
                events.append(("forwarder-closed",))

        def receiver(url, *, fps, stopped, message, **_):
            events.append(("receiver", url, fps))
            message("Virtual camera ready.")
            self.assertFalse(stopped())

        controller = SessionController(receiver=receiver, forwarder=forwarder)
        self.assertTrue(
            controller.start(
                SessionConfig(
                    connection_url=f"http://phone:8765/?key={KEY}",
                    usb=True,
                    depth=False,
                    fps=30,
                    udid="00000000-0000000000000001",
                )
            )
        )
        wait_until(lambda: not controller.is_active)

        self.assertIn(("receiver", f"http://127.0.0.1:8765/stream?key={KEY}", 30), events)
        self.assertIn(("forwarder-closed",), events)
        self.assertIn("Virtual camera ready.", controller.drain_messages())

    def test_receiver_error_is_reported_without_session_key(self):
        from rocam_desktop import SessionConfig, SessionController

        def receiver(*_args, **_kwargs):
            raise ReceiverError("Stream unavailable.")

        controller = SessionController(receiver=receiver)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}")))
        wait_until(lambda: not controller.is_active)

        messages = controller.drain_messages()
        self.assertIn("Stream unavailable.", " ".join(messages))
        self.assertNotIn(KEY, " ".join(messages))
        self.assertEqual(messages[-1], "Error: Stream unavailable.")

    def test_stop_interrupts_reconnect_wait_and_closes_usb(self):
        from rocam_desktop import SessionConfig, SessionController

        retrying = threading.Event()
        closed = threading.Event()

        @contextmanager
        def forwarder(*_args):
            try:
                yield lambda: True
            finally:
                closed.set()

        def receiver(*_args, pause, **_kwargs):
            retrying.set()
            pause(30)

        controller = SessionController(receiver=receiver, forwarder=forwarder)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}", usb=True)))
        self.assertTrue(retrying.wait(1))
        self.assertTrue(controller.stop())
        wait_until(lambda: not controller.is_active)
        self.assertTrue(closed.is_set())

    def test_refuses_second_start_while_worker_is_running(self):
        from rocam_desktop import SessionConfig, SessionController

        entered = threading.Event()

        def receiver(*_args, stopped, **_kwargs):
            entered.set()
            while not stopped():
                time.sleep(0.01)

        controller = SessionController(receiver=receiver)
        config = SessionConfig(f"http://phone/?key={KEY}")
        self.assertTrue(controller.start(config))
        self.assertTrue(entered.wait(1))
        self.assertFalse(controller.start(config))
        self.assertTrue(controller.stop())
        wait_until(lambda: not controller.is_active)

    def test_audio_cleanup_is_bounded_when_audio_worker_does_not_exit(self):
        from rocam_desktop import SessionConfig, SessionController

        audio_started = threading.Event()
        release_audio = threading.Event()

        def audio_runner(*_args, **_kwargs):
            audio_started.set()
            release_audio.wait()

        controller = SessionController(receiver=lambda *_args, **_kwargs: None, audio_runner=audio_runner)
        config = SessionConfig(f"http://phone/?key={KEY}", audio_output="Loopback")
        self.assertTrue(controller.start(config))
        self.assertTrue(audio_started.wait(1))
        time.sleep(3.1)
        self.assertFalse(controller.is_active)
        self.assertIn("still stopping", controller.status_text)
        self.assertFalse(controller.start(config))
        release_audio.set()

    def test_start_failure_restores_idle_state(self):
        from rocam_desktop import SessionConfig, SessionController

        controller = SessionController()
        with patch("rocam_desktop.threading.Thread.start", side_effect=RuntimeError("no threads")):
            with self.assertRaises(ReceiverError) as caught:
                controller.start(SessionConfig(f"http://phone/?key={KEY}"))
        self.assertFalse(controller.is_active)
        self.assertNotIn(KEY, str(caught.exception))

    def test_audio_thread_start_failure_restores_idle_state(self):
        from rocam_desktop import SessionConfig, SessionController

        original_start = threading.Thread.start

        def start(thread):
            if thread.name == "rocam-audio":
                raise RuntimeError("audio thread failed")
            return original_start(thread)

        controller = SessionController(receiver=lambda *_args, **_kwargs: None)
        with patch("rocam_desktop.threading.Thread.start", autospec=True, side_effect=start):
            self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}", audio_output="Loopback")))
            wait_until(lambda: not controller.is_active)
        messages = " ".join(controller.drain_messages())
        self.assertIn("Could not start microphone forwarding.", messages)
        self.assertNotIn(KEY, messages)

    def test_audio_error_stays_visible_with_video_progress_and_resets_on_next_start(self):
        from rocam_desktop import SessionConfig, SessionController

        calls = []

        def receiver(*_args, stopped, message, **_kwargs):
            calls.append(None)
            message(f"Virtual camera {len(calls)} ready.")
            if len(calls) == 1:
                while not stopped():
                    time.sleep(0.01)

        def audio_runner(*_args, **_kwargs):
            raise AudioError("Virtual microphone output stopped accepting audio.")

        controller = SessionController(receiver=receiver, audio_runner=audio_runner)
        first = SessionConfig(f"http://phone/?key={KEY}", audio_output="Loopback")
        self.assertTrue(controller.start(first))
        wait_until(lambda: "Virtual camera 1 ready." in controller.status_text and "Microphone" in controller.status_text)
        self.assertIn("Virtual camera 1 ready.", controller.status_text)
        self.assertIn("Microphone: Virtual microphone output stopped accepting audio.", controller.status_text)
        self.assertTrue(controller.stop())
        wait_until(lambda: not controller.is_active)

        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}")))
        wait_until(lambda: not controller.is_active)
        self.assertNotIn("Microphone", controller.status_text)

    def test_terminal_status_is_queued_before_next_session_can_start(self):
        from rocam_desktop import SessionConfig, SessionController

        terminal_entered = threading.Event()
        release_terminal = threading.Event()
        original_post = None

        def receiver(*_args, **_kwargs):
            pass

        controller = SessionController(receiver=receiver)
        original_post = controller._post

        def controlled_post(message):
            if message == "Rocam stopped.":
                terminal_entered.set()
                release_terminal.wait(1)
            original_post(message)

        controller._post = controlled_post
        config = SessionConfig(f"http://phone/?key={KEY}")
        self.assertTrue(controller.start(config))
        self.assertTrue(terminal_entered.wait(1))
        started_before_terminal = controller.start(config)
        release_terminal.set()
        wait_until(lambda: not controller.is_active)
        self.assertFalse(started_before_terminal)

    def test_usb_controls_use_root_url_and_replace_the_key_after_refresh(self):
        from rocam_desktop import SessionConfig, SessionController

        next_key = "b" * 32
        receiver_ready = threading.Event()
        refresh_requested = threading.Event()
        refreshed_ready = threading.Event()
        release_receiver = threading.Event()
        opened = []
        discovered = iter((
            f"http://127.0.0.1:8765/?key={KEY}",
            f"http://127.0.0.1:8765/?key={next_key}",
        ))

        @contextmanager
        def forwarder(*_args):
            yield lambda: True

        def discover(_link):
            return next(discovered)

        def receiver(url, *, connection_state, refresh_session, stopped, **_kwargs):
            connection_state(True, url)
            receiver_ready.set()
            while not stopped() and not release_receiver.is_set():
                time.sleep(0.01)
            connection_state(False, None)
            refresh_requested.set()
            refreshed = refresh_session()
            connection_state(True, refreshed)
            refreshed_ready.set()
            while not stopped():
                time.sleep(0.01)

        controller = SessionController(receiver=receiver, forwarder=forwarder, session_discoverer=discover)
        self.assertTrue(controller.start(SessionConfig("", usb=True)))
        self.assertTrue(receiver_ready.wait(1))
        self.assertTrue(controller.has_camera_controls)
        self.assertTrue(controller.open_camera_controls(opened.append))
        self.assertEqual(opened, [f"http://127.0.0.1:8765/?key={KEY}"])

        release_receiver.set()
        self.assertTrue(refresh_requested.wait(1))
        self.assertTrue(refreshed_ready.wait(1))
        self.assertTrue(controller.open_camera_controls(opened.append))
        self.assertEqual(opened[-1], f"http://127.0.0.1:8765/?key={next_key}")
        self.assertTrue(controller.stop())
        self.assertFalse(controller.has_camera_controls)
        wait_until(lambda: not controller.is_active)

    def test_usb_controls_clear_while_waiting_or_after_connection_loss(self):
        from rocam_desktop import SessionConfig, SessionController

        waiting = threading.Event()
        release_wait = threading.Event()

        @contextmanager
        def forwarder(*_args):
            yield lambda: True

        def discover(_link):
            waiting.set()
            release_wait.wait(1)
            raise UsbTransportError("lost")

        from rocam_receiver import UsbTransportError
        controller = SessionController(
            receiver=lambda *_args, **_kwargs: self.fail("receiver should not start"),
            forwarder=forwarder,
            session_discoverer=discover,
            reconnect_wait=lambda _seconds: None,
        )
        self.assertTrue(controller.start(SessionConfig("", usb=True)))
        self.assertTrue(waiting.wait(1))
        self.assertFalse(controller.has_camera_controls)
        self.assertFalse(controller.open_camera_controls(lambda _url: self.fail("browser should not open")))
        release_wait.set()
        self.assertTrue(controller.stop())
        wait_until(lambda: not controller.is_active)

    def test_controls_clear_immediately_when_receiver_loses_its_stream(self):
        from rocam_desktop import SessionConfig, SessionController

        connected = threading.Event()
        lose_stream = threading.Event()
        lost = threading.Event()

        def receiver(url, *, connection_state, stopped, **_kwargs):
            connection_state(True, url)
            connected.set()
            lose_stream.wait(1)
            connection_state(False, None)
            lost.set()
            while not stopped():
                time.sleep(0.01)

        controller = SessionController(receiver=receiver)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}")))
        self.assertTrue(connected.wait(1))
        self.assertTrue(controller.has_camera_controls)
        lose_stream.set()
        self.assertTrue(lost.wait(1))
        self.assertFalse(controller.has_camera_controls)
        self.assertFalse(controller.open_camera_controls(lambda _url: self.fail("browser should not open")))
        self.assertNotIn(KEY, controller.status_text)
        self.assertTrue(controller.stop())
        wait_until(lambda: not controller.is_active)


class DesktopAppStatusTests(unittest.TestCase):
    def test_camera_controls_button_tracks_session_availability_and_browser_failures_safely(self):
        from rocam_desktop import RocamDesktopApp

        class Button:
            def __init__(self):
                self.state = None

            def configure(self, **kwargs):
                self.state = kwargs["state"]

        class Value:
            value = ""

            def set(self, value):
                self.value = value

        class Controller:
            is_active = True
            is_stopping = False
            has_camera_controls = False

            def open_camera_controls(self, _opener):
                return False

        app = RocamDesktopApp.__new__(RocamDesktopApp)
        app.controller = Controller()
        app.start_button = Button()
        app.stop_button = Button()
        app.controls_button = Button()
        app.status = Value()
        app._browser_opener = lambda _url: self.fail("browser should not open")

        app._sync_controls()
        self.assertEqual(app.controls_button.state, "disabled")
        app.controller.has_camera_controls = True
        app._sync_controls()
        self.assertEqual(app.controls_button.state, "normal")
        app.open_camera_controls()
        self.assertEqual(app.status.value, "Could not open Camera controls in your default browser.")
        self.assertNotIn(KEY, app.status.value)

    def test_input_error_survives_idle_poll_after_previous_session(self):
        from rocam_desktop import RocamDesktopApp, SessionConfig, SessionController

        controller = SessionController(receiver=lambda *_args, **_kwargs: None)
        self.assertTrue(controller.start(SessionConfig(f"http://phone/?key={KEY}")))
        wait_until(lambda: not controller.is_active)
        controller.drain_messages()

        class Value:
            value = ""

            def set(self, value):
                self.value = value

        class Root:
            def after(self, *_args):
                pass

        app = RocamDesktopApp.__new__(RocamDesktopApp)
        app.controller = controller
        app.status = Value()
        app.root = Root()
        app._closing = False
        app._sync_controls = lambda: None

        def invalid_config():
            raise ReceiverError("Invalid Rocam Connection URL.")

        app._config = invalid_config
        app.start()
        self.assertEqual(app.status.value, "Error: Invalid Rocam Connection URL.")
        app.poll()
        self.assertEqual(app.status.value, "Error: Invalid Rocam Connection URL.")
