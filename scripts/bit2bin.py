#!/usr/bin/env python3
"""Extract the raw configuration payload from a Xilinx .bit file.

The vendor ``write_bitstream -bin_file`` output and the B210 FX3 loader use
the raw payload, not the TLV header.  Project X-Ray's ``xc7frames2bit`` writes a
standard .bit file whose ``e`` field is exactly that payload (including the
7-series bus-width/sync preamble).  This script writes that field to a .bin
without changing a single byte.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

BIT_MAGIC = bytes.fromhex("00090ff00ff00ff00ff0000001")
SYNC_WORD = bytes.fromhex("aa995566")


def extract(bit_path: Path) -> tuple[bytes, dict[str, bytes]]:
    data = bit_path.read_bytes()
    if not data.startswith(BIT_MAGIC):
        raise SystemExit(f"{bit_path}: not a Xilinx .bit file (bad magic)")

    pos = len(BIT_MAGIC)
    fields: dict[str, bytes] = {}
    while pos < len(data):
        tag = data[pos : pos + 1]
        pos += 1
        if tag == b"e":
            if pos + 4 > len(data):
                raise SystemExit(f"{bit_path}: truncated 'e' length")
            (length,) = struct.unpack(">I", data[pos : pos + 4])
            pos += 4
            payload = data[pos : pos + length]
            if len(payload) != length:
                raise SystemExit(f"{bit_path}: truncated 'e' payload")
            fields["e"] = payload
            break
        if pos + 2 > len(data):
            raise SystemExit(f"{bit_path}: truncated TLV header")
        (length,) = struct.unpack(">H", data[pos : pos + 2])
        pos += 2
        value = data[pos : pos + length]
        if len(value) != length:
            raise SystemExit(f"{bit_path}: truncated TLV value")
        pos += length
        fields[tag.decode("ascii", "replace")] = value.rstrip(b"\x00")

    payload = fields.get("e")
    if payload is None:
        raise SystemExit(f"{bit_path}: no 'e' payload found")
    if len(payload) < 0x30 or payload[0x30:0x34] != SYNC_WORD:
        raise SystemExit(
            f"{bit_path}: payload does not contain the 7-series sync word "
            f"at offset 0x30"
        )
    return payload, fields


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} INPUT.bit OUTPUT.bin", file=sys.stderr)
        return 2
    bit_path = Path(argv[1])
    bin_path = Path(argv[2])
    payload, fields = extract(bit_path)
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.write_bytes(payload)

    digest = hashlib.sha256(payload).hexdigest()
    design = fields.get("a", b"?").decode("ascii", "replace")
    part = fields.get("b", b"?").decode("ascii", "replace")
    print(f"  design:   {design}")
    print(f"  part:     {part}")
    print(f"  bin size: {len(payload)} bytes")
    print(f"  bin sha256: {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
