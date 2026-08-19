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
  rhythm.

This confirms that the two physical ten-LED bars are represented as 20 LEDs in
the configurator's lighting model. NuPhy does not publish a protocol
specification or host-side real-time LED API.

## Open-source implementation

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
F1–F6), not the side LEDs.

Combining its indexed RGB behavior with NuPhyIO's `84 + 20` model strongly
suggests that side LEDs are indices `84…103`. This is a hypothesis, not yet a
verified fact. The test program should read those indices first, write a
reversible sweep in two `D8` packets, verify each write with `D2`, and restore
the original colors when it exits. The sweep will also reveal physical order
and whether the firmware permits direct writes while the side-light mode is
active.

## Other useful references

- [NuPhyIO landing page](https://www.nuphy.io/) lists Air75 V3 ANSI as a
  supported device and links the official configurator.
- [Air75 V3 product page](https://nuphy.com/products/nuphy-air75-v3-page)
  describes the rhythm RGB light bars and NuPhyIO support.
- [Air75 V3 Linux setup notes](https://asadjb.com/blog/2025-12-08-nuphy-air-75-v3-linux/)
  independently report the same `19f5:1028` identity.
- [nuphy-capslock-agent-beacon](https://github.com/justintylerm/nuphy-capslock-agent-beacon)
  exactly matches the Air75 V3 wired keyboard HID descriptor on macOS, but only
  controls the standard one-bit Caps Lock output. It is evidence for safe HID
  matching, not arbitrary RGB control.
- [NuphyBar](https://github.com/itsmaiGe/NuphyBar) demonstrates native macOS
  `IOHIDManager` use for a NuPhy keyboard, but explicitly does not support Air
  V3 and relies on custom Air60 V2 firmware. Its two-byte host LED protocol does
  not apply here.
- [Nudelta](https://github.com/donn/nudelta) reverse-engineers older NuPhy
  Console keyboards but explicitly excludes Air75 V2/V3/HE because NuPhyIO uses
  a different protocol.

## Safety constraints for the test program

1. Match only wired `19f5:1028`, usage `1:0`, with 64-byte input/output reports.
2. Use only read commands plus `D6`/`D8`; never send factory reset (`0xf1`),
   firmware/IAP (`0xef`), keymap, macro, or calibration commands.
3. Close NuPhyIO before testing so two programs cannot replace the session key
   or consume each other's untagged responses.
4. Read and retain the original state before the first write.
5. Require a valid acknowledgement and exact readback; never blindly retry a
   write whose result is unknown.
6. Restore original colors/state on normal exit and after a verified mismatch.
7. Initially update slowly. A VU refresh-rate soak test is required before
   treating persistent RGB writes as safe for keyboard input or flash wear.
