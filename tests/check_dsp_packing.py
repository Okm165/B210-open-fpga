#!/usr/bin/env python3
"""check_dsp_packing.py - did yosys' DSP mapping leave register bits dangling?

yosys 0.69 has a fault in the pass that moves registers into DSP48E1 cells
(tests/yosys_dsp_signext.v).  When it packs a product or product-sum register
that has a reset or a clock enable and is wider than the value it holds, the
register's extra, sign-extending bits are left reading the old arithmetic
net, which no longer has a driver.  Later passes turn those bits into the
constant 0, and nothing in the final netlist or in the log says so.

Immediately after the DSP mapping the damage is still visible: yosys' own
`check` reports "Wire ... is used but has no driver".  tests/postsyn.sh runs
`check` before and after that stage; this script reads the two reports.

    check_dsp_packing.py design <dir>
        The complete design (<dir>/check_b200_before.txt, _after.txt): no
        wire may be undriven after the DSP mapping that was not undriven
        before it.

    check_dsp_packing.py reproducer <dir> <simulation log>
        The three modules of tests/yosys_dsp_signext.v.  For each, `check`
        must say "undriven" exactly when the simulation of the netlist says
        "products differ".  That is what makes the design check above worth
        something: on the yosys at hand it sees the fault where there is
        one and is silent where there is none.  Whether this yosys has the
        fault at all is reported, not judged.
"""
import os
import re
import sys

UNDRIVEN = re.compile(r"Warning: Wire (\S+) \[\d+\] is used but has no driver")
REPRO = ("signext_plain", "signext_rst", "signext_en")


def undriven(path):
    """Wire name -> number of undriven bits, from a `check` report."""
    wires = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = UNDRIVEN.search(line)
            if m:
                wires[m.group(1)] = wires.get(m.group(1), 0) + 1
    return wires


def design(d):
    before = undriven(os.path.join(d, "check_b200_before.txt"))
    after = undriven(os.path.join(d, "check_b200_after.txt"))
    new = {w: n for w, n in after.items() if n > before.get(w, 0)}
    if new:
        for w, n in sorted(new.items()):
            print("  %s: %d bits undriven after DSP mapping" % (w, n))
        print("FAIL: yosys' DSP mapping left %d wires of the design without a "
              "driver; a register is wider than the product or sum it holds "
              "(see tests/yosys_dsp_signext.v)" % len(new))
        return 1
    print("PASS: DSP mapping of the complete design leaves no register bit "
          "dangling (%d wire bits were undriven before it and still are)"
          % sum(before.values()))
    return 0


def reproducer(d, simlog):
    differ = {}
    with open(simlog, errors="replace") as f:
        for line in f:
            m = re.match(r"SIGNEXT (\w+): (\d+) products compared, (\d+) differ", line)
            if m:
                differ[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    bad = 0
    faulty = []
    for name in REPRO:
        if name not in differ or differ[name][0] < 1000:
            print("FAIL: no simulation result for %s in %s" % (name, simlog))
            return 1
        bits = sum(undriven(os.path.join(d, "check_%s_after.txt" % name)).values())
        n, wrong = differ[name]
        print("  %-14s check: %2d undriven bits   netlist: %4d of %d products wrong"
              % (name, bits, wrong, n))
        if (bits > 0) != (wrong > 0):
            bad += 1
        if wrong:
            faulty.append(name)
    if bad:
        print("FAIL: yosys' `check` after DSP mapping and the netlist simulation "
              "disagree on %d of the reproducer modules; the design check "
              "cannot be relied on with this yosys" % bad)
        return 1
    if faulty:
        print("PASS: this yosys mis-synthesizes %s, and `check` after DSP "
              "mapping reports exactly those" % " and ".join(faulty))
    else:
        print("PASS: this yosys synthesizes all three reproducer modules "
              "correctly, and `check` after DSP mapping reports none")
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "design":
        return design(argv[2])
    if len(argv) == 4 and argv[1] == "reproducer":
        return reproducer(argv[2], argv[3])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
