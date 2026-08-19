# macOS stereo system-audio capture

`kbvu` needs the instantaneous audio signal currently being sent by applications,
not the output device's volume-slider setting. macOS 14.2 and newer provide a
first-party, audio-only route: a Core Audio process tap. It does not require a
virtual loopback driver.

## Selected approach: Core Audio process tap

Apple's [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
sample describes taps as input streams for a HAL aggregate device. A tap can
capture one process, a set of processes, or the global output mix, and can mix
the captured device channels to stereo. `AudioHardwareCreateProcessTap` and
`AudioHardwareDestroyProcessTap` are available from macOS 14.2.

For this project the desired `CATapDescription` is:

```objc
[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]]
```

The SDK header says this captures every output process, excludes none, mixes to
two channels, and duplicates mono sources into left and right. The description
will also be private and use `CATapUnmuted`, so playback continues through the
real output while `kbvu` receives a copy. A stereo mixdown also gives the meter a
stable two-channel contract when the selected hardware has more outputs, such
as an eight-channel Studio Display.

The implementation sequence is:

1. Construct the private, unmuted global stereo `CATapDescription` and call
   `AudioHardwareCreateProcessTap`.
2. Read `kAudioTapPropertyUID` and `kAudioTapPropertyFormat` from the returned
   tap object. Reject an unexpected non-linear-PCM or non-stereo format rather
   than guessing its memory layout.
3. Create a unique private aggregate device with
   `AudioHardwareCreateAggregateDevice`. Its `taps` list contains a dictionary
   with the tap UID and drift compensation enabled. Set `tapautostart` so the
   aggregate starts when a tapped application first produces audio.
4. Register an `AudioDeviceIOProc` on the aggregate with
   `AudioDeviceCreateIOProcID`, then call `AudioDeviceStart`.
5. In the real-time callback, inspect every `AudioBuffer` and support both
   interleaved and planar Float32 stereo. Only write block sums to a fixed-size
   single-producer/single-consumer queue; do not allocate, print, lock, or call
   HID from the callback.
6. On shutdown, stop the device, destroy the IOProc, destroy the aggregate, and
   finally destroy the tap. Cleanup follows that reverse order on every error
   path.

The relevant declarations are in the installed macOS SDK's
`CoreAudio/AudioHardwareTapping.h`, `CoreAudio/CATapDescription.h`, and
`CoreAudio/AudioHardware.h`. The last header documents these aggregate keys:

| SDK key | Raw key | Purpose |
| --- | --- | --- |
| `kAudioAggregateDeviceNameKey` | `name` | transient device name |
| `kAudioAggregateDeviceUIDKey` | `uid` | unique aggregate UID |
| `kAudioAggregateDeviceIsPrivateKey` | `private` | keep it process-local and nonpersistent |
| `kAudioAggregateDeviceIsStackedKey` | `stacked` | use a normal, nonstacked aggregate |
| `kAudioAggregateDeviceTapListKey` | `taps` | array containing the sub-tap description |
| `kAudioSubTapUIDKey` | `uid` | UID returned for the process tap |
| `kAudioSubTapDriftCompensationKey` | `drift` | compensate the sub-tap clock |
| `kAudioAggregateDeviceTapAutoStartKey` | `tapautostart` | start on first tapped audio |

Apple's header specifically requires `tapautostart` aggregates to be private.

## Permission and packaging

Apple requires `NSAudioCaptureUsageDescription` in `Info.plist`. The first start
of an aggregate containing a tap requests **System Audio Recording Only**
permission. This differs from microphone access and from ScreenCaptureKit's
screen-recording path.

On macOS 26, `kbvu` is therefore built as a small `.app` bundle with a stable
bundle identifier even though its executable is terminal-oriented. It must be
started through LaunchServices: directly executing a child process from a
terminal makes that terminal the TCC-responsible application, and third-party
terminals may not carry `NSAudioCaptureUsageDescription`.
`zig-out/bin/kbvu-vu-live` uses `open` to give `kbvu-vu.app` its own TCC identity
while attaching its standard streams to the current TTY. The launcher forwards
Ctrl-C directly, and the display leaves the cursor enabled so an abrupt exit
cannot leave the terminal in a damaged state.

Keeping a stable signing identity avoids turning each rebuild into a different
TCC client. Development can use one ad-hoc-signed final build, but changing its
contents may require granting it again; a persistent Apple Development signature
is the reliable long-term option.

No microphone entitlement, audio driver, Audio MIDI Setup aggregate, or change
to the user's default output device is part of this design. If permission is
denied, the program must explain how to enable System Settings → Privacy &
Security → System Audio Recording Only and exit without touching the keyboard.

## Stereo level calculation

Capture and rendering run at different rates. The callback records, for each
channel and audio block:

- sum of squares: \(s = \sum_i x_i^2\); and
- sample count: \(N\), giving RMS \(r = \sqrt{s/N}\).

The terminal meter displays RMS in dBFS:

\[d = 20\log_{10}(\max(r, 10^{-6}))\]

and map −50 dBFS through 0 dBFS onto ten equal 5 dB segments. Values below
−50 dBFS are dark and 0 dBFS fills the bar. Left and right are calculated
independently. A fast attack and time-based decay are applied outside the audio
callback so the bars remain readable between callbacks without making the
measurement depend on the hardware block size.

Colour represents spectral balance rather than a single “dominant frequency.”
The callback passes each channel through a two-pole 200 Hz low-pass filter and
also accumulates its sum of squares. For combined left/right low-pass energy
\(s_b\) and full-band energy \(s\), the displayed bass amount is:

\[b = 10\log_{10}(\operatorname{clamp}(s_b/s, 10^{-6}, 1))\]

The filter coefficient is calculated from the actual Core Audio tap sample
rate. This adds fixed state and arithmetic but no allocation, locking, FFT, or
other real-time-unsafe work to the callback. Both bars share one smoothed value:
at or below −20 dB it is cyan, at −10 dB it is yellow, and at or above −4 dB it
is red, with 24-bit RGB interpolation between those points. Audio at or below
the −50 dBFS display floor moves the colour toward cyan instead of allowing
noise to choose it. Only filled cells are coloured; dim empty cells still show
the ten-cell capacity.

`--plain` exposes numeric dBFS, bass percentage/relative dB, RGB, and the
ten-segment bars. The built-in `--source test` produces exact-period 80 Hz,
2 kHz, and 200 Hz stereo sine blocks at −6/−18, −18/−6, and −12/−12 dBFS
followed by silence. It traverses the same strided sample, RMS, spectral,
ballistics, and rendering code as live capture without depending on TCC or an
output device. `--frames N` makes the executable terminate deterministically
for automated checks.

## Implementation and verification

- `src/audio_capture.m` owns the private unmuted tap, tap-only aggregate,
  Float32 layout checks, sample-rate handoff, IOProc, and reverse-order cleanup.
- `src/meter.zig` owns the fixed lock-free queue, independent stereo RMS,
  low-frequency energy analysis, 30 dB/s decay, ten-cell mapping, test source,
  and plain/ANSI renderers.
- `src/keyboard_lights.zig` maps those same stereo lengths and shared bass colour
  onto side indices `84…103` in reverse index order so each bar grows upward,
  selects private renderer mode 5, and restores the saved RGB table and lighting
  state on exit.
- `src/vu_meter.zig` owns argument parsing, the 20 Hz display loop, and signal
  cleanup. With `--keyboard`, this non-real-time loop also performs D8 writes;
  the Core Audio callback never touches HID.
- `resources/Info.plist` and `tools/run_vu.sh` provide the signed app identity
  and LaunchServices/TTY bridge required by TCC.

`zig build test` verifies interleaved channel identity, known RMS values, 80 Hz
versus 2 kHz separation, colour interpolation and silence behavior, ballistics,
all dBFS cell boundaries, deterministic plain rendering, and the two-line
truecolour ANSI shape. Running
`./zig-out/bin/kbvu-vu --source test --plain --frames 4` verifies the complete
test-source executable path. A LaunchServices-started live probe captured a
generated `afplay` WAV at approximately −21 dBFS left and −33 dBFS right,
preserving the file's expected 12 dB channel separation and orientation. The
absolute level reflects the active output route's stereo mixdown. The probe also
established that direct execution is denied by TCC under a terminal lacking the
usage key; this is why the supported live path is `zig-out/bin/kbvu-vu-live`
rather than the nested executable. A later `--keyboard` run completed 130 live
system-audio frames while changing both bar lengths and bass RGB, then a fresh
keyboard probe confirmed restoration to backlight mode 6 and stock side mode 4.

## Open-source corroboration

[`ravila4/nuphy-rgb-music`](https://github.com/ravila4/nuphy-rgb-music/tree/6e3086dffbbcb70daafb20d486e704be99bdf521)
uses this architecture on macOS:

- [`coreaudio_tap.py`](https://github.com/ravila4/nuphy-rgb-music/blob/6e3086dffbbcb70daafb20d486e704be99bdf521/src/nuphy_rgb/coreaudio_tap.py#L159-L193)
  creates an unmuted private global stereo tap and private tap-backed aggregate;
- its [IOProc setup and cleanup](https://github.com/ravila4/nuphy-rgb-music/blob/6e3086dffbbcb70daafb20d486e704be99bdf521/src/nuphy_rgb/coreaudio_tap.py#L222-L291)
  corroborate the register/start and stop/destroy lifecycle; and
- its [callback](https://github.com/ravila4/nuphy-rgb-music/blob/6e3086dffbbcb70daafb20d486e704be99bdf521/src/nuphy_rgb/coreaudio_tap.py#L198-L218)
  demonstrates live sample delivery.

Its callback must not be copied literally: it assumes one interleaved Float32
buffer, allocates NumPy arrays on the real-time thread, and downmixes left and
right to mono. Its later “VU” is bass-spectrum energy with automatic gain, not a
stereo full-band level meter. Its Air75 V2 HID protocol is also unrelated to the
Air75 V3 keyboard path documented elsewhere in this repository.

Other possible capture routes were rejected for the first implementation:

- ScreenCaptureKit can provide system audio, but requests broader screen/system
  capture access and wraps audio in `CMSampleBuffer`; it is unnecessary when the
  dedicated audio tap works.
- BlackHole and similar loopback devices work on older macOS versions but add an
  installation and output-routing requirement.
- microphone loopback measures the room and speakers rather than the digital
  left/right signal and cannot meet the goal.
