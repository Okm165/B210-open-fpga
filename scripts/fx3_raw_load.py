#!/usr/bin/env python3
"""fx3_raw_load.py - load and exercise an FPGA image with no UHD involved.

  fx3_raw_load.py <fpga.bin> [--regs] [--peek N] [--drain BYTES] [--echo N] [--fw usrp_b200_fw.hex]

1. reboot the FX3 into its USB bootloader (vendor request 0x99) and download
   the stock firmware, so every image starts from the same FX3 state;
2. configure the FPGA through the stock firmware's vendor requests;
3. --regs: the control path through every layer it has, printed as it is
   read: the USB link and the FX3's view of the FPGA; the FPGA's readback
   registers (signature, compatibility number, radio count, reference lock);
   a write and read-back of an FPGA setting register; and the AD9361's
   product ID, read through the FPGA's SPI master exactly as UHD reads it;
   --peek N: N control transactions on EP4 OUT / EP8 IN against the design's
   local register block; each must come back with its own sequence number and
   the 0xACE0BA5E signature (default 0: diagnostic designs have no registers);
4. --drain BYTES: write that much to the data endpoint EP2 OUT (default 8 MB).
   A design that clocks the FX3 and reads its FIFO takes all of it; a dead one
   stalls after the FX3's own 1024-byte buffer.  This shows that the bus
   moves; the bytes are zeros and nothing checks them;
5. --echo N (for src/top/diag_echo.v, which returns everything): N packets of
   random length and content on the data endpoints (EP2 OUT -> EP6 IN) and on
   the control endpoints (EP4 OUT -> EP8 IN), written and read at the same
   time; every packet must come back as it was sent.  Replaces the drain.

Exit status 0 only if every requested step succeeded.
"""
import argparse
import os
import random
import struct
import sys
import threading
import time

import usb.core
import usb.util

VID, PID = 0x2500, 0x0020
VIN, VOUT = 0xC0, 0x40
FX3_RESET, FX3_BOOT_WRITE = 0x99, 0xA0
FPGA_CONFIG, FPGA_START, FPGA_DATA = 0x55, 0x02, 0x12
GET_STATUS, SET_FPGA_HASH, GPIF_RESET = 0x83, 0x1C, 0x72
FPGA_READY, CONFIGURING, RUNNING = 1, 2, 4
DATA_OUT_EP, DATA_IN_EP, CTRL_OUT_EP, CTRL_IN_EP = 0x02, 0x86, 0x04, 0x88
SID_LOCAL = 0x40          # L0_CTRL_SID in b200_core.v
SR_READBACK = 32          # setting register that selects the readback word
SIGNATURE = 0xACE0BA5E    # upper half of readback word 0


def product(dev):
    try:
        return usb.util.get_string(dev, dev.iProduct) or ''
    except (usb.core.USBError, ValueError):
        return ''     # mid re-enumeration


def wait_device(is_wanted, seconds, what):
    deadline = time.time() + seconds
    while time.time() < deadline:
        dev = usb.core.find(idVendor=VID, idProduct=PID)
        if dev is not None and is_wanted(product(dev)):
            return dev
        time.sleep(0.25)
    sys.exit(f'FAIL: {what} did not appear within {seconds} s')


def in_bootloader(name):
    return 'West' in name or 'Cypress' in name


def reboot_to_bootloader():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit('FAIL: no B210 on USB')
    if not in_bootloader(product(dev)):
        dev.set_configuration()
        try:
            dev.ctrl_transfer(VOUT, FX3_RESET, 0, 0, b'\x00', 5000)
        except usb.core.USBError:
            pass      # the device drops off the bus while answering
    return wait_device(in_bootloader, 15, 'FX3 bootloader')


def load_firmware(boot, path):
    boot.set_configuration()
    upper = 0
    for line in open(path):
        if not line.startswith(':'):
            continue
        rec = bytes.fromhex(line.strip()[1:])
        count, addr, kind, data = rec[0], (rec[1] << 8) | rec[2], rec[3], rec[4:4 + rec[0]]
        if kind == 4:
            upper = int.from_bytes(data, 'big') << 16
        elif kind == 2:
            upper = int.from_bytes(data, 'big') << 4
        elif kind == 0:
            a = upper + addr
            boot.ctrl_transfer(VOUT, FX3_BOOT_WRITE, a & 0xFFFF, a >> 16, data, 5000)
        elif kind == 1:
            break
    try:
        boot.ctrl_transfer(VOUT, FX3_BOOT_WRITE, 0, 0, b'', 5000)   # jump
    except usb.core.USBError:
        pass          # the bootloader leaves the bus as it jumps
    return wait_device(lambda n: 'USRP' in n or 'B200' in n, 25, 'B200 firmware')


def wait_status(dev, wanted, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0] == wanted:
            return
        time.sleep(0.005)
    sys.exit(f'FAIL: FX3 never reported FPGA state {wanted}')


def load_fpga(dev, path):
    data = open(path, 'rb').read()
    dev.ctrl_transfer(VOUT, FPGA_CONFIG, 0, 0, b'\x00', 5000)
    wait_status(dev, FPGA_READY, 5)
    dev.ctrl_transfer(VOUT, FPGA_START, 0, 0, b'\x00', 5000)
    wait_status(dev, CONFIGURING, 10)
    for i in range(0, len(data), 512):
        dev.ctrl_transfer(VOUT, FPGA_DATA, 0, 0, data[i:i + 512], 5000)
    wait_status(dev, RUNNING, 20)     # DONE went high
    # No image hash is stored: UHD skips its own load when the hash matches,
    # and what follows a raw load should start from UHD loading the image.
    dev.ctrl_transfer(VOUT, SET_FPGA_HASH, 0, 0, struct.pack('<I', 0), 5000)
    dev.ctrl_transfer(VOUT, GPIF_RESET, 0, 0, b'\x00', 5000)
    time.sleep(0.05)
    print(f'loaded {path} ({len(data)} bytes)')


def control(dev, seq, addr, data):
    """One register write to the design's local block (SID 0x40); returns the
    64-bit readback word the answer carries, or None without an answer.
    The answer to a write of SR_READBACK carries the readback word selected."""
    header = 0x80000000 | ((seq & 0xFFF) << 16) | 16
    dev.write(CTRL_OUT_EP, struct.pack('<4I', header, SID_LOCAL, addr, data), 1000)
    try:
        raw = bytes(dev.read(CTRL_IN_EP, 512, 500))
    except usb.core.USBError:
        return None
    words = struct.unpack('<%dI' % (len(raw) // 4), raw[:len(raw) // 4 * 4])
    if len(words) != 6 or (words[0] >> 16) & 0xFFF != seq & 0xFFF:
        return None
    return (words[4] << 32) | words[5]


# The local registers of b200_core.v and UHD's b200_regs.hpp
SR_SPI_DIV, SR_SPI_CTRL, SR_SPI_DATA, SR_GPSDO_ST = 8, 9, 10, 40
RB_COMPAT, RB_SPI, RB_STATUS, RB_LOCK = 0, 1, 2, 3


def regs(dev):
    """Print the control surface layer by layer; True if every check held."""
    speed = {1: '1.5 Mb/s', 2: '12 Mb/s', 3: '480 Mb/s', 4: '5 Gb/s (USB 3)', 5: '10 Gb/s'}
    print(f'USB     link {speed.get(dev.speed, dev.speed)}, product "{product(dev)}", '
          f'FX3 reports the FPGA running: {dev.ctrl_transfer(VIN, GET_STATUS, 0, 0, 1)[0] == RUNNING}')
    seq = iter(range(1, 4096))
    rb = lambda k: control(dev, next(seq), SR_READBACK, k)
    ok = True
    compat = rb(RB_COMPAT)
    status = rb(RB_STATUS)
    lock = rb(RB_LOCK)
    if None in (compat, status, lock):
        print('FPGA    no answer on the control endpoint')
        return False
    signature_ok = compat >> 32 == SIGNATURE
    radios = (status >> 40) & 0xFF
    print(f'FPGA    signature {compat >> 32:08x} ({"right" if signature_ok else "WRONG"}), '
          f'compatibility {(compat >> 16) & 0xFFFF}.{compat & 0xFFFF}, {radios} radio(s), '
          f'reference PLL lock {status & 1}, AD9361 lock pins {lock & 3:02b}')
    ok &= signature_ok and radios == 2
    for value in (0xA5, 0x5A, 0x00):
        control(dev, next(seq), SR_GPSDO_ST, value)
        back = (rb(RB_STATUS) or 0) >> 32 & 0xFF
        ok &= back == value
        print(f'FPGA    setting register {SR_GPSDO_ST} <- {value:#04x}, reads back {back:#04x}')
    # AD9361 product ID (register 0x037, upper five bits 00001 for the AD9361),
    # read as UHD does: 1 MHz SPI, slave 0, 24 bits, data out on the falling edge
    control(dev, next(seq), SR_SPI_DIV, 49)
    control(dev, next(seq), SR_SPI_CTRL, 0x80000000 | (24 << 24) | 1)
    control(dev, next(seq), SR_SPI_DATA, (0x037 << 8) << 8)
    product_id = (rb(RB_SPI) or 0) & 0xFF
    id_ok = product_id & 0xF8 == 0x08
    ok &= id_ok
    print(f'AD9361  product ID {product_id:#04x} through the FPGA SPI master '
          f'({"an AD9361" if id_ok else "NOT an AD9361"})')
    return ok


def peek(dev, count):
    """count readback transactions; returns how many answered correctly."""
    try:
        while True:
            dev.read(CTRL_IN_EP, 512, 20)     # leftovers of an earlier session
    except usb.core.USBError:
        pass
    good, worst_ms = 0, 0.0
    for seq in range(count):
        # CHDR command: type 10, 12-bit sequence, length 16 bytes; then the
        # SID, the register address and its data.
        header = 0x80000000 | ((seq & 0xFFF) << 16) | 16
        t0 = time.time()
        dev.write(CTRL_OUT_EP, struct.pack('<4I', header, SID_LOCAL, SR_READBACK, 0), 1000)
        try:
            raw = bytes(dev.read(CTRL_IN_EP, 512, 500))
        except usb.core.USBError as e:
            print(f'  peek {seq}: no answer ({e.strerror or e})')
            continue
        worst_ms = max(worst_ms, (time.time() - t0) * 1e3)
        words = struct.unpack('<%dI' % (len(raw) // 4), raw[:len(raw) // 4 * 4])
        # response: header, SID, 64-bit time, 64-bit readback
        answered = (len(words) == 6 and (words[0] >> 16) & 0xFFF == seq & 0xFFF
                    and words[4] == SIGNATURE)
        if answered:
            good += 1
        else:
            print(f'  peek {seq}: unexpected ' + ' '.join(f'{w:08x}' for w in words))
    print(f'peek: {good}/{count} answered with their sequence number and '
          f'{SIGNATURE:08x} (slowest {worst_ms:.1f} ms)')
    return good


def drain(dev, total):
    frame, sent, stalls, t0 = bytes(512), 0, 0, time.time()
    while sent < total and stalls < 3:
        try:
            sent += dev.write(DATA_OUT_EP, frame, 200)
        except usb.core.USBTimeoutError:
            stalls += 1
    dt = time.time() - t0
    print(f'drain: {sent}/{total} B in {dt:.2f} s ({sent / dt / 1e6:.2f} MB/s)')
    return sent


def echo(dev, count, out_ep, in_ep, max_bytes, label):
    """count packets out, the same bytes expected back; returns True on a match."""
    rng = random.Random(count)
    packets = []
    for seq in range(count):
        # a whole number of 64-bit lines; the first word is a CHDR header,
        # of which the bus logic reads the sequence number and the length
        words = 2 * rng.randrange(1, max_bytes // 8 + 1)
        packets.append(struct.pack('<%dI' % words, ((seq & 0xFFF) << 16) | (words * 4),
                                   *[rng.getrandbits(32) for _ in range(words - 1)]))
    sent = b''.join(packets)
    got = bytearray()

    def reader():
        quiet = 0
        while quiet < 3:
            try:
                got.extend(dev.read(in_ep, 65536, 500))
                quiet = 0
            except usb.core.USBError:
                quiet += 1

    thread = threading.Thread(target=reader)
    t0 = time.time()
    thread.start()
    written = 0
    try:
        for p in packets:
            written += dev.write(out_ep, p, 2000)
    except usb.core.USBError as e:
        print(f'  {label}: write stopped after {written} B ({e.strerror or e})')
    thread.join()
    dt = time.time() - t0
    got = bytes(got)
    # Walk the returned stream packet by packet.  The bus logic follows a
    # packet whose length is a whole number of USB packets (1024 B) by one
    # extra word, so that it cannot get stuck in the FX3; its value is not
    # defined and it is not part of the packet.
    at = pads = 0
    for seq, p in enumerate(packets):
        back = got[at:at + len(p)]
        if back != p:
            word = next((i for i in range(0, len(p), 4) if back[i:i + 4] != p[i:i + 4]), 0)
            print(f'echo {label}: FAIL - packet {seq} of {count} ({len(p)} B) differs at word {word // 4}: '
                  f'sent {p[word:word + 4][::-1].hex()}, got {back[word:word + 4][::-1].hex() or "nothing"}; '
                  f'{len(got)} B came back for {len(sent)} sent')
            return False
        at += len(p)
        if len(p) % 1024 == 0:
            at += 4
            pads += 1
    if at != len(got):
        print(f'echo {label}: FAIL - {len(got) - at} B more than the {count} packets came back')
        return False
    print(f'echo {label}: {count} packets, {len(sent)} B returned intact in {dt:.2f} s'
          + (f' ({pads} of them padded by the bus logic)' if pads else ''))
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('fpga')
    ap.add_argument('--fw', default=os.path.join(os.environ.get('UHD_IMAGES_DIR', os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.tools', 'uhd315', 'images')),
        'usrp_b200_fw.hex'))
    ap.add_argument('--regs', action='store_true')
    ap.add_argument('--peek', type=int, default=0)
    ap.add_argument('--drain', type=int, default=None, help='default 8 MB, or none with --echo')
    ap.add_argument('--echo', type=int, default=0)
    a = ap.parse_args()

    dev = load_firmware(reboot_to_bootloader(), a.fw)
    dev.set_configuration()
    for interface in (1, 2, 3, 4):
        if dev.is_kernel_driver_active(interface):
            dev.detach_kernel_driver(interface)
        usb.util.claim_interface(dev, interface)
    load_fpga(dev, a.fpga)
    ok = True
    if a.regs:
        ok &= regs(dev)
    if a.peek:
        ok &= peek(dev, a.peek) == a.peek
    if a.echo:
        ok &= echo(dev, a.echo, DATA_OUT_EP, DATA_IN_EP, 8000, 'data')
        ok &= echo(dev, min(a.echo, 512), CTRL_OUT_EP, CTRL_IN_EP, 64, 'control')
    if a.drain is None:
        a.drain = 0 if a.echo else 8 * 1024 * 1024
    if a.drain:
        ok &= drain(dev, a.drain) >= a.drain
    print('RESULT: ' + ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
