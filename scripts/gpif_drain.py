#!/usr/bin/env python3
"""gpif_drain.py - measure whether the FPGA drains the FX3 OUT FIFO.

Writes a large stream to the control OUT endpoint in 512-byte frames with a
short per-transfer timeout and reports how many bytes were accepted before
the FX3 buffer filled.  A live GPIF master keeps draining; a dead one stalls
after the FX3's internal socket buffer.

Usage: gpif_drain.py <image.bin> [--mb 4]
"""
import struct
import sys
import time

import usb.core
import usb.util

sys.path.insert(0, 'scripts')
from gpif_rig import load, CTRL_OUT_EP, GPIF_RESET, VOUT  # noqa: E402


def main():
    img = sys.argv[1]
    mb = float(sys.argv[sys.argv.index('--mb') + 1]) if '--mb' in sys.argv else 4.0
    dev = usb.core.find(idVendor=0x2500, idProduct=0x0020)
    if dev is None:
        sys.exit('no device')
    dev.set_configuration()
    for itf in (3, 4):
        try:
            usb.util.claim_interface(dev, itf)
        except usb.core.USBError:
            pass
    load(dev, img)
    dev.ctrl_transfer(VOUT, GPIF_RESET, 0, 0, b'\x00', 5000)
    time.sleep(0.05)

    frame = struct.pack('<4I', 0x80010010, 0, 32, 0) + b'\x00' * (512 - 16)
    total = int(mb * 1024 * 1024)
    sent = 0
    t0 = time.time()
    stalls = 0
    while sent < total:
        try:
            n = dev.write(CTRL_OUT_EP, frame, 200)
            sent += n
        except usb.core.USBError as e:
            stalls += 1
            if stalls >= 3:
                break
    dt = time.time() - t0
    print(f"{img}: drained {sent} bytes in {dt:.2f}s "
          f"({sent/dt/1e6:.1f} MB/s), stalls={stalls}, "
          f"requested={total}, complete={sent >= total}")


if __name__ == '__main__':
    main()
