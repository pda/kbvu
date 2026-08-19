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
   interleaved and planar Float32 stereo. Only update preallocated atomic level
   accumulators; do not allocate, print, lock, or call HID from the callback.
6. On shutdown, stop the device, destroy the IOProc, destroy the aggregate, and
   finally destroy the tap. Zig `defer` blocks should mirror that reverse order
   on every error path.

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

On macOS 26, `kbvu` should therefore be built as a small `.app` bundle with a
stable bundle identifier even though its executable is terminal-oriented. The
binary inside the bundle can still render ANSI to its controlling terminal.
Keeping a stable signing identity avoids turning each rebuild into a different
TCC client. Development can use one ad-hoc-signed final build, but changing its
contents may require granting it again; a persistent Apple Development signature
is the reliable long-term option.

No microphone entitlement, audio driver, Audio MIDI Setup aggregate, or change
to the user's default output device is part of this design. If permission is
denied, the program must explain how to enable System Settings → Privacy &
Security → System Audio Recording Only and exit without touching the keyboard.

## Stereo level calculation

Capture and rendering run at different rates. The callback accumulates, for each
channel and display interval:

- peak magnitude: \(p = \max_i |x_i|\); and
- mean square: \(q = \frac{1}{N}\sum_i x_i^2\), with RMS \(r = \sqrt{q}\).

The first terminal version will display RMS in dBFS:

\[d = 20\log_{10}(\max(r, 10^{-6}))\]

and map −50 dBFS through 0 dBFS onto ten equal 5 dB segments. Values below
−50 dBFS are dark and 0 dBFS fills the bar. Left and right are calculated
independently. A fast attack and time-based decay are applied outside the audio
callback so the bars remain readable between callbacks without making the
measurement depend on the hardware block size.

The terminal demo should expose the numeric dBFS values as well as ten-segment
bars. That makes an end-to-end test unambiguous: a stereo test file with isolated
left/right tones at known digital amplitudes can be played with `afplay`, and the
recorded meter output can be checked for channel identity, relative level,
silence, attack, and decay.

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
