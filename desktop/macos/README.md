# Rocam for Mac

This is the self-contained native Mac receiver. It uses the macOS `usbmuxd`
socket already present on the Mac, and a bundled CoreMediaIO Camera Extension;
it does not install Homebrew, Python, iproxy, OBS, a driver, or a helper.

Build an unsigned developer bundle with `./build-unsigned.sh`. To run it on a
real Mac, sign both targets with the same Apple development or Developer ID
team, install `Rocam.app` in `/Applications`, open it, and choose **Enable
Rocam Camera**. macOS presents the normal Camera Extension approval. Connect
and trust one iPhone running Rocam; Rocam starts automatically when exactly
one iPhone is available. If several iPhones are attached, it asks the user to
choose one before starting. The output is intended to appear as `Rocam` at
fixed 1280x720 BGRA / 30 fps with portrait frames letterboxed.

This native receiver is experimental developer source, not a packaged release.
Signing, extension approval, and placeholder output in a normal macOS camera
consumer have been tested. End-to-end live iPhone video through the extension,
including disconnect and reconnect behavior, is not yet verified. Use the
[standard desktop setup](../README.md) for the existing receiver.

The Mac host directly queries `/var/run/usbmuxd`, asks the selected USB iPhone
for the established `/usb/session` bootstrap, and requests its MJPEG stream.
Session keys and device identifiers are never logged. iPads are deliberately
not silently selected; Wi-Fi and microphone transport are absent. The public
CMIO sink authorization API does not expose a producer's signer or team, so
another local CMIO client could feed or starve the sink; a signed system
extension and normal macOS approval remain the trust boundary.

For the transport socket cancellation regression check, run:

```sh
xcrun swiftc Transport/Sources/RocamUSB/USBProtocol.swift Rocam/USBTransport.swift Transport/Integration/main.swift -o /tmp/rocam-socket-lifecycle -framework Foundation
/tmp/rocam-socket-lifecycle
```

It uses the production `UnixSocket` against a local UNIX listener to verify a
blocked read is cancelled and rapid reconnects do not reuse a live descriptor.
