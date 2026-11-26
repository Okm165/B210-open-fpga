#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Mutants of the FPGA RTL for scripts/mutate.sh.

Each mutant is one small textual change at one place in one file: an
operator swapped, a constant inverted, a shift reversed. The benches then
say whether the design's tests notice it. A mutant no bench notices is
either a gap in the benches or an equivalent change (one that cannot alter
behaviour); both are reported, and every survivor has to be classified by
hand.

  mutate.py list            one line per mutant: id, file, line, old, new
  mutate.py apply ID DIR    copy fpga/rtl into DIR with that mutant applied
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(ROOT, "fpga", "rtl")

# (old, new) textual swaps. Chosen so that each occurrence is a plausible
# coding slip: a condition inverted, a bit combined with OR instead of AND,
# a shift the wrong way, a constant inverted.
SWAPS = [
    ("&&", "||"),
    ("||", "&&"),
    ("==", "!="),
    ("!=", "=="),
    (" & ", " | "),
    (" | ", " & "),
    (" ^ ", " & "),
    (" >> ", " << "),
    (" << ", " >> "),
    ("1'b0", "1'b1"),
    ("1'b1", "1'b0"),
]


def code_part(line: str) -> str:
    """The line without its comment: a change in a comment observes nothing."""
    for marker in ("//", "/*"):
        i = line.find(marker)
        if i >= 0:
            line = line[:i]
    return line


def mutants():
    out = []
    for name in sorted(os.listdir(RTL)):
        if not name.endswith(".v"):
            continue
        path = os.path.join(RTL, name)
        with open(path) as f:
            lines = f.readlines()
        for no, line in enumerate(lines, 1):
            code = code_part(line)
            if not code.strip() or code.lstrip().startswith(("`", "*")):
                continue
            for old, new in SWAPS:
                start = 0
                while True:
                    i = code.find(old, start)
                    if i < 0:
                        break
                    # the occurrence index of `old` in this line: the k-th
                    # match, so apply() and the id agree on the place
                    occ = code.count(old, 0, i)
                    out.append((name, no, occ, old, new, i))
                    start = i + len(old)
    # one entry per (file, line, occurrence, swap): there is no other identity
    seen = set()
    unique = []
    for m in out:
        key = (m[0], m[1], m[2], m[3], m[4])
        if key not in seen:
            seen.add(key)
            unique.append(m)
    unique.sort(key=lambda m: (m[0], m[1], m[5], m[3]))
    return unique


def manifest():
    for k, (name, line, occ, old, new, _) in enumerate(mutants()):
        print(f"{k}\t{name}\t{line}\t{old}\t{new}")


def apply(mid: int, dest: str):
    ms = mutants()
    if not 0 <= mid < len(ms):
        sys.exit(f"no mutant {mid} (0 .. {len(ms) - 1})")
    name, line, occ, old, new, _ = ms[mid]
    os.makedirs(dest, exist_ok=True)
    for f in os.listdir(RTL):
        if f.endswith(".v") or f.endswith(".vh"):
            shutil.copy(os.path.join(RTL, f), os.path.join(dest, f))
    path = os.path.join(dest, name)
    with open(path) as f:
        text = f.read()
    with open(os.path.join(RTL, name)) as f:
        lines = f.readlines()
    # apply at the same place: the occ-th occurrence of `old` in that line
    target = lines[line - 1]
    i = -1
    for _ in range(occ + 1):
        i = target.find(old, i + 1)
        if i < 0:
            sys.exit(f"mutant {mid}: occurrence {occ} of {old!r} not in line {line}")
    new_line = target[:i] + new + target[i + len(old):]
    # exactly that occurrence changed: reversing the swap gives the line back
    if new_line[:i] + old + new_line[i + len(new):] != target:
        sys.exit(f"mutant {mid}: applied text differs from the recorded place")
    lines[line - 1] = new_line
    with open(path, "w") as f:
        f.writelines(lines)
    # sanity: exactly one line changed
    changed = sum(1 for a, b in zip(text.splitlines(), "".join(lines).splitlines()) if a != b)
    if changed != 1:
        sys.exit(f"mutant {mid}: {changed} lines changed, 1 expected")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        manifest()
    elif len(sys.argv) == 4 and sys.argv[1] == "apply":
        apply(int(sys.argv[2]), sys.argv[3])
    else:
        sys.exit(__doc__)
