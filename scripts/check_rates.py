#!/usr/bin/env python3
"""check_rates.py - the transmit level and the CIC range, against the driver.

Two properties make the TX level rate-independent on hardware, and neither is
obvious from the RTL alone:

1. `cic_int_shifter` normalises by a shift, so its gain is R^3/2^shift.  The
   shift is `ceil_log2(R^3)` at every rate, which makes that gain exactly the
   reciprocal of what UHD's `tx_dsp_core_3000` writes into the TX scale
   register (SR_TX_DSP+4): `2^ceil_log2(R^3)/R^3`.  Product = 1, so the level
   does not depend on the rate.

2. The CIC needs `R^3 <= 2^21` (16 data + 21 guard bits).  UHD's TX rate menu
   is laid out so the rate *after* the halfbands never exceeds 128: above 128
   it steps by 4, then by 2, i.e. it strips exactly the two halfbands this
   design has.  A custom driver writing an odd rate above 128 would overflow.

The UHD menu below is a snapshot of UHD master
(host/lib/usrp/cores/tx_dsp_core_3000.cpp, get_host_rates): 512..260 step 4,
256..130 step 2, 128..1 step 1.
"""
import math
import re
import sys

RTL = "src/rtl/dsp/cic_int_shifter.v"
MAXBITS = 21


def shift_table():
    src = open(RTL).read()
    tbl = {}
    for m in re.finditer(r"((?:8'd\d+\s*,\s*)*8'd\d+)\s*:\s*bitgain\s*=\s*(\d+)",
                         src):
        for n in re.findall(r"8'd(\d+)", m.group(1)):
            tbl[int(n)] = int(m.group(2))
    m = re.search(r"default\s*:\s*bitgain\s*=\s*(\d+)", src)
    default = int(m.group(1))
    return tbl, default


def ceil_log2(x):
    return 0 if x <= 1 else (x - 1).bit_length()


def cic_rate(interp):
    """The RTL's CIC rate after UHD enables up to two halfbands."""
    hb = 0
    while interp % 2 == 0 and hb < 2:
        hb += 1
        interp //= 2
    return interp, hb


def main():
    tbl, default = shift_table()
    fail = []

    for r in range(1, 129):
        sh = tbl.get(r, default)
        want = ceil_log2(r ** 3)
        if sh != want:
            fail.append(f"R={r}: shift {sh}, ceil_log2(R^3) {want}")
        if sh > MAXBITS:
            fail.append(f"R={r}: shift {sh} exceeds the {MAXBITS} guard bits")
    if default != MAXBITS:
        fail.append(f"default shift {default} != {MAXBITS}: rates above 128 "
                    f"would leave gain without guard bits")

    menu = (list(range(512, 256, -4)) + list(range(256, 128, -2))
            + list(range(128, 0, -1)))
    worst = 0.0
    worst_rate = 0
    max_cic = 0
    for r in menu:
        cr, hb = cic_rate(r)
        max_cic = max(max_cic, cr)
        if cr > 128:
            fail.append(f"UHD rate {r} -> CIC rate {cr} > 128 (overflow)")
        sh = tbl.get(cr, default)
        g = cr ** 3 / 2 ** sh              # the shifter leaves this
        u = 2 ** ceil_log2(cr ** 3) / cr ** 3   # UHD's scale factor
        d = abs(g * u - 1.0)
        if d > worst:
            worst, worst_rate = d, r

    if max_cic != 128:
        fail.append(f"max CIC rate over the menu is {max_cic}, expected 128 "
                    f"(the limit would not be exercised the way this says)")
    if worst > 1e-12:
        fail.append(f"level after UHD scaling off by {worst:.3e} at rate {worst_rate}")

    if fail:
        print("RATES: FAIL")
        for f in fail[:10]:
            print("  " + f)
        return 1
    print(f"RATES: PASS - {len(menu)} UHD TX rates, CIC rate <= {max_cic}, "
          f"shift = ceil_log2(R^3) for R=1..128, "
          f"level after TX scale off by {worst:.1e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
