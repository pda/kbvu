# Project history and plan

`kbvu` began as an experiment to determine whether host software can safely
control the NuPhy Air75 V3's side LEDs independently, using stock firmware if
possible and an exact-model firmware change only if necessary. This document
records the outcome and the phased plan that produced it.

## Result

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
6 and stock side mode 4. See [the firmware patch notes](firmware-patch.md)
for the exact manifest, trial history, updater, and recovery evidence.

The macOS audio and keyboard paths are now connected. A first-party Core Audio
process tap captures the global stereo output mix, and the 20 Hz Zig display
loop renders it on the two physical bars. Independent lengths show left/right
volume; their shared colour runs from cyan through yellow to saturated red as
the mix becomes more bass-heavy. HID work remains outside the real-time audio
callback, and normal exit restores the saved RGB table and lighting modes. The
signed build is a menu-bar app for ongoing use; terminal rendering remains
available as an opt-in diagnostic. See [the audio research](macos-audio.md)
for the capture design and permission details.

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
- [x] Keep the app running across keyboard disconnects and resume automatically after reconnection.

Each phase is committed separately. Checkboxes are updated as evidence is
collected and each implementation phase is completed.
