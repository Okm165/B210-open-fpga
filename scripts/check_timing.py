#!/usr/bin/env python3
"""Enforce the timing-margin policy on a nextpnr report.

Usage: check_timing.py PNR_REPORT.json [MARGIN]

Every clock must close with at least MARGIN (default 5 %, i.e. 1.05) of the
required frequency.  Closing at exactly the constraint is not enough: on this
design the routed result depends on the nextpnr seed (measured on the same
netlist: bus_clk 109.33 MHz against 100 required on one seed, 60.88 MHz on
another), and a route that closes by 0.1 % has no room for temperature,
voltage or a later re-synthesis.

The margin is deliberately modest.  It rejects routes that are lucky and keeps
the ones that are robust, without demanding a frequency the part cannot reach.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} PNR_REPORT.json [MARGIN]", file=sys.stderr)
        return 2
    report = json.loads(Path(argv[1]).read_text())
    margin = float(argv[2]) if len(argv) == 3 else 1.05
    clocks = report.get("fmax", {})
    if not clocks:
        print("ERROR: report contains no clock results", file=sys.stderr)
        return 1

    worst = None
    failed = False
    print(f"Timing margin policy: every clock >= {margin:.3f} x its constraint")
    for name in sorted(clocks):
        achieved = float(clocks[name].get("achieved", 0.0))
        constraint = float(clocks[name].get("constraint", 0.0))
        if constraint <= 0:
            continue
        ratio = achieved / constraint
        status = "ok" if ratio >= margin else "TOO TIGHT"
        if ratio < margin:
            failed = True
        if worst is None or ratio < worst[1]:
            worst = (name, ratio, achieved, constraint)
        print(f"  {name:34s} {achieved:9.2f} MHz  need {constraint:8.2f}"
              f"  x{ratio:5.3f}  {status}")

    if worst is not None:
        name, ratio, achieved, constraint = worst
        print(f"Worst clock: {name} at {achieved:.2f} MHz, {ratio:.3f} x {constraint:.2f} MHz")
    if failed:
        print("ERROR: timing margin below policy; the bitstream is not shippable as-is")
        return 1
    print("PASS: timing margin policy met")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
