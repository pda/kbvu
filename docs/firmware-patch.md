# Air75 V3 firmware patch candidate

This document describes an **unflashed, hardware-untested** patch candidate for
the NuPhy Air75 V3 ANSI on official firmware 1.0.16.6. It does not authorize a
flash. A wrong or non-booting image can require opening the keyboard and using a
PCB boot pad to recover it.

## Intended contract

The patch adds one private lighting combination without changing the five stock
side modes:

- backlight effect 21 continues to render the host's `D8` RGB table;
- effect 21 renders all 104 entries instead of stopping at 84; and
- side mode 5 means that the stock side-effect dispatcher has no handler, so it
  leaves indices `84…103` to effect 21.

Normal side modes 0–4 retain their original dispatch paths. `kbvu` must select
effect 21 and side mode 5 before streaming, then restore the complete original
lighting state when it exits.

## Exact patch manifest

All offsets are raw offsets in
`Air75v3_US_v1.0.16.6_20260721.bin`. Each replacement changes only an RV32/RVC
immediate and preserves instruction size and alignment.

| Offset | Stock bytes | Patched bytes | Decoded change |
| ---: | --- | --- | --- |
| `0x0b5e6` | `13 07 30 05` | `13 07 70 06` | effect-21 completion index `83` → `103` |
| `0x0bbaa` | `93 06 40 05` | `93 06 80 06` | effect-21 maximum `84` → `104` |
| `0x0bbce` | `93 0a 40 05` | `93 0a 80 06` | effect-21 chunk clamp `84` → `104` |
| `0x14a3e` | `91 47` | `95 47` | accepted side-mode maximum `4` → `5` |

The source image must be exactly 284,112 bytes with SHA-256
`7fd339b0e22dff0843d6be7f8ac4a970c209b2362b49cc6babd60fcf3101642e`.
The four-edit output has SHA-256
`2d95a6a163b10ea1398e7603e9d4b59d1b115c192cae63a890e07310e1c4ac14`.
The S4 parser, USB setup, command dispatch table, `0xef` IAP handler, and startup
code remain byte-identical to stock.

Build the candidate without contacting the keyboard:

```console
mkdir -p firmware
python3 tools/patch_firmware.py \
  /path/to/Air75v3_US_v1.0.16.6_20260721.bin \
  firmware/Air75v3_US_v1.0.16.6_kbvu.bin
```

The tool refuses any source size or hash other than the exact official image,
checks every original instruction byte, checks that no unlisted byte changed,
and verifies the deterministic output hash. Firmware binaries and archives are
ignored by Git and must not be committed or redistributed.

## Evidence and remaining risk

Static analysis establishes the first three edits directly. The custom renderer
uses 21-pixel chunks. Its stock completion test ends after the fourth chunk,
whose exclusive end is 84; extending both bounds without changing the completion
threshold would therefore still skip the fifth chunk. With all three edits it
runs chunks `0…20`, `21…41`, `42…62`, `63…83`, and `84…103`.

The fourth edit is deliberately smaller than adding a new function. The existing
central side dispatcher checks for modes 0–4 and skips its mode-specific branch
for larger values. Allowing D6 to retain mode 5 should therefore prevent the
ordinary side renderer from overwriting effect 21. This is a static conclusion,
not hardware proof; the first post-flash test must verify exact `D5`/`D2`
readback and visually inspect a low-brightness left/right pattern.

[`gig3m/nuphykit`](https://github.com/gig3m/nuphykit/tree/66626a60c809be49805fadfe75e62db08182ffb7)
provides closely related but **Air100-only** evidence:

- its [captured IAP protocol](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L1914-L1952)
  writes and verifies the application image in 56-byte raw-HID blocks;
- a [one-byte modified Air100 image booted](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L2051-L2109),
  proving that model's bootloader performs no image signature or CRC rejection;
- its [physical recovery investigation](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L2447-L2492)
  found no key-at-plug-in route and concludes a PCB BOOT pad may be needed for a
  non-enumerating application; and
- its [recovery analysis](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L2800-L2855)
  explains why preserving stock USB and `0xef` code retains software recovery
  only when the application boots far enough to handle USB.

Those results support the method, but do not prove that Air75 boot PID `0x0722`
uses identical frames or timing. Before flashing this candidate, capture an
official Air75 update or independently verify its bootloader protocol, retain
the exact stock image, ensure NuPhyIO can recover PID `0x0722`, and obtain the
user's explicit approval for the flash itself.
