#!/usr/bin/env python3
"""Minimal FX3 config loader with NO extra reset (use on a freshly
re-enumerated device, state UNCONFIGURED)."""
import struct, sys, time
import usb.core

VID, PID = 0x2500, 0x0020
VIN, VOUT = 0xC0, 0x40
FPGA_CONFIG, FPGA_START, FPGA_DATA = 0x55, 0x02, 0x12
GET_STATUS, SET_FPGA_HASH = 0x83, 0x1C
NAMES = {0: "UNDEFINED", 1: "FPGA_READY", 2: "CONFIGURING", 3: "BUSY",
         4: "RUNNING", 5: "UNCONFIGURED", 6: "ERROR"}


def boost_hash(data):
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
        time.sleep(0.005)
    return False, seen


def main():
    path = sys.argv[1]
    data = open(path, 'rb').read()
    h = boost_hash(data)
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit('no device')
    try:
        dev.set_configuration()
    except Exception:
        pass
    s = dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0]
    print(f'state before: {NAMES.get(s, s)}  ({len(data)} bytes, hash {h:08x})')

    dev.ctrl_transfer(VOUT, FPGA_CONFIG, 0, 0, b'\x00', 5000)
    ok, seen = wait_for(dev, 1, 500)
    print('ready:', ok, seen)
    if not ok:
        sys.exit(1)
    dev.ctrl_transfer(VOUT, FPGA_START, 0, 0, b'\x00', 5000)
    ok, seen = wait_for(dev, 2, 1000)
    print('configuring:', ok, seen)
    if not ok:
        sys.exit(1)

    chunk = 512
    for i in range(0, len(data), chunk):
        dev.ctrl_transfer(VOUT, FPGA_DATA, 0, 0, data[i:i + chunk], 5000)

    ok, seen = wait_for(dev, 4, 2000)
    s = dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0]
    print(f'after data: {NAMES.get(s, s)} {seen} -> done={ok}')
    if not ok:
        sys.exit(1)
    dev.ctrl_transfer(VOUT, SET_FPGA_HASH, 0, 0,
                      struct.pack('<I', h), 5000)
    print('CONFIGURED, hash registered')


if __name__ == '__main__':
    main()
