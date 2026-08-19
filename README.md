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

## Current result

Feasibility is **unresolved**. The probe has established that:

- `D1` reports 104 LEDs, matching NuPhyIO's 84 key LEDs plus 20 side LEDs;
- `D2` reads rendered RGB values for indices `84…103`;
- `D6` can set both bars together as one effects zone; and
- undocumented `D8` accepts `[index, red, green, blue]` records.

The first `D8` side-light test left both bars dim white and produced unchanged
`D2` readback, but that test used ordinary backlight effect 6. Subsequent
research found that the closely related Air100 V3 renders its `D8` buffer only
under hidden effect 21. Therefore the first result does **not** establish that
the Air75 V3 lacks per-LED host control.

A follow-up attempted to select effect 21 through `D6`, but exact `D5` readback
verification failed, so the program restored the original state without sending
another `D8` write. Testing is paused while the keyboard firmware is reviewed or
updated. See [the protocol research](docs/keyboard-protocol.md) for evidence,
citations, and the next experiment.

## Keyboard probe

Build with Zig 0.16 or newer and close NuPhyIO before running:

```console
zig build
./zig-out/bin/kbvu-keyboard-demo --probe
./zig-out/bin/kbvu-keyboard-demo --hold-ms 1500
```

`--probe` performs management reads plus the required `EE` session handshake;
it sends no lighting or persistent-configuration write. The full run temporarily
shows both bars in red, green, blue, and dim white through the supported
whole-zone command. It then requires effect 21 to survive exact `D5` readback,
verifies and restores `D8` first on known key-light index 1, and only then
attempts independent bar patterns with exact `D2` readback. It restores the
complete original lighting state on exit or failure.

## Plan

- [x] Record the project goal and exact connected keyboard model.
- [x] Collect documentation and open-source references for the Air75 V3 USB/HID protocol and side LEDs.
- [x] Build and run a minimal Zig program that displays whole-zone test colors and attempts independent patterns.
- [ ] Establish independent control of the two ten-LED bars. **Pending firmware review/update and an effect-21 retest.**
- [ ] Research macOS system-output capture and stereo level measurement. **Paused at the keyboard feasibility gate.**
- [ ] Build and verify a Zig terminal stereo VU meter using test audio. **Paused at the keyboard feasibility gate.**
- [ ] Connect the audio meter to the keyboard LED driver and verify the complete path.

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
