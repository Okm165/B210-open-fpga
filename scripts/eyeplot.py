#!/usr/bin/env python3
"""eyeplot.py - summarise an eyescan.sh log.

Input lines:  EYE <rx> <tx> <U> <L>   (one char per data bit 11..0 of the two
12-bit words: '.' right phase, 'x' other phase, '~' unstable between reads).
Delay index d: d >= 0 is d steps of DATA delay, d < 0 is -d steps of CLOCK
delay (AD9361 registers 0x006 for RX, 0x007 for TX).

Prints the 2-D map (rows rx, columns tx) and the margins around the operating
point UHD programs on a B200/B210 (rx = 15, tx = 15).  Map cell: '.' every bit
right, 'x' every bit in the other phase (stable, I/Q swapped), 'o' stable but
bits disagree, '~' at least one unstable bit.
"""
import sys

UHD_RX, UHD_TX = 15, 15


def load(path):
    cells = {}
    for line in open(path):
        if not line.startswith("EYE "):
            continue
        f = line.split()
        key = (int(f[1]), int(f[2]))
        if key in cells:          # second radio core: same pins, keep the first
            continue
        bits = f[3] + f[4]
        if "~" in bits:
            cells[key] = "~"
        elif set(bits) == {"."}:
            cells[key] = "."
        elif set(bits) == {"x"}:
            cells[key] = "x"
        else:
            cells[key] = "o"
    return cells


def run_length(cells, fixed, axis, start, step):
    """Clean steps from `start` (exclusive) in direction `step`."""
    n, d = 0, start + step
    while True:
        key = (d, fixed) if axis == "rx" else (fixed, d)
        if cells.get(key) != ".":
            return n, key in cells
        n, d = n + 1, d + step


def main():
    cells = load(sys.argv[1])
    if not cells:
        sys.exit("no EYE lines in " + sys.argv[1])
    rxs = sorted({k[0] for k in cells})
    txs = sorted({k[1] for k in cells})
    print("       tx " + "".join("-" if t < 0 else "+" for t in txs))
    print("          " + "".join("%x" % abs(t) for t in txs))
    for r in rxs:
        print("rx %3d    " % r + "".join(cells.get((r, t), " ") for t in txs))
    here = cells.get((UHD_RX, UHD_TX))
    print("\nUHD operating point rx=%d tx=%d: %s" % (UHD_RX, UHD_TX, here))
    if here != ".":
        print("RESULT: FAIL - the operating point is not clean")
        sys.exit(1)
    for axis, fixed in (("rx", UHD_TX), ("tx", UHD_RX)):
        start = UHD_RX if axis == "rx" else UHD_TX
        lo, lo_seen = run_length(cells, fixed, axis, start, -1)
        hi, hi_seen = run_length(cells, fixed, axis, start, +1)
        print("  %s margin: %d steps below, %d steps above%s" % (
            axis, lo, hi, "" if hi_seen else " (scan range ends there)"))
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
