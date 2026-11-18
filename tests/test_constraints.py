#!/usr/bin/env python3
"""Static check of src/constraints/b210.xdc against the real top-level module.

This is a software-only alignment guard.  A pin that has no LOC is still
routed by nextpnr -- to a site chosen by the placer -- so the bitstream builds
cleanly and the board does not work.  The same holds for a missing
IOSTANDARD, a pin claimed twice, or a clock constraint attached to a name that
does not exist.

Checks performed:
  1. every port of `module b200` has a LOC
  2. every port of `module b200` has an IOSTANDARD
  3. no physical pin is assigned twice
  4. every get_ports entry names a real port (or element of one)
  5. every create_clock names a real port or a net that exists in the RTL
  6. LOC and IOSTANDARD cover the same set of ports
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XDC = ROOT / "src" / "constraints" / "b210.xdc"
TOP = ROOT / "src" / "top" / "b200.v"
RTL_DIR = ROOT / "src"


def top_ports() -> list[str]:
    src = TOP.read_text(errors="replace")
    body = re.search(r"module\s+b200\s*\((.*?)\);", src, re.S)
    if not body:
        raise SystemExit("FAIL: could not find the b200 module header")
    text = re.sub(r"//[^\n]*", "", body.group(1))
    ports = []
    for m in re.finditer(
        r"(?:inout|input|output)\s*(?:\[[^\]]+\]\s*)?([A-Za-z_]\w*)", text
    ):
        ports.append(m.group(1))
    return ports


def property_pairs(kind: str) -> list[tuple[str, str]]:
    """(value, port) for `set_property KIND value [get_ports PORT]`."""
    text = XDC.read_text(errors="replace")
    pattern = (
        r"set_property\s+" + kind + r"\s+(\S+)\s+\[get_ports\s+(?:\{([^}]+)\}|([^\]]+))\]"
    )
    out = []
    for m in re.finditer(pattern, text):
        port = (m.group(2) or m.group(3)).strip()
        out.append((m.group(1), port))
    return out


def rtl_nets() -> set[str]:
    """Identifiers that look like nets, collected from every RTL file.

    Deliberately permissive: the goal is to catch a *typo* in a clock
    constraint, not to prove the net exists after synthesis.
    """
    names: set[str] = set()
    for path in RTL_DIR.rglob("*.v"):
        for m in re.finditer(r"\b([A-Za-z_]\w{2,})\b", path.read_text(errors="replace")):
            names.add(m.group(1))
    return names


def port_matches(entry: str, ports: list[str]) -> bool:
    if entry in ports:
        return True
    base = entry.split("[")[0]
    return base in ports


def covered(name: str, entries: set[str]) -> bool:
    """True if `name` or any element of it (`name[i]`) appears in `entries`."""
    return name in entries or any(e.startswith(name + "[") for e in entries)


def main() -> int:
    ports = top_ports()
    loc = property_pairs("LOC")
    std = property_pairs("IOSTANDARD")
    errors: list[str] = []

    # 1 and 2: coverage
    loc_names = {p for _, p in loc}
    std_names = {p for _, p in std}
    for p in ports:
        if not covered(p, loc_names):
            errors.append(f"port '{p}' has no LOC")
        if not covered(p, std_names):
            errors.append(f"port '{p}' has no IOSTANDARD")

    # 3: duplicate pin assignment
    pins = Counter(pin for pin, _ in loc if not pin.startswith("{"))
    for pin, count in sorted(pins.items()):
        if count > 1:
            users = sorted(p for pn, p in loc if pn == pin)
            errors.append(f"pin {pin} assigned {count} times: {', '.join(users)}")

    # 4: every get_ports entry resolves to a real port
    for _, entry in loc + std:
        if not port_matches(entry, ports):
            errors.append(f"get_ports entry '{entry}' is not a port of b200")

    # 6: LOC and IOSTANDARD agree
    for p in sorted(loc_names - std_names):
        errors.append(f"port '{p}' has LOC but no IOSTANDARD")
    for p in sorted(std_names - loc_names):
        errors.append(f"port '{p}' has IOSTANDARD but no LOC")

    # 5: clocks
    nets = rtl_nets()
    clock_re = re.compile(r"create_clock\s+-period\s+(\S+)\s+\[get_(ports|nets)\s+([^\]]+)\]")
    clocks = clock_re.findall(XDC.read_text(errors="replace"))
    if not clocks:
        errors.append("no create_clock constraints found")
    for period, kind, name in clocks:
        name = name.strip().strip("{}")
        try:
            float(period)
        except ValueError:
            errors.append(f"create_clock period '{period}' is not a number")
        if kind == "ports" and name not in ports:
            errors.append(f"create_clock on unknown port '{name}'")
        if kind == "nets" and name not in nets:
            errors.append(f"create_clock on unknown net '{name}'")

    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        print(f"FAIL: {len(errors)} constraint problem(s)")
        return 1

    print(
        "PASS: constraints cover "
        f"{len(ports)} top-level ports, {len(loc)} LOC, "
        f"{len(clocks)} clock(s), no duplicates"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
