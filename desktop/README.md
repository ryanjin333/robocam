# Rocam desktop

The desktop receiver publishes the Rocam phone feed as a virtual camera. The
GUI starts USB mode automatically. The command-line equivalent is:

```sh
rocam-webcam --usb --fps 30
```

USB mode needs `iproxy` and never falls back to Wi-Fi. The phone must be
connected, unlocked, trusted, and running Rocam. A selected device can be
given with `--udid DEVICE_ID`.

## Install and build

For local development, use Python 3.12 and install the receiver from the
repository root:

```sh
python3.12 -m pip install './desktop[audio,video,build]'
python3.12 desktop/build_app.py
```

The native PyInstaller app is written to `desktop/dist/app/`. Build each native
bundle on the matching operating system.

- Linux needs `v4l2loopback`, `python3-tk`, and `libusbmuxd-tools`.
- macOS setup installs Homebrew `libusbmuxd`, Python 3.12, and OBS when needed.
  Enable the OBS Camera Extension yourself in **System Settings → General →
  Login Items & Extensions → Camera Extensions**.
- Windows setup uses official winget packages for Python 3.12, OBS, and Apple
  Devices. It uses the released `iproxy` tools locally and does not change the
  global PATH or PowerShell execution policy.

Run [`setup_macos.sh`](setup_macos.sh) or
[`setup_windows.ps1`](setup_windows.ps1) from an unpacked release. Linux has a
separate per-user systemd installer in [`install_linux.py`](install_linux.py).
All startup installers use `--usb --fps 30`, protect foreign configurations,
and leave microphone forwarding disabled.

The iPhone Settings FPS row and desktop receiver both default to 30 FPS. The
phone offers 15, 20, 30, 60, or 120 FPS when the active camera mode supports
them; higher FPS may require turning LiDAR off. The saved selection, including
20 FPS, remains in effect. For 60 FPS, choose **Settings → FPS → 60** on the
phone, then start the receiver with `--fps 60`.

## Endpoints and privacy

The phone stream is authenticated by a session key. Development URLs use a
placeholder only, for example `http://127.0.0.1:8765/?key=<SESSION_KEY>`.
`/stream` serves camera MJPEG and `/depth.mjpg` serves the optional depth view.
Encoded H.264 and HEVC endpoints need the `video` extra. Keep real session URLs
private: they authorize access to the active phone session.

`/robot.frame` is for a robot program that needs both views. It is authenticated
over the localhost USB tunnel and can be decoded with
`rocam_robot.parse_robot_frame`: RGB is `uint8`, depth is Float32 metres, and
the frame includes calibration metadata.

The optional `audio` extra supports a named desktop audio output, but no setup
script enables it. Rocam does not ask for or forward phone microphone audio
unless the user explicitly configures that feature.
