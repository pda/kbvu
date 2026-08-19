# Keyboard VU (`kbvu`)

`kbvu` is an experiment to turn the two ten-LED side bars on a NuPhy Air75 V3
keyboard into a stereo volume-unit display. The left bar should show the level
of the audio currently playing on the Mac's left output channel, and the right
bar should show the right channel.

The target keyboard was identified while connected over USB as:

- Product: **NuPhy Air75 V3**
- USB vendor ID: `0x19f5` (NuPhy)
- USB product ID: `0x1028`
- USB serial string: `NuPhy Keybord 0720`

This project initially targets macOS only and uses Zig. It is experimental:
before capturing audio, it must establish that host software can safely control
the side LEDs independently and at a useful refresh rate.

## Plan

- [x] Record the project goal and exact connected keyboard model.
- [x] Collect documentation and open-source references for the Air75 V3 USB/HID protocol and side LEDs.
- [ ] Build a minimal Zig program that displays test patterns on both LED bars.
- [ ] Research macOS system-output capture and stereo level measurement.
- [ ] Build and verify a Zig terminal stereo VU meter using test audio.
- [ ] Connect the audio meter to the keyboard LED driver and verify the complete path.

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
