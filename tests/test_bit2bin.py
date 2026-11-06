#!/usr/bin/env python3
"""Unit test for scripts/bit2bin.py using a synthetic .bit file."""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "bit2bin.py"
MAGIC = bytes.fromhex("00090ff00ff00ff00ff0000001")


def tlv(tag: bytes, value: bytes) -> bytes:
    return tag + struct.pack(">H", len(value)) + value


def make_bit(payload: bytes) -> bytes:
    return (
        MAGIC
        + tlv(b"a", b"b200\x00")
        + tlv(b"b", b"xc7k325tffg676-1\x00")
        + tlv(b"c", b"2026/11/06\x00")
        + tlv(b"d", b"00:00:00\x00")
        + b"e"
        + struct.pack(">I", len(payload))
        + payload
    )


def main() -> int:
    payload = (
        b"\xff" * 0x20
        + struct.pack(">I", 0x000000BB)
        + struct.pack(">I", 0x11220044)
        + b"\xff" * 8
        + bytes.fromhex("aa995566")
        + b"\x00" * 16
    )
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        bit = tmpdir / "test.bit"
        out = tmpdir / "test.bin"
        bit.write_bytes(make_bit(payload))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(bit), str(out)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"FAIL: bit2bin returned {result.returncode}")
            print(result.stdout)
            print(result.stderr)
            return 1
        if out.read_bytes() != payload:
            print("FAIL: extracted payload does not match")
            return 1

        bad = tmpdir / "bad.bit"
        bad.write_bytes(b"not a bit file")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(bad), str(tmpdir / "bad.bin")],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print("FAIL: bad magic was accepted")
            return 1

    print("PASS: bit2bin round trip and bad-magic rejection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
