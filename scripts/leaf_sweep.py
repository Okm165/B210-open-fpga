#!/usr/bin/env python3
"""leaf_sweep.py - sweep the HCLK_IOI leaf-mux source bits in a frames file.

For each IGCLK k (0..11) this writes HCLK_IOI.LEAF_GCLK_BOT0 <- CK_IGCLK_k
into a copy of the input frames, assembles a .bin, and (when --flash) the
caller tests it.  Leaf source rows per DB:
  LEAF_GCLK_BOT0.CK_IGCLKk : distinct bit sets per k.

Usage: leaf_sweep.py <in.frames> <outdir>
"""
import json
import os
import sys

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))
TILE = 'HCLK_IOI_X235Y130'
blk = tg[TILE]['bits']['CLB_IO_CLK']
BASE = int(blk['baseaddr'], 16)
OFF = blk['offset']

# rows from segbits_hclk_ioi.db, LEAF_GCLK_BOT0 <- CK_IGCLKk
rows = {}
for line in open(f'{DB}/segbits_hclk_ioi.db'):
    line = line.strip()
    if not line.startswith('HCLK_IOI.HCLK_IOI_LEAF_GCLK_BOT0.'):
        continue
    feat, _, bits = line.partition(' ')
    k = int(feat.rsplit('K', 1)[1])
    toks = []
    for b in bits.split():
        f, wb = map(int, b.split('_'))
        toks.append((f, OFF + wb // 32, wb % 32))
    rows[k] = toks


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    frames = {}
    order = []
    for line in open(src):
        line = line.strip()
        if not line:
            continue
        a, ws = line.split()
        a = int(a, 16)
        frames[a] = [int(x, 16) for x in ws.split(',')]
        order.append(a)
    order.sort()

    # clear every leaf-source row first
    for k, toks in rows.items():
        for (f, w, b) in toks:
            a = BASE + f
            if a in frames:
                frames[a][w] &= ~(1 << b)

    for k in sorted(rows):
        fr = {a: list(w) for a, w in frames.items()}
        for (f, w, b) in rows[k]:
            a = BASE + f
            if a not in fr:
                fr[a] = [0] * 101
                if a not in order:
                    order.append(a)
            fr[a][w] |= (1 << b)
        order.sort()
        out = f'{outdir}/leaf{k}.frames'
        with open(out, 'w') as fh:
            for a in order:
                fh.write(hex(a) + ' ' + ','.join(f'{x:08x}' for x in fr[a]) + '\n')
        print('wrote', out)


if __name__ == '__main__':
    main()
