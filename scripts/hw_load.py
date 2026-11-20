#!/usr/bin/env python3
"""hw_load.py - load this project's Kintex bitstream onto the B210-class
board directly, over the FX3's vendor-request protocol (pyusb).

Why this exists: UHD's loader always offers its STOCK b210 image, which is
a Spartan-6 bitstream.  On this Kintex-7 board it never asserts DONE, so
UHD reports "fx3 is in state 5" (FX3_STATE_UNCONFIGURED) and reconfigures
away any image we loaded ourselves.  This script speaks the same protocol
UHD does, but with OUR image, and registers the image hash so that UHD
(with the fpga= hint) skips reconfiguration.

Protocol (from UHD b200_iface.cpp):
    0x55 FPGA_CONFIG  -> FX3 waits for READY(1)
    0x02 FPGA_START   -> FX3 enters CONFIGURING(2)
    0x12 FPGA_DATA    <- 512-byte chunks of the bitstream
    poll status 0x83  -> RUNNING(4) when the FPGA asserts DONE
    0x1C SET_FPGA_HASH<- 32-bit boost hash_combine over the file bytes

After it, run:
    uhd_usrp_probe --args="type=b200,serial=<sn>,fpga=<this bitstream>"

Usage: python3 scripts/hw_load.py [bitstream] [serial]
"""
import struct
import sys
import time

import usb.core

VID, PID = 0x2500, 0x0020
VIN, VOUT = 0xC0, 0x40
FPGA_CONFIG, FPGA_START, FPGA_DATA = 0x55, 0x02, 0x12
GET_STATUS, SET_FPGA_HASH = 0x83, 0x1C
NAMES = {0: "UNDEFINED", 1: "FPGA_READY", 2: "CONFIGURING", 3: "BUSY",
         4: "RUNNING", 5: "UNCONFIGURED", 6: "ERROR"}


def boost_hash(data):
    """uint32 hash_combine over bytes, exactly as UHD's generate_hash."""
    m = 0xFFFFFFFF
    h = 0
    for ch in data:
        h = (h ^ (ch + 0x9E3779B9 + ((h << 6) & m) + (h >> 2))) & m
    return h


def wait_for(dev, target, tries):
    seen = {}
    for _ in range(tries):
        s = dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0]
        seen[NAMES.get(s, s)] = seen.get(NAMES.get(s, s), 0) + 1
        if s == target:
            return True, seen
        time.sleep(0.002)
    return False, seen


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "build/deploy/usrp_b210_fpga.bin"
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("no USRP B210-class device on USB")
    try:
        dev.detach_kernel_driver(0)
    except Exception:
        pass

    data = open(path, "rb").read()
    h = boost_hash(data)
    print(f"[hw_load] {path}: {len(data)} bytes, hash {h:08x}")
    s = dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0]
    print(f"[hw_load] FX3 state before: {NAMES.get(s, s)}")

    dev.ctrl_transfer(VOUT, FPGA_CONFIG, 0, 0, b"\x00", 5000)
    ok, seen = wait_for(dev, 1, 500)
    if not ok:
        sys.exit(f"[hw_load] FAIL: no FPGA_READY after CONFIG ({seen})")
    dev.ctrl_transfer(VOUT, FPGA_START, 0, 0, b"\x00", 5000)
    ok, seen = wait_for(dev, 2, 1000)
    if not ok:
        sys.exit(f"[hw_load] FAIL: did not enter CONFIGURING ({seen})")

    chunk = 512
    for i in range(0, len(data), chunk):
        dev.ctrl_transfer(VOUT, FPGA_DATA, 0, 0, data[i:i + chunk], 5000)

    ok, seen = wait_for(dev, 4, 2000)  # RUNNING == FPGA asserted DONE
    print(f"[hw_load] after data: {NAMES.get(dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0], '?')} ({seen})")
    if not ok:
        sys.exit("[hw_load] FAIL: FPGA never reached RUNNING (no DONE?)")
    dev.ctrl_transfer(VOUT, SET_FPGA_HASH, 0, 0, struct.pack("<I", h), 5000)
    print("[hw_load] FPGA CONFIGURED, hash registered")
    print("[hw_load] now: uhd_usrp_probe --args=\"type=b200,serial=<sn>,fpga=" + path + "\"")


if __name__ == "__main__":
    main()
