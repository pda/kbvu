# Air75 V3 firmware patch

This document describes the exact firmware change for the NuPhy Air75 V3 ANSI
on official firmware 1.0.16.6. The first hardware trial proved the renderer
change but exposed a misidentified fourth edit. The corrected image documented
here has now been flashed and passed exact host readback plus lighting-state
restoration. Firmware modification still carries real risk, although an Air75
V3-specific physical recovery path has been identified below.

## Intended contract

The patch adds one private lighting combination without changing the five stock
side modes:

- backlight effect 21 continues to render the host's `D8` RGB table;
- effect 21 renders all 104 entries instead of stopping at 84; and
- side mode 5 means that the stock side-effect dispatcher has no handler, so it
  leaves indices `84…103` to effect 21; and
- `D6` can replace private mode 5 with a stock mode when `kbvu` exits.

Stock `D6` already accepts an incoming mode 5 while the current mode is 0–4,
but refuses every later mode change because its setter checks the *current*
mode against 4. The fourth edit extends only that current-state guard to 5.
Normal side modes 0–4 retain their original dispatch paths. `kbvu` selects
effect 21 and side mode 5 before streaming, then restores the complete original
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
| `0x0de1a` | `11 47` | `15 47` | restorable current side-mode maximum `4` → `5` |

The source image must be exactly 284,112 bytes with SHA-256
`7fd339b0e22dff0843d6be7f8ac4a970c209b2362b49cc6babd60fcf3101642e`.
The corrected four-edit output has SHA-256
`10df67aaf7d4841cd59340d08a9699e7973fe6b5d8c0fc6aefde992ef0129e7d`.
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

The Zig updater is also locked to that output size and hash. Its default mode
validates the file without opening a USB device:

```console
zig build
./zig-out/bin/kbvu-firmware-flash \
  firmware/Air75v3_US_v1.0.16.6_kbvu.bin
```

Adding `--flash-candidate` enters IAP, erases, writes, verifies, reboots, and
checks application re-enumeration. That flag changes keyboard firmware and must
only be used with explicit approval for the specific image.

## Evidence and remaining risk

Static analysis establishes the first three edits directly. The custom renderer
uses 21-pixel chunks. Its stock completion test ends after the fourth chunk,
whose exclusive end is 84; extending both bounds without changing the completion
threshold would therefore still skip the fifth chunk. With all three edits it
runs chunks `0…20`, `21…41`, `42…62`, `63…83`, and `84…103`.

The existing central side dispatcher checks for modes 0–4 and skips its
mode-specific branch for larger values. `D6`'s mode setter at `0x0de12` first
reads the current side mode, then ignores the requested replacement when the
current value exceeds 4. It does not validate the incoming value before storing
it. The fourth edit therefore permits exactly the transition back out of private
mode 5; it neither adds another renderer nor changes any stock dispatch path.

## First hardware trial and correction

The initial image used the same three renderer edits but changed `c.li a5, 4`
to `c.li a5, 5` at `0x14a3e`. Its SHA-256 was
`2d95a6a163b10ea1398e7603e9d4b59d1b115c192cae63a890e07310e1c4ac14`.
That instruction actually handles lighting-state byte 2, not side mode byte 9,
so the edit was unrelated and shifted a five-entry lookup table by one.

With explicit approval, that initial image was flashed over the normal updater:

- all 5,074 write blocks and all 5,074 verify blocks were acknowledged;
- the keyboard rebooted as application `19f5:1028`, continued typing normally,
  and answered `A1` with `10 00 01 aa 06 00 50 50` immediately after flashing;
- effect 21 and side mode 5 survived exact `D5` readback; and
- `D8` patterns for split red/blue, one full and one empty bar, 3/10 and 7/10
  bars, and alternating pixels all passed exact `D2` readback at indices
  `84…103`.

This establishes independent host control and proves the first three edits.
Cleanup restored the saved RGB values and backlight mode, but side mode remained
5 because of the stock current-mode guard above. The keyboard remains bootable
and usable; the corrected fourth edit is needed both to restore a stock side
mode and to make normal `kbvu` shutdown reversible.

With fresh explicit approval, the corrected image was then flashed over the
same normal updater and direct USB-C connection:

- SHA-256 was locked to
  `10df67aaf7d4841cd59340d08a9699e7973fe6b5d8c0fc6aefde992ef0129e7d`;
- all 5,074 write blocks and all 5,074 verify blocks were acknowledged;
- the keyboard rebooted as `19f5:1028` and answered `A1` with
  `10 00 01 aa 06 00 49 49` immediately after flashing;
- `D6` successfully changed the stranded private mode 5 back to stock mode 4;
- every whole-zone and indexed demo pattern passed exact readback; and
- after cleanup, a fresh process read back backlight mode 6, side mode 4, and
  the original side RGB table.

The corrected contract is therefore hardware-verified. The demo also recovers
mode 5 to stock mode 4 before taking its baseline, so a previous interrupted
run does not preserve the private mode indefinitely.

## Exact official Air75 updater protocol

The Air100 capture below was initially only a lead. Static inspection of the
official **NuPhyIO 2.2.6** macOS app now independently establishes the Air75 V3
path. Its bundled `static/js/main.7461f1d3.js` has SHA-256
`13dc517878cd4cc879c116662b8ff36645aa4b71dccf70072100ea764e4ea5e9`.
The relevant facts are all in that bundle:

- the device table pairs Air75 V3 ANSI application `19f5:1028` with updater
  `19f5:0722` (`6645:1826` in decimal);
- the Air75 V3 feature record is mechanical, which makes the common updater use
  56-byte data blocks rather than its 32-byte fallback;
- the HID transport pads every command to 64 bytes and sends report ID zero;
- the application-device path calls `enterIap()`, waits 1.5 seconds, and then
  opens the updater, while an already-enumerated updater device goes directly to
  the same firmware loader; and
- the updater writes the image once and verifies it by transmitting the complete
  image a second time.

The frames selected for this exact model are:

| Phase | 64-byte report contents |
| --- | --- |
| erase | `81 07 00 00 00 00 00`, then zeros |
| write | `80`, data length (at most 56), 32-bit little-endian image offset, data |
| verify | `82`, data length (at most 56), 32-bit little-endian image offset, data |
| finalize | `83 02 00 00`, then zeros |
| success/reboot | `84 01 01`, then zeros |

For write and verify packets, NuPhyIO accepts a block only when response bytes
0–1 are both zero. Offsets begin at zero and the final block is short. The
current [official firmware metadata API](https://drive.nuphy.io/prod-api/api/nuphyIo/getLastFirmwareVersionsByType?businessId=1930212869851615233&type=1)
returns `e2Prom: "N"`, which is why byte 6 of the erase frame is zero. The same
metadata hash-locks the uncompressed application image to the source hash above.

This is the same write/verify protocol captured independently on Air100, but the
Air75 VID/PIDs, 56-byte selection, metadata flag, and recovery routing now come
from NuPhyIO's Air75-specific data rather than a cross-model inference. The
first hardware trial subsequently confirmed the complete Air75 erase, write,
verify, finalize, reboot, and application re-enumeration path.

## Recovery paths

There are two distinct boot environments:

1. **Normal updater (`19f5:0722`).** NuPhyIO 2.2.6 explicitly recognizes this as
   the Air75 V3 updater and can load the latest official firmware without first
   contacting the application. An interrupted custom update that remains in
   this environment can therefore be retried or restored in software.
2. **CH582 ROM ISP (USB product `0x55e0`).** A
   [publicly shared Air75 V3 repair package](https://drive.google.com/file/d/1HOJY8UmUm4lnN-LK6wncuXxiYnZ8RUqW/view?usp=drivesdk),
   [described by its recipient as supplied by NuPhy support](https://www.reddit.com/r/NuPhy/comments/1mqnd9r/keyboard_died_after_firmware_update_failed_air75/),
   documents a physical route that does not depend on a working application:
   switch the keyboard off, remove the Caps Lock keycap, hold the small button
   beneath it, and switch from Off to Wired while USB is connected.

The shared repair archive has SHA-256
`41422e07eefe8bd22994c5dcd74a4aa846b971bd553aa2c966eb09b2dbda01ad`.
Its macOS script waits for USB product `0x55e0`, then invokes WCH's signed
`WCHISPTool_CMD` against a bundled factory image. The configuration names the
MCU as **CH582**, selects **PB22** as the boot pin, erases all code flash,
verifies the write, and resets afterward. The universal WCH executable is
signed by “Nanjing Qinheng Microelectronics Co., Ltd.” and has SHA-256
`92a34f31e8c6a2ab1546d245fa8403f5b2e91688ad37392456f99d2df035062e`.

This package is a recovery artifact, not the source for the candidate: its
factory image predates 1.0.16.6 and differs from the current official binary.
It should be retained offline and used only if the normal `0x0722` path is no
longer available. It materially improves recoverability because entering ROM
ISP uses a physical button sampled at power-on, not application code, and does
not require opening the keyboard case.

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

Those results support the patch method and are now corroborated by both the
official Air75 updater implementation and the first Air75 hardware trial above.
The corrected Air75 image has since proved both the renderer edits and the
restoration guard. Before any future flash, retain the exact stock image and
repair package, use the MacBook's direct USB-C connection that succeeded for
the official and experimental updates, and obtain explicit approval for that
specific flash.
