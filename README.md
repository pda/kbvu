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

This project initially targets macOS only and uses Zig. It is experimental: the
first phase determines whether host software can safely control the side LEDs
independently, using stock firmware if possible and an exact-model firmware
change only if necessary.

## Current result

The official firmware's limitation is now established. On official Air75 V3
ANSI firmware **1.0.16.6**:

- `D1` reports 104 LEDs, matching NuPhyIO's 84 key LEDs plus 20 side LEDs;
- `D6` can set both bars together as one effects zone; and
- hidden effect 21 plus undocumented `D8` provide verified per-key control for
  key indices `0…83`.

However, `D8` side-index writes still leave `D2` unchanged. Static analysis
explains why: `D8` stores all 104 RGB entries, but effect 21 renders
only indices `0…83`; a separate five-mode renderer owns side indices `84…103`
and has no host-frame mode. Stock firmware therefore exposes both bars only as
one `D6` effects zone, not as 20 independently host-controlled pixels. A
model-specific firmware change is required for stereo VU output. See
[the protocol research](docs/keyboard-protocol.md) for evidence and citations.

The macOS audio half is implemented independently of the keyboard path. A
first-party Core Audio process tap captures the global stereo output mix, and a
Zig RMS meter renders two ten-cell Unicode/ANSI rows. It can therefore visualize
Spotify and other application audio without a virtual loopback device. See
[the audio research](docs/macos-audio.md) for the design and permission details.

## Terminal stereo VU meter

Build and exercise the deterministic stereo test source without requesting any
macOS permission:

```console
zig build
zig build test
./zig-out/bin/kbvu-vu --source test --plain --frames 4
```

The plain mode emits numeric dBFS and exactly ten cells for each channel, making
it suitable for tests and agent inspection. Omit `--plain` for the compact live
ANSI display:

```text
L █████████░
R ███████░░░
```

To meter live system output on macOS 14.2 or newer, use the app launcher from an
interactive terminal:

```console
./zig-out/bin/kbvu-vu-live
```

The first run asks for **System Audio Recording Only** access. The launcher is
important: it starts the signed `zig-out/kbvu-vu.app` through LaunchServices so
TCC attributes the request to `kbvu-vu`, while routing ANSI output and Ctrl-C
back to the terminal. Directly executing the app's nested binary makes the
terminal application responsible for permission and is intentionally rejected.
An ad-hoc signature is used when no Apple Development identity is available, so
a changed rebuild may need permission to be granted again.

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
whole-zone command. It then selects effect 21, verifies and restores `D8` first
on known key-light index 1, and demonstrates the stock-firmware side-render
limitation with an exact `D2` readback check. It restores the complete original
lighting state on exit or failure.

## Plan

- [x] Record the project goal and exact connected keyboard model.
- [x] Collect documentation and open-source references for the Air75 V3 USB/HID protocol and side LEDs.
- [x] Build and run a minimal Zig program that displays whole-zone test colors and attempts independent patterns.
- [x] Establish the official firmware's control boundary: individually addressable internally, but only a shared side-light effects zone is exposed to the host.
- [x] Build an offline, exact-image-checked firmware patch candidate that renders host RGB entries `84…103` without contacting the keyboard.
- [ ] Verify the exact Air75 bootloader/recovery path, flash only with explicit approval, then visually verify independent control.
- [x] Research macOS system-output capture and stereo level measurement.
- [x] Build and verify a Zig terminal stereo VU meter using test audio.
- [ ] Connect the audio meter to the keyboard LED driver and verify the complete path.

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
