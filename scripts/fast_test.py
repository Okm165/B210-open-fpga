#!/usr/bin/env python3
"""fast_test.py - test bit-level hypotheses on the board WITHOUT re-running PnR.

Each candidate is an existing routed fasm plus a small patch.  It is assembled
(scripts/assemble.sh) and measured on the board with one instrument:

  default   scripts/fx3_raw_load.py --peek 16   control path + 8 MB drain
  --eye     scripts/eyescan.sh                  AD9361 interface eye margins
  --run CMD any command; {bin} in it is the candidate's image

usage: fast_test.py candidates.json [--eye | --run "command {bin} ..."] [--jobs N]

All candidates are assembled first, N at a time (default 4); the board then
sees them one after another.
candidates.json = [{
   "name": "label",
   "base": "build/fpga/pnr/b200.fasm",
   "drop": ["substring", ...],     lines containing any of these are removed
   "add":  ["TILE.FEATURE", ...]   lines appended (if not already present)
}, ...]
"""
import concurrent.futures
import json
import os
import shlex
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = 'build/tmp'


def patch(c):
    lines = open(f'{ROOT}/{c["base"]}').read().splitlines()
    kept = [l for l in lines if not any(d in l for d in c.get('drop', []))]
    have = set(kept)
    added = [a for a in dict.fromkeys(c.get('add', [])) if a not in have]
    os.makedirs(f'{ROOT}/{TMP}', exist_ok=True)
    open(f'{ROOT}/{TMP}/ft_{c["name"]}.fasm', 'w').write('\n'.join(kept + added) + '\n')
    return len(lines) - len(kept), len(added)


def run(cmd, timeout):
    """Returns (ok, last lines of output)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return False, [f'timed out after {timeout} s']
    out = (r.stdout + r.stderr).strip().splitlines()
    return r.returncode == 0, out[-4:] or ['no output']


def main():
    eye = '--eye' in sys.argv
    custom = sys.argv[sys.argv.index('--run') + 1] if '--run' in sys.argv else None
    jobs = int(sys.argv[sys.argv.index('--jobs') + 1]) if '--jobs' in sys.argv else 4
    candidates = json.load(open(sys.argv[1]))

    def assemble(c):
        counts = patch(c)
        return counts, run(['scripts/assemble.sh', f'{TMP}/ft_{c["name"]}.fasm', f'{TMP}/ft_{c["name"]}.bin'], 1800)

    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        assembled = list(pool.map(assemble, candidates))
    # The frame tool locks the database files it reads; several at once can
    # time out on a busy host.  What failed in parallel is assembled again alone.
    assembled = [a if a[1][0] else assemble(c) for c, a in zip(candidates, assembled)]

    failed = 0
    for c, ((dropped, added), (ok, out)) in zip(candidates, assembled):
        bin_path = f'{TMP}/ft_{c["name"]}.bin'
        print(f'== {c["name"]}: -{dropped} +{added} lines', flush=True)
        if ok:
            if custom:
                measure = shlex.split(custom.replace('{bin}', bin_path))
            elif eye:
                measure = ['scripts/eyescan.sh', bin_path]
            else:
                measure = [sys.executable, 'scripts/fx3_raw_load.py', bin_path, '--peek', '16']
            ok, out = run(measure, 900)
        else:
            out = ['ASSEMBLE FAILED'] + out
        failed += not ok
        print('\n'.join('   ' + l for l in out), flush=True)
        print('VERDICT %s %s' % (c['name'], 'PASS' if ok else 'FAIL'), flush=True)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
