# RoboCam

Turn your iPhone into a USB webcam, with optional LiDAR depth.

LiDAR is a sensor that helps the phone see how far things are from it. Your
iPhone may show this as a depth view when it has LiDAR.

The app and camera may be called **Rocam**. That name is kept for compatibility.

## Setup

You do these two setup steps once.

1. **Set up the iPhone on a Mac.** Open `Rocam.xcodeproj` in Xcode. Choose your Apple
   Team, select your real iPhone, and press **Run**. Open the app on the phone.

2. **Set up the computer.** Download the official **Source code (zip)** from
   the [GitHub releases page](https://github.com/ryanjin333/robocam/releases),
   and extract the full repository. Then run the command for your computer:

   - Linux: `python3 desktop/setup_linux.py`
   - macOS: `bash desktop/setup_macos.sh`
   - Windows PowerShell: `./desktop/setup_windows.ps1`

   A macOS release can also use `bash setup_macos.sh` when the script and
   release wheel are next to each other. An unpacked Windows release can use
   `./setup_windows.ps1`.

The setup installs the basic virtual-camera pieces. macOS and Windows use OBS;
Linux uses its virtual-camera driver. Your operating system may ask you to
approve normal camera, driver, or security prompts. macOS setup requires
Homebrew.

## Use it

1. Connect the iPhone to the computer with a USB cable.
2. Unlock the iPhone and tap **Trust** if the iPhone asks.
3. Keep the RoboCam app open.

The computer connects by itself and sends video at 20 frames per second. There
is no **Start stream** button. In your video app, choose **Rocam** on Linux, or
**OBS Virtual Camera** on macOS and Windows.

The microphone is off by default. RoboCam uses USB for this connection.

## More information

See the [desktop guide](desktop/README.md) for computer details and the
[feature matrix](FEATURE_MATRIX.md) for platform details.
