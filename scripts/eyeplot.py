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
    """{(rx, tx): cell}, and the points where the two radio cores disagree.

    Both radio cores of a B210 drive the same AD9361 interface, so the scan
    covers every point twice.  A point that comes back differently the second
    time is unstable, and averaging the two away would hide exactly that.
    """
    cells, conflicts = {}, []
    for line in open(path):
        if not line.startswith("EYE "):
            continue
        f = line.split()
        key = (int(f[1]), int(f[2]))
        bits = f[3] + f[4]
        if "~" in bits:
            cell = "~"
        elif set(bits) == {"."}:
            cell = "."
        elif set(bits) == {"x"}:
            cell = "x"
        else:
            cell = "o"
        if key in cells:
            # The two radio cores see the same interface, so a point measured
            # twice with different results is unstable, not clean: keep it as
            # "~" and let it shorten the margin like any other bad point.
            if cells[key] != cell:
                conflicts.append(key)
                cells[key] = "~"
            continue
        cells[key] = cell
    return cells, conflicts


def run_length(cells, fixed, axis, start, step):
    """Clean steps from `start` (exclusive) in direction `step`."""
    n, d = 0, start + step
    while True:
        key = (d, fixed) if axis == "rx" else (fixed, d)
        if cells.get(key) != ".":
            return n, key in cells
        n, d = n + 1, d + step


def main():
    cells, conflicts = load(sys.argv[1])
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
    if conflicts:
        print("%d points came back differently in the two cores' scans and are "
              "counted as unstable (first rx=%d tx=%d)"
              % (len(conflicts), conflicts[0][0], conflicts[0][1]))
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
