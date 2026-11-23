#!/usr/bin/env python3
"""Mark the whole GCLK spine stretch ACTIVE in a FASM.

Upstream openXC7/nextpnr#222 (cavearr, Vivado A/B on xc7k325t):
Vivado sets CLK_HROW_R_CK_GCLK<n>_ACTIVE in *every* clock row the global
clock crosses, not only where it has a load.  nextpnr sets it only on loaded
rows, so a clock crossing a row between the BUFG and its bank stops there.

Usage: patch_spine_active.py <in.fasm> <out.fasm>
"""
import json, re, sys

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))

def main(src, dst):
    lines = [l.rstrip('\n') for l in open(src)]
    gclk = None
    bufg_y = None
    for l in lines:
        m = re.match(r'^(CLK_HROW_BOT_R_X121Y(\d+))\.CLK_HROW_CK_MUX_OUT_R\d+\.CLK_HROW_R_CK_GCLK(\d+)$', l)
        if m:
            bufg_y = int(m.group(2)); gclk = int(m.group(3))
        m2 = re.match(r'^CLK_BUFG_BOT_R_X121Y(\d+)\.', l)
        if m2:
            bufg_y = int(m2.group(1))
    if gclk is None:
        sys.exit('no CLK_HROW_CK_MUX_OUT row found — nothing to anchor the GCLK index')
    # every CLK_HROW_BOT_R row between the BUFG row and the destination row
    rows = sorted((i['grid_y'], t) for t, i in tg.items()
                  if i['type'] == 'CLK_HROW_BOT_R' and i.get('grid_x') == 121)
    lo, hi = min(rows)[0], max(rows)[0]
    span = [t for y, t in rows if lo <= y <= hi]
    have = set(lines)
    added = 0
    out = list(lines)
    for t in span:
        feat = f'{t}.CLK_HROW_R_CK_GCLK{gclk}_ACTIVE'
        if feat not in have:
            out.append(feat); added += 1
    # also the BUFG row's own GCLK active marker if the schema carries it
    open(dst, 'w').write('\n'.join(out) + '\n')
    print(f'gclk={gclk} rows_in_span={len(span)} active_rows_added={added}')

main(sys.argv[1], sys.argv[2])
