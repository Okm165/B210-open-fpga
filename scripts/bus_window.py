#!/usr/bin/env python3
"""bus_window.py - the FX3 bus timing window of a routed design, measured.

  bus_window.py <routed.fasm> [--steps A:B:S] [--run "command {bin} ..."]
  bus_window.py <routed.fasm> --around M --image <its .bin> --run "..."

The clock forwarded to the FX3 comes from its own MMCM output (IFCLK_STEPS in
src/top/b200_clk_gen.v: its lag behind the bus clock in steps of 104 ps, 96
steps to a 10 ns period).  The FX3 times every bus signal against that
clock, so moving it moves the sampling instants on both sides of the bus.
This patches the lag into copies of one routed design - nothing is placed or
routed again - and runs the command on each (default: the echo test of
src/top/diag_echo.v, which checks both directions of the bus bit for bit).
The result is the range of lags the bus works at, its centre, and how far
the design's own setting is from each edge.

--around M checks a margin instead of scanning: the two lags M steps before
and after the built one, exit status 0 only if the command succeeds at both.
--image names the image the fasm is said to have produced; the unpatched
fasm is assembled as well and must give exactly those bytes.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERIOD = 96      # steps in one 100 MHz bus clock period
STEP_PS = 10000 / PERIOD


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('fasm')
    ap.add_argument('--steps', default='0:96:8', help='first:end:increment, in steps (default 0:96:8)')
    ap.add_argument('--run', default=f'{sys.executable} scripts/fx3_raw_load.py {{bin}} --echo 2000')
    ap.add_argument('--around', type=int, metavar='M')
    ap.add_argument('--image')
    a = ap.parse_args()
    first, end, inc = (int(x) for x in a.steps.split(':'))

    text = open(os.path.join(ROOT, a.fasm)).read()
    mux = re.search(r"^(\S+\.MMCME2_ADV\.)CLKOUT2_CLKOUT1_PHASE_MUX\[2:0\] = 3'b([01]{3})$", text, re.M)
    dly = re.search(r"^\S+\.MMCME2_ADV\.CLKOUT2_CLKOUT2_DELAY_TIME\[5:0\] = 6'b([01]{6})$", text, re.M)
    if not mux or not dly:
        sys.exit('no MMCM CLKOUT2 phase in this fasm: not a design with a forwarded bus clock')
    tile = mux.group(1)
    built = int(dly.group(1), 2) * 8 + int(mux.group(2), 2)
    # The MMCM's phase interpolators are powered (POWER_REG 0x9900 instead of
    # 0x0100) when some output is shifted by other than a multiple of half a
    # VCO period; without that such an output does not run.
    power = re.search(r"^\S+\.MMCME2_ADV\.POWER_REG_POWER_REG_POWER_REG\[15:0\] = 16'b([01]{16})$", text, re.M)
    if not power:
        sys.exit('no MMCM POWER_REG in this fasm')
    interpolators_on = int(power.group(1), 2) == 0x9900
    tag = os.path.basename(a.fasm).replace('.fasm', '')
    lags = [s % PERIOD for s in range(first, end, inc)]
    if a.around:
        lags = [(built - a.around) % PERIOD, (built + a.around) % PERIOD]
    if a.image:
        # the fasm must be the one this image was assembled from
        r = subprocess.run(['scripts/assemble.sh', a.fasm, f'build/tmp/{tag}_asbuilt.bin'], cwd=ROOT)
        digest = lambda f: hashlib.sha256(open(os.path.join(ROOT, f), 'rb').read()).hexdigest()
        if r.returncode or digest(f'build/tmp/{tag}_asbuilt.bin') != digest(a.image):
            sys.exit(f'{a.fasm} does not assemble to {a.image}')
    json.dump([{'name': f'{tag}_lag{s:02d}', 'base': a.fasm,
                'drop': [tile + 'CLKOUT2_CLKOUT1_PHASE_MUX', tile + 'CLKOUT2_CLKOUT2_DELAY_TIME',
                         tile + 'POWER_REG_POWER_REG_POWER_REG'],
                'add': [f"{tile}CLKOUT2_CLKOUT1_PHASE_MUX[2:0] = 3'b{s & 7:03b}",
                        f"{tile}CLKOUT2_CLKOUT2_DELAY_TIME[5:0] = 6'b{s >> 3:06b}",
                        f"{tile}POWER_REG_POWER_REG_POWER_REG[15:0] = 16'b"
                        f"{0x9900 if interpolators_on or s % 4 else 0x0100:016b}"]} for s in lags],
              open(os.path.join(ROOT, 'build/tmp', f'{tag}_window.json'), 'w'), indent=1)
    out = subprocess.run([sys.executable, 'scripts/fast_test.py', f'build/tmp/{tag}_window.json', '--run', a.run],
                         cwd=ROOT, capture_output=True, text=True).stdout
    open(os.path.join(ROOT, 'build/tmp', f'{tag}_window.txt'), 'w').write(out)

    # a candidate passed when its last output line says so; one that could
    # not be assembled was not measured
    blocks = re.split(r'^== ', out, flags=re.M)[1:]
    result = {}
    for block in blocks:
        name = block.split(':', 1)[0]
        if 'ASSEMBLE FAILED' in block:
            sys.exit(f'{name} could not be assembled, see build/tmp/{tag}_window.txt')
        result[int(name[-2:])] = 'RESULT: PASS' in block.strip().splitlines()[-1]
    print(f'design built with a lag of {built} steps ({built * STEP_PS / 1000:.2f} ns); '
          f'details in build/tmp/{tag}_window.txt')
    print('lag (steps): ' + ' '.join(f'{s:2d}' for s in lags))
    print('             ' + ' '.join(' .' if result.get(s) else ' X' for s in lags))
    passing = [s for s in lags if result.get(s)]
    if a.around:
        ok = len(passing) == len(lags) == 2
        print(f'{a.around * STEP_PS / 1000:.2f} ns before and after the built setting: '
              + ('works at both' if ok else 'FAILS'))
        sys.exit(0 if ok else 1)
    if not passing or len(passing) == len(lags):
        print('no edge of the window inside the scanned range')
        sys.exit(0 if passing else 1)
    # longest run of passing lags, taken around the period
    best = (0, 0)
    for start in range(len(lags)):
        n = 0
        while n < len(lags) and result.get(lags[(start + n) % len(lags)]):
            n += 1
        if n > best[1]:
            best = (start, n)
    lo, hi = lags[best[0]], lags[(best[0] + best[1] - 1) % len(lags)]
    width = (hi - lo) % PERIOD
    centre = (lo + width // 2) % PERIOD
    print(f'widest working range: lag {lo} to {hi} steps ({width * STEP_PS / 1000:.2f} ns between the outermost '
          f'working points, scanned every {inc * STEP_PS / 1000:.2f} ns), centre {centre}')
    if result.get(built) is not None:
        print(f'the built setting ({built}) is {(built - lo) % PERIOD * STEP_PS / 1000:.2f} ns after the first working '
              f'point and {(hi - built) % PERIOD * STEP_PS / 1000:.2f} ns before the last')


if __name__ == '__main__':
    main()
