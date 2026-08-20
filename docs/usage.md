# Building and running `kbvu`

Build with Zig 0.16 or newer. Keyboard output requires the corrected firmware
documented in [the patch notes](firmware-patch.md), a wired USB connection, and
NuPhyIO to be closed.

The target keyboard was identified while connected over USB as:

- Product: **NuPhy Air75 V3**
- USB vendor ID: `0x19f5` (NuPhy)
- USB product ID: `0x1028`
- USB serial string: `NuPhy Keybord 0720`

## Run continuously as a menu-bar app

Build and open the signed app:

```console
zig build
open zig-out/kbvu.app
```

Opening the app with no arguments starts system-audio capture and keyboard
output. The waveform item in the macOS menu bar shows that Keyboard VU is
running. Under **Cycle Audio Outputs (F13)**, check each output device that
should participate in the cycle, then remap the knob button from Mute to F13 in
the keyboard's remapping tool. Each press switches to the next checked device
that is currently connected. Device choices use Core Audio's persistent device
IDs, so a checked USB output remains selected after it disconnects and
reconnects. The current output is labelled in the menu; if zero available
devices are checked, or the sole checked device is already current, F13 does
nothing.

The **Start at Login** item toggles the native macOS Login Item and shows a
checkmark when enabled. A dash means macOS requires approval; selecting the item
then opens the relevant System Settings pane. Choose **Quit Keyboard VU** to
stop it and restore the keyboard's complete pre-run lighting state. The app has
no Dock icon and emits no terminal output.

The app can start without the keyboard. While the Air75 is absent, its menu
shows a disconnected warning and retries silently once per second. Unplugging
the keyboard during use has the same behavior; reconnecting it by USB
automatically restores VU output without restarting the app.

The first run asks for **System Audio Recording Only** access. Audio-capture
startup failures are displayed as errors; keyboard availability is reported by
the menu status and handled by the retry loop.

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

The filled LEDs use the same bass colour shown in the ANSI meter; unfilled LEDs
remain dark, and each bar fills upward from the physical bottom. Ctrl-C and
finite `--frames` runs restore the complete pre-run side-light state.

## Keyboard probe

Close NuPhyIO before running:

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
