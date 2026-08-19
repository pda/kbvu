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

## Result

The stock Air75 V3 firmware does **not** expose the two bars as independently
writable LEDs. The Zig hardware probe established two distinct behaviors:

- command `D6` changes and reads back the mode, brightness, and one RGB color
  for both side bars as a single effects zone; and
- undocumented command `D8` accepts writes to the 20 side-light indices
  `84…103`, but `D2` readback remains unchanged. `D8` is an override for the
  84 key LEDs only.

A five-second manual check confirmed the same result visually: the supported
`D6` test changed both bars red, green, blue, and dim white, while the attempted
`D8` red/blue split left both bars dim white.

The official NuPhyIO S4 driver likewise leaves its per-light `setCustomLight`
operation unimplemented for this keyboard. Independent host-driven side LEDs
would therefore require new Air75 V3 firmware with a streaming HID command.
Existing streaming and side-light projects require model-specific custom
firmware and do not support the Air75 V3.

This blocks a stereo ten-segment keyboard VU: the available `D6` control can
only show one shared value on both bars. Per the feasibility gate above, the
audio phases have not been started.

## Keyboard probe

Build with Zig 0.16 or newer and close NuPhyIO before running:

```console
zig build
./zig-out/bin/kbvu-keyboard-demo --probe
./zig-out/bin/kbvu-keyboard-demo --hold-ms 1500
```

`--probe` is read-only. The full run temporarily shows both bars in red, green,
blue, and dim white through the supported whole-zone command. It then attempts
independent red/blue bars, holds that request for `--hold-ms` so it can be
checked visually, requires exact `D2` readback, reports
`VerificationFailed` on the stock firmware, and restores the original state.

## Plan

- [x] Record the project goal and exact connected keyboard model.
- [x] Collect documentation and open-source references for the Air75 V3 USB/HID protocol and side LEDs.
- [x] Build and run a minimal Zig program that displays whole-zone test colors and attempts independent patterns.
- [ ] Establish independent control of the two ten-LED bars. **Blocked by stock firmware.**
- [ ] Research macOS system-output capture and stereo level measurement. **Not started because keyboard feasibility failed.**
- [ ] Build and verify a Zig terminal stereo VU meter using test audio. **Not started because keyboard feasibility failed.**
- [ ] Connect the audio meter to the keyboard LED driver and verify the complete path. **Blocked by stock firmware.**

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
