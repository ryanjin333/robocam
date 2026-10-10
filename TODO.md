# RoboCam next steps

- Run the first GitHub Actions builds after the public repository is pushed.
- Test the macOS bundle with a trusted phone, OBS Virtual Camera, reconnect, and
  a real camera consumer.
- Test the Windows bundle with Apple Devices, a trusted phone, OBS Virtual
  Camera, reconnect, and a real camera consumer.
- Publish a signed iOS build through the appropriate Apple distribution path if
  wider phone installation is needed. The repository's CI iOS build is unsigned.
- Measure LiDAR accuracy over the intended robot ranges before treating it as a
  measurement input.
- Keep microphone forwarding off unless a deployment explicitly needs it.
