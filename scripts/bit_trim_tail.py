#!/usr/bin/env python3
"""bit_trim_tail.py - drop trailing all-zero frames from a 7-series .bin.

The image is a single FDRI burst starting at FAR 0, so frames that are all
zero at the end of the payload can simply be omitted: configuration memory
is zero after PROGRAM_B.  Only the FDRI length and epilogue position change,
no FAR arithmetic is needed.

Usage: bit_trim_tail.py <in.bin> <out.bin>
"""
import struct
import sys

FRAME_WORDS = 101
REGS = {1: 'FAR', 2: 'FDRI', 4: 'CMD', 5: 'CTL0', 6: 'MASK'}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = open(src, 'rb').read()
    w = list(struct.unpack('>%dI' % (len(d) // 4), d[:len(d) // 4 * 4]))

    def t1_ok(i):
        return (w[i] >> 29) == 1 and ((w[i] >> 27) & 3) == 2

    # find the FDRI type-1 header (reg 2) that starts the payload
    fdri = None
    i = 0
    while i < len(w):
        h = w[i]
        t = h >> 29
        if t == 1 and ((h >> 27) & 3) == 2:
            reg = (h >> 13) & 0x3FFF
            cnt = h & 0x7FF
            if reg == 2:
                fdri = i
                break
            i += 1 + cnt
            continue
        i += 1
    if fdri is None:
        raise SystemExit('no FDRI')

    head = w[:fdri]
    first_cnt = w[fdri] & 0x7FF
    payload = list(w[fdri + 1:fdri + 1 + first_cnt])
    i = fdri + 1 + first_cnt
    while i < len(w) and (w[i] >> 29) == 2:
        c = w[i] & 0x7FFFFFF
        payload += list(w[i + 1:i + 1 + c])
        i += 1 + c
    epilogue = w[i:]

    if len(payload) % FRAME_WORDS:
        raise SystemExit('payload not frame aligned')
    n = len(payload) // FRAME_WORDS
    last = max((k for k in range(n) if any(payload[k * FRAME_WORDS:(k + 1) * FRAME_WORDS])),
               default=0)
    keep = payload[:(last + 1) * FRAME_WORDS]

    out = list(head)
    first = min(len(keep), 0x7FF)
    out.append((1 << 29) | (2 << 27) | (2 << 13) | first)
    out.extend(keep[:first])
    rest = keep[first:]
    while rest:
        chunk = min(len(rest), 0x7FFFFFF)
        out.append((2 << 29) | chunk)
        out.extend(rest[:chunk])
        rest = rest[chunk:]
    out.extend(epilogue)

    data = struct.pack('>%dI' % len(out), *out)
    open(dst, 'wb').write(data)
    print(f"{src}: {n} frames, last non-zero {last} -> {dst}: {len(data)} B")


if __name__ == '__main__':
    main()
