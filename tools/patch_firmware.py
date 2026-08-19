#!/usr/bin/env python3
"""Build the exact Air75 V3 1.0.16.6 kbvu firmware candidate offline."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


STOCK_SIZE = 284_112
STOCK_SHA256 = "7fd339b0e22dff0843d6be7f8ac4a970c209b2362b49cc6babd60fcf3101642e"
PATCHED_SHA256 = "2d95a6a163b10ea1398e7603e9d4b59d1b115c192cae63a890e07310e1c4ac14"

# Raw binary file offsets. Each edit changes only an RV32 immediate; no code is
# inserted and instruction boundaries do not move.
PATCHES = (
    # Finish effect 21 after index 103 instead of index 83.
    (0x0B5E6, bytes.fromhex("13 07 30 05"), bytes.fromhex("13 07 70 06")),
    # Extend effect 21's overall limit and final-chunk clamp from 84 to 104.
    (0x0BBAA, bytes.fromhex("93 06 40 05"), bytes.fromhex("93 06 80 06")),
    (0x0BBCE, bytes.fromhex("93 0A 40 05"), bytes.fromhex("93 0A 80 06")),
    # Permit side mode 5. The existing side dispatcher has handlers only for
    # 0..4, so mode 5 leaves pixels 84..103 to effect 21.
    (0x14A3E, bytes.fromhex("91 47"), bytes.fromhex("95 47")),
)


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def build(source: Path, destination: Path) -> None:
    if source.resolve() == destination.resolve():
        raise SystemExit("refusing to overwrite the stock firmware")
    if destination.exists():
        raise SystemExit(f"refusing to overwrite existing output: {destination}")

    stock = source.read_bytes()
    digest = sha256(stock)
    if len(stock) != STOCK_SIZE or digest != STOCK_SHA256:
        raise SystemExit(
            "input is not the exact Air75 V3 ANSI 1.0.16.6 stock image\n"
            f"size: expected {STOCK_SIZE}, got {len(stock)}\n"
            f"sha256: expected {STOCK_SHA256}, got {digest}"
        )

    patched = bytearray(stock)
    for offset, expected, replacement in PATCHES:
        actual = bytes(patched[offset : offset + len(expected)])
        if actual != expected:
            raise SystemExit(
                f"unexpected bytes at 0x{offset:05x}: "
                f"expected {expected.hex()}, got {actual.hex()}"
            )
        patched[offset : offset + len(expected)] = replacement

    changed = [index for index, (before, after) in enumerate(zip(stock, patched)) if before != after]
    expected_changed = [
        offset + index
        for offset, before, after in PATCHES
        for index, (old, new) in enumerate(zip(before, after))
        if old != new
    ]
    if changed != expected_changed:
        raise SystemExit("internal error: output contains changes outside the patch manifest")

    patched_digest = sha256(patched)
    if patched_digest != PATCHED_SHA256:
        raise SystemExit(
            "internal error: patched image hash mismatch\n"
            f"expected {PATCHED_SHA256}, got {patched_digest}"
        )

    destination.write_bytes(patched)
    print(f"wrote {destination} ({len(patched)} bytes)")
    print(f"sha256 {patched_digest}")
    print(f"changed {len(changed)} bytes at " + ", ".join(f"0x{x:05x}" for x in changed))
    print("This image has not been flashed or hardware-tested.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock", type=Path, help="official Air75 V3 ANSI 1.0.16.6 .bin")
    parser.add_argument("output", type=Path, help="new path for the patched .bin")
    args = parser.parse_args()
    build(args.stock, args.output)


if __name__ == "__main__":
    main()
