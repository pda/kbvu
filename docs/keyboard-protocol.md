# Air75 V3 keyboard protocol research

Research date: 2026-08-19. The details below apply only to the NuPhy Air75 V3
ANSI keyboard identified as USB `19f5:1028`. Similar NuPhy models use different
product IDs, LED counts, layouts, or protocols.

## Local USB evidence

macOS I/O Registry reports four HID interfaces on the connected keyboard. The
configuration interface is interface 3 and has:

- primary usage page `0x01`, usage `0x00`;
- report ID `0`;
- 64-byte input and output reports; and
- descriptor `0601000900a1010902150026ff009540750881020902150026ff00954075089102c0`.

The other interfaces are ordinary keyboard and pointing/media interfaces and
must not be used for vendor commands. Matching the exact VID, PID, usage, and
report sizes avoids writing to one of those interfaces or another keyboard.

## Official NuPhyIO evidence

[NuPhyIO](https://drive.nuphy.io/) is NuPhy's official Chromium/WebHID
configurator. The application fetched during this research used
`/static/js/main.f6f60294.js` (SHA-256
`3e90833c5db2cc1cbe8e0243ec32b0528c1d2d62cef17dabb358bc728b27695b`).
It is minified proprietary code, but inspection establishes several useful
facts:

- its WebHID filter identifies Air75 V3 ANSI as vendor `6645` (`0x19f5`),
  product `4136` (`0x1028`), usage page `1`, usage `0`;
- it pads commands to 64 bytes and calls `sendReport(0, report)`;
- its Air75 V3 model data says `keyLight: 84`, `sideLight: 20`, and places the
  side-light colors in the final 20 entries; and
- it defines five side-light modes: flowing, neon, static, breathing, and
  rhythm; and
- its S4 Air75 V3 driver implements `D2`, `D5`, and `D6`, but does not override
  the base API's unsupported `setCustomLight` operation. The per-light custom
  editor used by older protocol families is therefore unavailable on this
  keyboard.

This confirms that the two physical ten-LED bars are represented as 20 LEDs in
the configurator's lighting model. NuPhy does not publish a protocol
specification or host-side real-time LED API.

## Open-source references

### `kelchm/nuphy-tools`

[`kelchm/nuphy-tools`](https://github.com/kelchm/nuphy-tools), inspected at
commit [`03140bc`](https://github.com/kelchm/nuphy-tools/tree/03140bc1534001599bfcd0a0ef61706bd34d377d),
documents and implements the keymap protocol for mechanical S4-family V3
keyboards. Only the Air65 V3 was hardware-verified there, so its Air75 V3
support is a family-level inference rather than Air75 lighting evidence.

Useful corroboration:

- [`PROTOCOL.md`](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/PROTOCOL.md#L8-L43)
  documents the same usage `1:0`, 64-byte reports, checksum, XOR session key,
  payload length, address, and handle fields used by this project;
- its [geometry section](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/PROTOCOL.md#L45-L75)
  records the Air75 V3 as a 6×16 matrix with two extra slots and a 196-byte
  per-layer keymap stride;
- its [official S4 opcode table](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/PROTOCOL.md#L93-L105)
  includes `D1`, `D2`, `D5`, and `D6`, but no `D8`; and
- [`NuphyKB.command`](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/nuphyctl/protocol.py#L87-L126)
  is a compact independent implementation of the transport. Its
  [parameterized probe](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/nuphyctl/cli.py#L89-L101)
  can vary command, key, address, handle, and length.

This repository provides no `D8` implementation, side-light write command, or
side-light index map. It corroborates the transport but cannot establish either
the presence or absence of per-pixel bar control.

### `bohu8264/N-Agent-Bridge`

The most directly applicable reference is the MIT-licensed
[N Agent Bridge](https://github.com/bohu8264/N-Agent-Bridge), inspected at commit
[`fed40a2`](https://github.com/bohu8264/N-Agent-Bridge/tree/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd).
It targets the same Air75 V3 ANSI and says its protocol was hardware-verified on
official firmware `1.0.16.6`.

Relevant source:

- [protocol notes](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/docs/LIGHTING-PROTOCOL.md)
- [`NuPhyS4ProtocolCodec`](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeCore/HID/NuPhyS4ProtocolCodec.swift)
- [`Air75V3LightingController`](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeCore/Lighting/Air75V3LightingController.swift)

Its transport uses `IOHIDManager` and sends a 64-byte output report with report
ID zero:

```swift
IOHIDDeviceSetReport(
    device,
    kIOHIDReportTypeOutput,
    0,
    buffer,
    64
)
```

### S4 report format

Every logical transaction first establishes a fresh one-byte XOR session key.
This matters because NuPhyIO or a reconnect can replace the key held in the
keyboard's RAM.

| Byte | Request | Response |
| ---: | --- | --- |
| 0 | `0x55` | `0xaa` |
| 1 | command | echoed command |
| 2 | zero | zero |
| 3 | 8-bit sum of bytes 4–63 | same checksum rule |
| 4 | payload length | payload length |
| 5–6 | little-endian address | echoed address |
| 7 | handle | echoed handle |
| 8–63 | payload, at most 56 bytes | response payload |

Handshake command `0xee` carries 56 random payload bytes. Challenge byte 20
(report byte 28) is the session key; a zero value is replaced with `0xaa`.
After the handshake, request bytes 4–7 and payload bytes are XORed with that key
before the checksum is calculated. Firmware `1.0.16.6` returns routing bytes
4–7 in plain text but XORs the payload; older firmware can XOR both. Responses
must match the command, expected route, length, and checksum.

### Relevant lighting commands

| Command | Meaning | Data |
| ---: | --- | --- |
| `0xa1` | get firmware information | read-only identification |
| `0xd1` | get LED count | read-only |
| `0xd2` | get LED colors | RGB bytes at address `index * 3` |
| `0xd5` | get lighting state | 17 bytes for handle 0 or 1 |
| `0xd6` | set lighting state | complete 17-byte state |
| `0xd8` | set direct LED colors | repeated `[index, red, green, blue]` |

`D5`/`D6` expose the side bars as one effects zone. In the 17-byte state,
offsets 9–16 are side-light mode, raw brightness, speed, RGB/index selection,
and RGB color. This is useful for safe whole-zone tests but cannot represent
different left and right levels.

`D8` accepts at most 14 indexed colors per transaction. N Agent Bridge verifies
the write by reading the same colors through `D2` and restores the old values
on mismatch. Its authors hardware-tested `D8` for LED indices 0–6 (Escape and
F1–F6), with a changed-value test at F1 index 1, not the side LEDs. Its
[`D8` implementation](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeCore/Lighting/Air75V3LightingController.swift#L276-L367)
uses address 0 and handle 0.

NuPhyIO's `84 + 20` model and hardware `D2` reads confirm that side LEDs occupy
indices `84…103` in the rendered RGB table. N Agent Bridge's public key map
ends at index 83 and treats the side bars only as `D6` fields 9–16
([key map](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeCore/Lighting/SignalLightLayout.swift#L25-L70),
[side modes](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeCore/Lighting/Air75V3LightingController.swift#L128-L140)).
Later static analysis below proves that `D8` does store side entries, but the
renderer deliberately excludes them.

N Agent Bridge also defines backlight mode 21 (`0x15`) as
`signalIndicator`. Its first-time setup calls
[`setBacklight(mode: .signalIndicator)`](https://github.com/bohu8264/N-Agent-Bridge/blob/fed40a2fe72d5ff226fc0ac0d3e0e6800b29d2fd/Sources/Air75AgentBridgeApp/BridgeStore.swift#L464-L518)
before normal status-light synchronization. The `D8` method itself does not
select that mode, so a standalone caller cannot assume ordinary effects render
the direct-color buffer. The project targets firmware `1.0.16.6`, but its A1
method only formats bytes as hexadecimal; it does not establish a general A1
version-decoding rule.

### `gig3m/nuphykit`

[`gig3m/nuphykit`](https://github.com/gig3m/nuphykit), inspected at commit
[`66626a6`](https://github.com/gig3m/nuphykit/tree/66626a60c809be49805fadfe75e62db08182ffb7),
targets the [**Air100 V3 US** (`19f5:102d`) on firmware `1.0.6.6`](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/README.md#L1-L10),
not the Air75 V3. Its model-specific LED count and index map must not be copied
to this keyboard. It nevertheless supplies the strongest lead for the hidden
S4 custom-color path because it recovered and hardware-tested `D8` on a closely
related stock V3 firmware.

Its [`lighting.py`](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/nuphykit/lighting.py#L95-L126)
implements the discovered sequence:

```python
st[EFFECT] = 21
st[COLOUR_MODE] = 0
set(dev, bytes(st))

data += [idx, red, green, blue]
dev.send(0xD8, [len(data), 0, 0, 0] + data)
```

The Air100 evidence is unusually strong:

- firmware-dispatcher analysis found hidden command `D8`, absent from
  NuPhyIO's enum, and identified repeated `(index, R, G, B)` records
  ([protocol dispatcher analysis](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L2495-L2538));
- effects 1–20 ignored the custom table, while every tested effect from 21
  upward rendered it through independent `D2` readback
  ([hardware result and recipe](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L2626-L2653));
- the author visually verified WASD red on an otherwise black keyboard and
  confirmed that the table is RAM-only; and
- `D1` and `D2` were used to discover that model's 119-LED rendered table
  rather than assuming a count.

The Air100's tail LED/side-light mapping remained inferred rather than
individually verified, so even that project does not provide a transferable bar
index map. It also established custom-firmware feasibility for the Air100 by
analyzing its unencrypted CH58x firmware and bootloader. Its static-analysis
method transferred to the Air75 binary; its model-specific offsets, LED count,
and flashing assumptions do not.

## Internal addressability versus USB control

The Air75's built-in rhythm effect visibly lights different lengths of each bar,
so the firmware's internal renderer and LED driver clearly address those pixels
individually. That fact does not by itself identify a host command: an effect can
compute and render pixels entirely inside the keyboard while USB exposes only
mode, speed, brightness, and palette controls.

Conversely, absence from NuPhyIO's UI or command enum does not prove absence
from firmware. The Air100's working `D8` command was hidden from the same enum.
The firmware and hardware evidence now settle the distinction: the host can
supply all 104 custom RGB entries, but the stock custom renderer consumes only
the first 84. The side pixels remain individually addressable inside the
firmware while the exposed `D6` contract controls them as one zone.

No inspected Air75 source, NuPhyIO traffic, open-source implementation, or
firmware dispatch path shows a second side-frame command. Known working `D8`
implementations use address 0 and handle 0; handle 1 is a Windows lighting
profile rather than a side selector. On the Air100, `D7` is an asynchronous
`LightStateChange` report and `D8` is the hidden setter, so blindly probing
opcode gaps is neither justified nor safe.

## Air75 V3 hardware results

### First direct-color test: inconclusive

The first Zig probe run against the connected Air75 V3 on 2026-08-19 did this:

1. `D5` reported side mode 4 (rhythm) and raw brightness 60.
2. Reversible `D6` writes selected static mode 2 and red, green, blue, then dim
   white. Every acknowledgement and delayed `D5` readback matched exactly.
3. In static dim-white mode, `D2` reported all 20 side indices as `#131313`.
   This confirms both that `84…103` are the bars and that `D6` controls all 20
   as one zone (brightness accounts for the requested `#202020` being rendered
   as `#131313`).
4. `D8` was then sent in two packets for red indices `84…93` and blue indices
   `94…103`. The firmware echoed both payloads, but delayed `D2` readback did
   not contain the requested colors. Strict verification rejected the write.
5. The requested `D8` pattern was held for five seconds before verification.
   Manual observation confirmed that both bars remained dim white rather than
   splitting red and blue.
6. The pre-test colors and complete original `D6` state were restored, and a
   read-only probe confirmed the original rhythm mode and brightness.

An ACK is not evidence of mutation, but this test also is not evidence that the
write was discarded. `D2` reports the **rendered** frame, and the Air100 evidence
shows that ordinary effects can ignore a successfully written custom table. The
manual result—both bars remaining dim white—is exactly what would happen if
effect 6 continued rendering instead of hidden custom effect 21. The earlier
conclusion that stock Air75 firmware lacked side-pixel control was therefore
withdrawn.

### Read-only count and effect-21 follow-up

A later run added `D1` and the mode gate learned from `nuphykit`:

1. `D1` returned **104**, exactly matching NuPhyIO's 84 key lights plus 20 side
   lights. This is independent device evidence for one 104-entry rendered RGB
   table.
2. The supported whole-zone `D6` colors again passed exact readback.
3. The program then changed only the candidate custom-renderer fields—backlight
   effect byte 0 to 21 and color-mode byte 4 to fixed—while retaining a complete
   valid 17-byte state.
4. That candidate state did not survive exact delayed `D5` readback. The program
   stopped **before sending any `D8` command**, restored the original complete
   lighting state, and reported no restoration warning.

At that point, neither the known key-light `D8` control check nor a mode-21 side
write had run on this keyboard. The remaining uncertainty was firmware version
support, another Air75-specific state requirement, or a different render-mode
mechanism.

The A1 response is intentionally recorded as raw hexadecimal rather than called
a semantic version. Its first six bytes were stable (`0e 00 01 aa 06 00`), while
the final two varied with the session (`d3 d3`, later `e9 e9`), so interpreting
the eight requested bytes directly as a version would be unjustified. NuPhyIO's
displayed firmware version is the authoritative value.

### Firmware 1.0.16.6 retest

The keyboard was upgraded through NuPhyIO to official firmware **1.0.16.6** and
connected directly to the MacBook Pro by USB-C rather than through the previous
hub and Studio Display. Direct attachment was required for the update; it may
affect updater reliability, but the successful HID transactions do not show
that it changes the lighting protocol.

With NuPhyIO closed, the guarded full demo then established:

1. `A1` returned `10 00 01 aa 06 00 2f 2f`; only the first byte's change from
   `0e` to `10` is treated as update evidence, not a general version decoder.
2. `D1` again returned 104 and `D5` reported backlight mode 6, side mode 4, and
   side brightness 60.
3. Supported shared-bar red, green, blue, and dim-white `D6` states all passed
   exact delayed `D5` verification.
4. Hidden backlight effect 21 now passed exact `D5` verification.
5. `D8` changed key-light index 1 to magenta, passed exact `D2` verification,
   and restored its prior color. This verifies the handshake, encryption,
   routing, command encoding, hidden mode gate, and readback implementation.
6. Under effect 21, `D8` packets requested red at indices `84…93` and blue at
   `94…103`. Both full payloads were echoed, but delayed `D2` readback remained
   at the dim-white baseline (`#131313`). Strict verification rejected the
   pattern.
7. The side custom-color entries and complete original lighting state were
   overwritten with their baselines and restored without warnings.

This isolates the failure to Air75 side rendering rather than a malformed USB
transaction. The direct connection also rules out the previous hub as the
cause of the side-write failure.

## Lighting baseline recovery and factory reset

The earliest durable record of the keyboard's pre-`kbvu` lighting configuration
contains only the fields printed by the probe: backlight mode 6, side mode 4,
and side brightness 60. Neither the repository nor its commit history contains
a complete 17-byte `D5` response captured before `kbvu` first ran.

After an interrupted run and USB reconnect, the complete state was read as:

```text
15 32 01 00 00 00 00 05 80 04 3c 02 00 00 00 ff ae
```

The old process had selected backlight effect 21 and fixed-colour mode. A first
one-off repair changed only byte 0 back to the recorded effect 6. That state
looked unlike the user's previous effect. N Agent Bridge's field mapping then
identified byte 4 as the backlight `isRGB` flag, so a second repair changed it
from 0 to 1. Exact `D5` readback produced the current reconstructed state:

```text
06 32 01 00 01 00 00 05 80 04 3c 02 00 00 00 ff ae
```

This reconstruction is not a previously captured factory-state record. It is
based on the three fields `kbvu` deliberately replaces—bytes 0, 4, and 9—plus
the user's visual comparison. All other bytes were preserved. In particular,
the backlight speed byte remains 1 and the side-light speed byte remains 2, so
neither the app nor either repair increased the stored speed. Writing `D6` can
restart an effect's phase, and changing fixed-colour/RGB behavior can change its
appearance, which may account for a perceived speed difference.

NuPhyIO's Reset warning says, “Returns the keyboard to the factory setting, all
your changes will be lost, please proceed with caution.” Inspection of the same
hash-locked NuPhyIO bundle cited above shows that its S4 reset path sends
`RestoreFactory`; the
[`nuphy-tools` S4 opcode table](https://github.com/kelchm/nuphy-tools/blob/03140bc1534001599bfcd0a0ef61706bd34d377d/PROTOCOL.md#L93-L105)
identifies this as application command `0xf1`, separately from `0xef` firmware
update/IAP mode. NuPhyIO's firmware update follows the latter path, re-enumerates
the keyboard as updater `19f5:0722`, then transfers and verifies a complete
284,112-byte image. Reset does none of those things and therefore does **not**
replace the application image or remove the four-byte `kbvu` firmware patch.

The exact Air75 V3 configuration scope of `F1` has not been destructively
measured here. Closely related Air100 V3 hardware research reports that it resets
all five configuration spaces—keymaps/macros, keyboard functions, sleep,
application-defined data, and lighting—while a firmware update preserves those
spaces
([configuration spaces](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/nuphykit/spaces.py#L1-L50),
[reset observations](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L1344-L1404),
[firmware-update preservation](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/PROTOCOL.md#L1965-L1969)).
That is strong S4-family evidence, not an Air75-specific guarantee. On the
Air75, the safe interpretation of NuPhyIO's warning is that all customized
keymaps, macros, lighting, sleep, and other configurator settings may be lost.
The [NuPhy shortcut guide](https://nuphy.dev/?en), which explicitly includes
Air75 V3, also documents holding `Fn` + `[` for three seconds to restore factory
settings. Use NuPhyIO's visible Reset action in preference to sending raw `F1`,
and only after accepting the configuration loss.

## Official firmware provenance and static analysis

NuPhyIO's public keyboard-list API identifies the exact target as Air75 V3 ANSI
business ID `1930212869851615233`, application PID `0x1028`, and bootloader PID
`0x0722`:

- [keyboard list API](https://drive.nuphy.io/prod-api/api/nuphyIo/keyBoardList)
- [latest application firmware API](https://drive.nuphy.io/prod-api/api/nuphyIo/getLastFirmwareVersionsByType?businessId=1930212869851615233&type=1)

On 2026-08-19, the latter returned official version `1.0.16.6`, firmware ID
`2079506883036012545`, and [this archive](https://cdn.nuphy.io/image/2026/07/21/35f97f78d9d84393a7dea646f77e8f11.zip).
The archive's SHA-256 is
`37697fcbe35d39cafc576e7c3b7042015dcc8e952805638655d8fae743de1a48`.
It contains `Air75v3_US_v1.0.16.6_20260721.bin`, 284,112 bytes, whose SHA-256
matches the API value:
`7fd339b0e22dff0843d6be7f8ac4a970c209b2362b49cc6babd60fcf3101642e`.
The API also returns `e2Prom: "N"`. The release note says, “We have updated the
execution logic of the lighting.”

The binary was inspected offline as RISC-V RV32 with compressed instructions,
using Capstone and the methodology in nuphykit's
[`fwtool.py`](https://github.com/gig3m/nuphykit/blob/66626a60c809be49805fadfe75e62db08182ffb7/firmware/fwtool.py).
All addresses below are raw binary file offsets, not runtime addresses.

The S4 parser at `0x14e02` checks request marker `0x55`, extracts the opcode,
handles `0xee`, verifies/decrypts the frame, normalizes command values by
subtracting `0x2f`, and dispatches through the self-relative table at `0x42c9c`.
That table resolves these handlers:

| Command | Handler file offset |
| ---: | ---: |
| `D1` | `0x155a0` |
| `D2` | `0x15326` |
| `D5` | `0x1552c` |
| `D6` | `0x1550e` |
| `D8` | `0x154be` |

The `D1` handler writes constant `0x68` (104). More importantly, the `D8`
handler at `0x154be` divides the payload into four-byte records, calculates
`index * 3`, and writes RGB into the custom buffer at `gp + 0x2ec`. Its index
guard compares against `0x68`, so side records `84…103` are stored. The ACK is
therefore not merely accepting and discarding those indices.

The only renderer that reads `gp + 0x2ec` begins at `0x0bba6`. It calculates a
21-LED chunk, then clamps both the chunk end and render loop to `0x54` (84):

```text
0x0bbaa  addi   a3, zero, 0x54       # maximum key-light count
...
0x0bbce  addi   s5, zero, 0x54       # clamp chunk end to 84
0x0bbdc  addi   a5, gp, 0x2ec        # D8 custom RGB buffer
...
0x0bc1e  bltu   a5, s5, ...          # render only indices < 84
```

Separately, the side renderer calls the low-level LED setter for the ranges
`84…93` and `94…103`. The side-mode cycling logic at `0x0e01c` wraps the mode
with `sltiu ..., 5`, confirming exactly modes 0–4; there is no mode 5/custom
branch. Numerous side effects render up to exclusive bound `0x68` while main
backlight effects use exclusive bound `0x54`.

This reconciles every observation:

- all 104 LEDs are individually addressable by firmware;
- `D8` stores host RGB for all 104 positions;
- effect 21 intentionally consumes only the first 84 values;
- the five-mode side renderer overwrites/owns positions 84–103; and
- `D2` reports the resulting rendered frame, so side `D8` writes remain
  invisible even though their RGB bytes exist in RAM.

The official 1.0.16.6 USB protocol therefore cannot display arbitrary host
values on the two bars. The smallest plausible firmware change is to extend
effect 21's custom-buffer renderer from 84 to 104 and ensure the ordinary side
renderer does not subsequently overwrite those pixels. That must be developed
and flashed as an exact-model experimental firmware with a verified recovery
path; it must not be inferred from Air100 offsets or flashed without explicit
approval. The exact official updater frames and Air75-specific physical recovery
procedure are recorded in [the firmware patch notes](firmware-patch.md).

## Other useful references

- [NuPhyIO landing page](https://www.nuphy.io/) lists Air75 V3 ANSI as a
  supported device and links the official configurator.
- [NuPhy's firmware page](https://nuphy.com/pages/firmware) directs Air75 V3
  firmware management to NuPhyIO; firmware changes must use the exact ANSI model
  selected by the official updater.
- [Air75 V3 product page](https://nuphy.com/products/nuphy-air75-v3-page)
  describes the rhythm RGB light bars and NuPhyIO support.
- [Air75 V3 Linux setup notes](https://asadjb.com/blog/2025-12-08-nuphy-air-75-v3-linux/)
  independently report the same `19f5:1028` identity.
- [nuphy-capslock-agent-beacon](https://github.com/justintylerm/nuphy-capslock-agent-beacon)
  exactly matches the Air75 V3 wired keyboard HID descriptor on macOS, but only
  controls the standard one-bit Caps Lock output. It is evidence for safe HID
  matching, not arbitrary RGB control.
- [NuphyBar](https://github.com/itsmaiGe/NuphyBar/tree/004d43c13986c434a15060279c1d253263d73e38),
  inspected at commit `004d43c`, demonstrates native macOS `IOHIDManager` use
  but [explicitly does not support Air V3](https://github.com/itsmaiGe/NuphyBar/blob/004d43c13986c434a15060279c1d253263d73e38/README.md#L61-L68).
  It patches official Air60 V2 firmware so ordinary host Num/Scroll Lock bits
  drive five right-side LEDs. Its two-byte host protocol and LED indices do not
  apply here, but its exact-binary patch and recovery discipline are relevant.
- [nuphy-rgb-music](https://github.com/ravila4/nuphy-rgb-music/tree/6e3086dffbbcb70daafb20d486e704be99bdf521),
  inspected at commit `6e3086d`, streams indexed side-light RGB over Raw HID,
  but only after flashing its custom QMK handler to an Air75 V2 (`19f5:3246`).
  Its [12-pixel side-frame protocol](https://github.com/ravila4/nuphy-rgb-music/blob/6e3086dffbbcb70daafb20d486e704be99bdf521/src/nuphy_rgb/hid_utils.py#L118-L141),
  firmware, MCU target, and LED count do not apply to the Air75 V3
  (`19f5:1028`). It nevertheless shows the needed host-frame architecture.
- [Nudelta](https://github.com/donn/nudelta) reverse-engineers older NuPhy
  Console keyboards but explicitly excludes Air75 V2/V3/HE because NuPhyIO uses
  a different protocol.

## Safety constraints for the test program

1. Match only wired `19f5:1028`, usage `1:0`, with 64-byte input/output reports.
2. Use only read commands plus `D6`/`D8`; never send factory reset (`0xf1`),
   firmware/IAP (`0xef`), keymap, macro, or calibration commands.
3. Close NuPhyIO before testing so two programs cannot replace the session key
   or consume each other's untagged responses. Even `--probe` performs required
   `EE` handshakes, which replace NuPhyIO's in-RAM session key, although it sends
   no lighting or persistent-configuration write.
4. Read and retain the original state before the first write.
5. Require a valid acknowledgement and exact readback; never blindly retry a
   write whose result is unknown.
6. Restore original key and side colors plus the complete lighting state on
   normal exit and after a verified mismatch.
7. Initially update slowly. A VU refresh-rate soak test is required before
   treating persistent RGB writes as safe for keyboard input or flash wear.
