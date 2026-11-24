#!/usr/bin/env python3
"""fast_test.py - test bit-level hypotheses on the board WITHOUT re-running PnR.

Each candidate = an existing routed fasm + a small patch, assembled to a bin
(scripts/assemble.sh) and measured with three instruments:
  drain   fx3_raw_load.py  (full FX3 reboot; vendor = 8 MB @ ~12 MB/s)
  fx3     fx3_diag.py      (PIB/GPIF error lines in the stock firmware log:
                            any line proves PCLK + strobes reach the FX3)
  ctrl    ctrl_peek.py     (raw VRT register peek over EP4/EP0x88)

usage: fast_test.py candidates.json
candidates.json = [{
   "name":  "label",
   "base":  "build/fpga/ring2/pnr/b200_80t.fasm",
   "add":   ["TILE.FEATURE", ...],        optional
   "drop":  ["substring", ...],           optional
   "zinv_t1": true,   set OLOGIC_Y<i>.ZINV_T1 wherever the pad tristate is
                      driven through the OLOGIC (RIOI_T<i> <- RIOI_OLOGIC<i>_TQ)
   "spine":   true    mark every used GCLK ACTIVE in every CLK_HROW row
}, ...]
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = 'build/tmp'
HROWS = [f'CLK_HROW_BOT_R_X121Y{y}' for y in (26, 78, 130, 182)] + \
        [f'CLK_HROW_TOP_R_X121Y{y}' for y in (234, 286, 338)]


def patch(c):
    src = open(f'{ROOT}/{c["base"]}').read().splitlines()
    src = [l for l in src if not any(d in l for d in c.get('drop', []))]
    add = list(c.get('add', []))
    if c.get('zinv_t1'):
        for l in src:
            m = re.match(r'^(RIOI\w*_X\d+Y\d+)\.RIOI_T([01])\.RIOI_OLOGIC[01]_TQ$', l)
            if m:
                add.append(f'{m.group(1)}.OLOGIC_Y{m.group(2)}.ZINV_T1')
    if c.get('spine'):
        for g in sorted(set(re.findall(r'CLK_HROW_CK_MUX_OUT_[LR]\d+\.CLK_HROW_R_CK_GCLK(\d+)', '\n'.join(src)))):
            add += [f'{t}.CLK_HROW_R_CK_GCLK{g}_ACTIVE' for t in HROWS]
    have = set(src)
    new = [a for a in dict.fromkeys(add) if a not in have]
    open(f'{ROOT}/{TMP}/ft_{c["name"]}.fasm', 'w').write('\n'.join(src + new) + '\n')
    return len(new)


def assemble(name):
    r = subprocess.run([f'{ROOT}/scripts/assemble.sh', f'{TMP}/ft_{name}.fasm', f'{TMP}/ft_{name}.bin'],
                       capture_output=True, text=True)
    return (r.stderr.strip().splitlines() or ['assemble failed'])[-1][:150] if r.returncode else None


def run(*cmd, timeout=600):
    return subprocess.run([sys.executable, *cmd], capture_output=True, text=True, timeout=timeout, cwd=ROOT).stdout


def measure(name):
    drain = (run('scripts/fx3_raw_load.py', f'{TMP}/ft_{name}.bin').strip().splitlines() or ['?'])[-1]
    fx3 = (run('scripts/fx3_diag.py', timeout=60).splitlines() or ['?'])[0]
    ctrl = [l for l in run('scripts/ctrl_peek.py', '8', timeout=120).splitlines() if l.startswith('responses')]
    return drain, fx3, (ctrl[0] if ctrl else 'ctrl ?')


def main():
    for c in json.load(open(sys.argv[1])):
        n = patch(c)
        err = assemble(c['name'])
        if err:
            print(f'{c["name"]:26s} +{n:<4d} BUILD-FAIL: {err}', flush=True)
            continue
        d, f, k = measure(c['name'])
        print(f'{c["name"]:26s} +{n:<4d} | {d:32s} | {f} | {k}', flush=True)


main()
