#!/usr/bin/env python3
"""gpif_rig.py - raw FX3<->FPGA GPIF measurement rig.

Loads a bitstream through the FX3 config vendor requests (same path UHD
uses), resets the GPIF, then performs raw UHD-format control transactions
(16-byte CHDR packets, SID 0x40) on the control endpoints EP4 OUT / EP8 IN.

Unlike uhd_usrp_probe, this reports raw bytes, per-transaction latency and
timeouts, so "the FPGA does not answer" can be told apart from "UHD threw".

Usage:
  python3 scripts/gpif_rig.py <image.bin> [--reads N] [--expect HEX32]
"""
import struct
import sys
import time

import usb.core
import usb.util

VID, PID = 0x2500, 0x0020
VIN, VOUT = 0xC0, 0x40
FPGA_CONFIG, FPGA_START, FPGA_DATA = 0x55, 0x02, 0x12
GET_STATUS, SET_FPGA_HASH, GPIF_RESET = 0x83, 0x1C, 0x72
NAMES = {0: "UNDEFINED", 1: "FPGA_READY", 2: "CONFIGURING", 3: "BUSY",
         4: "RUNNING", 5: "UNCONFIGURED", 6: "ERROR"}
CTRL_OUT_EP, CTRL_IN_EP = 0x04, 0x88
SID_LOCAL = 0x40
SR_READBACK = 32


def boost_hash(data):
    m = 0xFFFFFFFF
    h = 0
    for ch in data:
        h = (h ^ (ch + 0x9E3779B9 + ((h << 6) & m) + (h >> 2))) & m
    return h


def wait_for(dev, target, tries):
    for _ in range(tries):
        s = dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0]
        if s == target:
            return True
        time.sleep(0.005)
    return False


def load(dev, path):
    data = open(path, 'rb').read()
    h = boost_hash(data)
    print(f"image {path}: {len(data)} bytes, hash {h:08x}")
    dev.ctrl_transfer(VOUT, FPGA_CONFIG, 0, 0, b'\x00', 5000)
    if not wait_for(dev, 1, 500):
        sys.exit("FX3 never reached FPGA_READY")
    dev.ctrl_transfer(VOUT, FPGA_START, 0, 0, b'\x00', 5000)
    if not wait_for(dev, 2, 1000):
        sys.exit("FX3 never reached CONFIGURING")
    for i in range(0, len(data), 512):
        dev.ctrl_transfer(VOUT, FPGA_DATA, 0, 0, data[i:i + 512], 5000)
    if not wait_for(dev, 4, 2000):
        sys.exit("FX3 never reached RUNNING (config failed)")
    dev.ctrl_transfer(VOUT, SET_FPGA_HASH, 0, 0, struct.pack('<I', h), 5000)
    print("FPGA CONFIGURED, hash registered")


def pkt(addr, data=0, seq=1):
    hdr = 0x80010010 | ((seq & 0xF) << 0)  # context, 16 bytes, seq in low bits
    return struct.pack('<4I', hdr, 0, addr, data)


def txn(dev, addr, data=0, seq=1, timeout_ms=200):
    w = pkt(addr, data, seq)
    t0 = time.time()
    try:
        sent = dev.write(CTRL_OUT_EP, w, 1000)
    except usb.core.USBError as e:
        return None, 0.0, f"OUT error {e}"
    try:
        r = dev.read(CTRL_IN_EP, 64, timeout_ms)
    except usb.core.USBError as e:
        return None, (time.time() - t0) * 1e3, f"IN timeout/err {e.errno}"
    dt = (time.time() - t0) * 1e3
    return bytes(r), dt, None


def main():
    path = sys.argv[1]
    reads = int(sys.argv[sys.argv.index('--reads') + 1]) if '--reads' in sys.argv else 3
    expect = sys.argv[sys.argv.index('--expect') + 1] if '--expect' in sys.argv else None
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("no device")
    dev.set_configuration()
    for itf in (3, 4):
        try:
            usb.util.claim_interface(dev, itf)
        except usb.core.USBError:
            pass
    load(dev, path)
    dev.ctrl_transfer(VOUT, GPIF_RESET, 0, 0, b'\x00', 5000)
    time.sleep(0.05)
    ok = 0
    for i in range(reads):
        r, dt, err = txn(dev, SR_READBACK, 0, seq=1)
        if r is None:
            print(f"read {i}: FAIL {err} after {dt:.1f} ms")
        else:
            words = struct.unpack('<%dI' % (len(r) // 4), r)
            print(f"read {i}: {len(r)}B in {dt:.1f} ms: "
                  + ' '.join(f'{w:08x}' for w in words))
            if expect and any(f'{w:08x}' == expect.lower().replace('0x', '') for w in words):
                ok += 1
    if expect:
        print(f"matches {expect}: {ok}/{reads}")


if __name__ == '__main__':
    main()
