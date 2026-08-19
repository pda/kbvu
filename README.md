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

The official firmware's limitation and the required firmware change are now
established. On official Air75 V3 ANSI firmware **1.0.16.6**:

- `D1` reports 104 LEDs, matching NuPhyIO's 84 key LEDs plus 20 side LEDs;
- `D6` can set both bars together as one effects zone; and
- hidden effect 21 plus undocumented `D8` provide verified per-key control for
  key indices `0…83`.

However, `D8` side-index writes on stock firmware leave `D2` unchanged. Static
analysis explains why: `D8` stores all 104 RGB entries, but effect 21 renders
only indices `0…83`; a separate five-mode renderer owns side indices `84…103`
and has no host-frame mode.

An approved first flash extended effect 21 to all 104 entries. Exact `D2`
readback then passed for independent left/right bars, partial bars, and
alternating side pixels. That proved the bars are host-addressable with three
small renderer-bound edits, but stock `D6` made private side mode 5 impossible
to exit. A corrected fourth edit now makes mode 5 reversible. The corrected
image was written and verified in full; the complete demo passed exact readback
after every pattern, and a fresh probe confirmed restoration to backlight mode
6 and stock side mode 4. See [the firmware patch notes](docs/firmware-patch.md)
for the exact manifest, trial history, updater, and recovery evidence.

The macOS audio and keyboard paths are now connected. A first-party Core Audio
process tap captures the global stereo output mix, and the 20 Hz Zig display
loop renders it on the two physical bars. Independent lengths show left/right
volume; their shared colour runs from cyan through yellow to saturated red as
the mix becomes more bass-heavy. HID work remains outside the real-time audio
callback, and normal exit restores the saved RGB table and lighting modes. The
signed build is a menu-bar app for ongoing use; terminal rendering remains
available as an opt-in diagnostic. See [the audio research](docs/macos-audio.md)
for the capture design and permission details.

## Run continuously as a menu-bar app

Build and open the signed app:

```console
zig build
open zig-out/kbvu.app
```

Opening the app with no arguments starts system-audio capture and keyboard
output. The waveform item in the macOS menu bar shows that Keyboard VU is
running. Its **Start at Login** item toggles the native macOS Login Item and
shows a checkmark when enabled. A dash means macOS requires approval; selecting
the item then opens the relevant System Settings pane. Choose **Quit Keyboard
VU** to stop it and restore the keyboard's complete pre-run lighting state. The
app has no Dock icon and emits no terminal output.

The first run asks for **System Audio Recording Only** access. Keyboard output
requires the corrected firmware documented in [the patch notes](docs/firmware-patch.md),
a wired USB connection, and NuPhyIO to be closed. If either audio capture or the
keyboard cannot start, the app displays an error instead of disappearing
silently.

For launch-at-login use, first copy `zig-out/kbvu.app` to a stable location such
as `/Applications/kbvu.app`, open that copy, and enable **Start at Login** from
its menu. Re-copy it after rebuilding. The app uses macOS's native Login Item
service; no daemon or LaunchAgent is needed.

## Terminal stereo VU meter

Build and exercise the deterministic stereo test source without requesting any
macOS permission:

```console
zig build
zig build test
./zig-out/bin/kbvu-vu --source test --plain --frames 4
```

The plain mode emits numeric dBFS, low-frequency energy percentage/relative dB,
RGB, and exactly ten cells for each channel, making both magnitude and colour
suitable for tests and agent inspection. Its deterministic sequence includes
bass, treble, and silence. Use `--ansi` for the compact live display:

```text
L ▪▪▪▪▪▪▪▪▪▫
R ▪▪▪▪▪▪▪▫▫▫
```

The ANSI view uses 24-bit foreground colour on every filled `▪`: cyan means
little energy below roughly 200 Hz, yellow means a mixed spectrum, and red means
bass-heavy. Empty `▫` cells remain dim and neutral. Both rows use the same
spectral colour so their lengths remain an unambiguous stereo level comparison.
Terminal output is disabled unless `--ansi` or `--plain` is supplied.

For live diagnostics on macOS 14.2 or newer, use the app launcher from an
interactive terminal. `--keyboard` is optional:

```console
./zig-out/bin/kbvu-vu-live --ansi
./zig-out/bin/kbvu-vu-live --ansi --keyboard
```

The launcher starts `zig-out/kbvu.app` through LaunchServices so TCC
attributes the request to `kbvu-vu`, while routing requested output and Ctrl-C
back to the terminal. Directly executing the app's nested binary makes the
terminal application responsible for permission and is intentionally rejected.
An ad-hoc signature is used when no Apple Development identity is available, so
a changed rebuild may need permission to be granted again.

Keyboard output requires the corrected firmware documented in
[the patch notes](docs/firmware-patch.md), a wired USB connection, and NuPhyIO
to be closed. The filled LEDs use the same bass colour shown in the ANSI meter;
unfilled LEDs remain dark, and each bar fills upward from the physical bottom.
Ctrl-C and finite `--frames` runs restore the complete pre-run side-light state.

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
on known key-light index 1, and displays independent side patterns with an exact
`D2` readback check after each write. It restores the complete original lighting
state on exit or failure when running the corrected firmware.

## Plan

- [x] Record the project goal and exact connected keyboard model.
- [x] Collect documentation and open-source references for the Air75 V3 USB/HID protocol and side LEDs.
- [x] Build and run a minimal Zig program that displays whole-zone test colors and attempts independent patterns.
- [x] Establish the official firmware's control boundary: individually addressable internally, but only a shared side-light effects zone is exposed to the host.
- [x] Build an offline, exact-image-checked firmware patch candidate that renders host RGB entries `84…103` without contacting the keyboard.
- [x] Verify the exact Air75 updater protocol and physical recovery path without contacting the keyboard.
- [x] With explicit approval, flash the first candidate and verify independent `D8`/`D2` control of all 20 side LEDs.
- [x] Flash the corrected candidate and verify the complete demo plus stock-state restoration by exact readback.
- [x] Confirm visually that the displayed patterns match their descriptions.
- [x] Research macOS system-output capture and stereo level measurement.
- [x] Build and verify a Zig terminal stereo VU meter using test audio.
- [x] Connect the audio meter to the keyboard LED driver and exercise the complete live capture-to-D8 path.
- [x] Visually confirm physical channel orientation, upward bar direction, and bass colouring.
- [x] Package ongoing operation as a macOS menu-bar app with opt-in terminal output and a native Start at Login toggle.

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
