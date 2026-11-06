#!/usr/bin/env python3
"""Summarize a nextpnr JSON timing/utilization report.

Usage: pnr-report.py build/fpga/reports/pnr-report.json [paths]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} PNR_REPORT.json [N_PATHS]", file=sys.stderr)
        return 2
    report = json.loads(Path(argv[1]).read_text())
    n_paths = int(argv[2]) if len(argv) == 3 else 5

    print("Clock domains:")
    for name, fmax in sorted(report.get("fmax", {}).items()):
        achieved = fmax.get("achieved")
        constraint = fmax.get("constraint")
        status = "PASS" if achieved >= constraint else "FAIL"
        print(f"  {name:32s} {achieved:8.2f} MHz  target {constraint:8.2f} MHz  {status}")

    print("\nUtilization:")
    for name, util in sorted(report.get("utilization", {}).items()):
        used = util.get("used", 0)
        available = util.get("available", 0)
        pct = (100.0 * used / available) if available else 0.0
        print(f"  {name:32s} {used:8d} / {available:8d}  {pct:6.2f}%")

    paths = report.get("critical_paths", [])
    print(f"\nCritical paths ({min(n_paths, len(paths))} of {len(paths)}):")
    for idx, path in enumerate(paths[:n_paths], 1):
        print(f"\n  [{idx}] {path.get('from')} -> {path.get('to')}")
        segments = path.get("path", [])
        total = 0.0
        for seg in segments:
            delay = float(seg.get("delay", 0.0))
            total += delay
            frm = seg.get("from", {})
            to = seg.get("to", {})
            kind = seg.get("type", "?")
            net = seg.get("net", "")
            print(
                f"      {delay:8.3f} ns  {kind:8s} "
                f"{frm.get('cell','?')}.{frm.get('port','?')} -> "
                f"{to.get('cell','?')}.{to.get('port','?')}"
                + (f"  [{net}]" if net else "")
            )
        print(f"      {total:8.3f} ns  total")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
