# Keyboard VU (`kbvu`)

`kbvu` is a macOS menu-bar app that integrates a NuPhy Air75 V3 keyboard with
the Mac's audio. It turns the keyboard's two ten-LED side bars into a stereo VU
meter — bar length shows left/right volume, colour shows bassiness — and makes
a click of the volume knob cycle between your chosen audio output devices. The
VU meter relies on a small keyboard firmware patch described and tooled in this
repository; output cycling relies on remapping the knob click to F13.

## Side-light VU meter

A first-party Core Audio process tap captures the global stereo output mix and
renders it on the keyboard's side bars at 20 Hz. Each bar fills upward with the
volume of its channel, and the shared colour runs from cyan through yellow to
saturated red as the mix becomes more bass-heavy. Quitting the app restores the
keyboard's complete pre-run lighting state.

Stock firmware exposes the side LEDs to the host only as a single whole-zone
effect, so per-LED control requires a four-edit patch to official Air75 V3 ANSI
firmware 1.0.16.6. The patch, its tooling, and the recovery path are documented
in [the firmware patch notes](docs/firmware-patch.md).

## Volume-knob output cycling

Under **Cycle Audio Outputs (F13)** in the menu, check each output device that
should participate in the cycle. Each press of F13 switches to the next checked
device that is currently connected, using Core Audio's persistent device IDs so
choices survive disconnection.

The Air75 V3's volume knob clicks; remap that click from Mute to F13 in the
keyboard's remapping tool and the knob becomes an output-device switcher. No
firmware patch is needed for this feature.

## Building, running, and documentation

```console
zig build
open zig-out/kbvu.app
```

See [usage](docs/usage.md) for full menu-bar app details, the terminal VU meter
and live diagnostics, and the keyboard probe. Protocol research is in
[keyboard-protocol](docs/keyboard-protocol.md), audio-capture research in
[macos-audio](docs/macos-audio.md), the firmware change in
[firmware-patch](docs/firmware-patch.md), and the project's phased history in
[history](docs/history.md).

## License

[MIT](LICENSE)
