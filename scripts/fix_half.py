#!/usr/bin/env python3
"""fix_half.py - post-process diag_ring5 frames:
1. swap the OLOGIC pass-through config from the Y0 half to the Y1 half
   (AD1's OLOGIC is the Y1 half per the vendor reference),
2. graft the vendor-proven fabric route:
   LOGIC_OUTS_L0 -> EE2BEG0@INT_L_X92Y96 -> EE2END0 -> WR1BEG1@INT_L_X94Y96
   -> IMUX34@INT_R_X95Y109 (D1 of the Y1 half),
3. tie T low via IMUX15/GFAN1 at Y109.
"""
import json, os, re, sys

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))


def load_frames(p):
    fr, order = {}, []
    for line in open(p):
        line = line.strip()
        if not line:
            continue
        a, ws = line.split()
        a = int(a, 16)
        fr[a] = [int(x, 16) for x in ws.split(',')]
        order.append(a)
    return fr, order


def tile_pips(tt):
    R = {}
    for suf in ('.db', '_sing.db'):
        p = f'{DB}/segbits_{tt.lower()}{suf}'
        if not os.path.exists(p):
            continue
        for line in open(p):
            feat, _, bits = line.strip().partition(' ')
            R[feat] = [(int(b.lstrip('!').split('_')[0]), int(b.lstrip('!').split('_')[1]),
                        not b.startswith('!')) for b in bits.split()]
    return R


def apply(fr, order, tile, tt, feat):
    R = tile_pips(tt)
    toks = R.get(f'{tt}.{feat}')
    if toks is None:
        print('MISSING row:', tt, feat)
        return 0
    blk = tg[tile]['bits']['CLB_IO_CLK']
    base = int(blk['baseaddr'], 16)
    off = blk['offset']
    n = 0
    for f, wb, pol in toks:
        a = base + f
        if a not in fr:
            fr[a] = [0] * 101
            order.append(a)
        w, b = off + wb // 32, wb % 32
        if pol:
            if not (fr[a][w] >> b) & 1:
                fr[a][w] |= 1 << b
                n += 1
        else:
            if (fr[a][w] >> b) & 1:
                fr[a][w] &= ~(1 << b)
                n += 1
    return n


def main(in_frames, out_frames):
    fr, order = load_frames(in_frames)
    total = 0
    # 1. ensure the Y1-half pass-through config (ORMUX.D1/OQUSED/TQ.BUF) at RIOI_X95Y109
    for feat in ('OLOGIC_Y1.OMUX.D1', 'OLOGIC_Y1.OQUSED', 'OLOGIC_Y1.OSERDES.DATA_RATE_TQ.BUF'):
        total += apply(fr, order, 'RIOI_X95Y109', 'RIOI', feat)
    # 2. vendor route rows
    total += apply(fr, order, 'INT_L_X92Y96', 'INT_L', 'EE2BEG0.LOGIC_OUTS_L8')
    total += apply(fr, order, 'INT_L_X94Y96', 'INT_L', 'WR1BEG1.EE2END0')
    total += apply(fr, order, 'INT_R_X95Y109', 'INT_R', 'IMUX34.WR1END1')
    # 3. T tie low at the Y1 half (IMUX15_0 -> INT tile at same row Y109)
    total += apply(fr, order, 'INT_R_X95Y109', 'INT_R', 'IMUX15.GFAN1')
    total += apply(fr, order, 'INT_R_X95Y109', 'INT_R', 'GFAN1.GND_WIRE')
    order.sort()
    with open(out_frames, 'w') as fh:
        for a in order:
            fh.write(hex(a) + ' ' + ','.join(f'{x:08x}' for x in fr[a]) + '\n')
    print('total bits written:', total)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
