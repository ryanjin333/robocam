# Rocam feature matrix

| Feature | Linux | macOS | Windows |
| --- | --- | --- | --- |
| USB-only automatic connection | Exercised | Code and setup present; physical check pending | Code and setup present; physical check pending |
| Desktop GUI and `--usb --fps 20` receiver | Exercised | Native build path present | Native build path present |
| Virtual-camera output | v4l2loopback | OBS Virtual Camera required | OBS Virtual Camera required |
| Optional LiDAR depth view | Available when supported by phone | Same receiver support | Same receiver support |
| Microphone forwarding | Available only when configured | Available only when configured | Available only when configured |
| Native release packaging | Tarball build path | Zip build path | Zip plus local USB tools build path |

LiDAR depth has one comparison point only. It is useful as a view, not a
complete robot-accuracy or safety certification. Physical camera, cable,
reconnect, and target-app acceptance still need to be performed for macOS and
Windows.
