#!/usr/bin/env python3
"""Graft ring9's X1-only 4-inverter ring (CLBLL_L_X92Y96 slice + INT routes)
into the WORKING vendor bitstream, repointing EE2BEG0 from LOGIC_OUTS_L4
(vendor's FF) to LOGIC_OUTS_L18 (our C6LUT O6, sweep-proven to drain).

Everything else in the vendor image is preserved byte-for-byte:
pad column rows, IOB_COL rows, ODDR D1/D2 toggle config, all other fabric.
"""
import json, os, re, sys

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))

# --- load segbits DBs: tiletype -> feature -> [(frame, bit, polarity)]
R = {}
for tt in ('clbll_l', 'int_l'):
    for suf in ('.db', '_sing.db'):
        p = f'{DB}/segbits_{tt}{suf}'
        if not os.path.exists(p):
            continue
        for line in open(p):
            feat, _, bits = line.strip().partition(' ')
            R[feat] = [(int(b.lstrip('!').split('_')[0]), int(b.lstrip('!').split('_')[1]),
                        not b.startswith('!')) for b in bits.split()]

def loadf(p):
    fr = {}; order = []
    for line in open(p):
        line = line.strip()
        if not line: continue
        a, ws = line.split(); a = int(a, 16)
        fr[a] = [int(x, 16) for x in ws.split(',')]; order.append(a)
    return fr, order

def setfeat(fr, order, tile, feat):
    blk = tg[tile]['bits']['CLB_IO_CLK']
    base = int(blk['baseaddr'], 16); off = blk['offset']
    for f, wb, pol in R[feat]:
        a = base + f
        if a not in fr:
            fr[a] = [0] * 101; order.append(a)
        w, b = off + wb // 32, wb % 32
        if pol: fr[a][w] |= (1 << b)
        else:   fr[a][w] &= ~(1 << b)

def clearfeat(fr, order, tile, feat):
    blk = tg[tile]['bits']['CLB_IO_CLK']
    base = int(blk['baseaddr'], 16); off = blk['offset']
    for f, wb, pol in R[feat]:
        a = base + f
        if a not in fr: continue
        w, b = off + wb // 32, wb % 32
        if pol: fr[a][w] &= ~(1 << b)
        else:   fr[a][w] |= (1 << b)

fr, order = loadf('build/tmp/vendor_true.frames')

# vendor feature set per tile (for same-dst conflict clearing)
vfeat = {}
for line in open('build/vendor.fasm'):
    m = re.match(r'^([A-Za-z0-9_]+_[LR]_X\d+Y\d+)\.(\S+)$', line.strip())
    if m: vfeat.setdefault(m.group(1), []).append(m.group(2))

TILE_CLB = 'CLBLL_L_X92Y96'
TILE_INT = 'INT_L_X92Y96'
applied = 0

for line in open('build/fpga/ring2/pnr/diag_ring9.fasm'):
    line = line.strip()
    if not (re.match(r'^CLBLL_L_X92Y\d+\.', line) or re.match(r'^INT_L_X92Y\d+\.', line)):
        continue
    tile, rest = line.split('.', 1)
    tt = tg[tile]['type']

    # LUT INIT row: SLICEL_X1.ALUT.INIT[63:0] = 64'b...
    m = re.match(r'^(SLICEL_X[01])\.([ABCD])LUT\.INIT\[\d+:\d+\] = \d+\'b([01]+)$', rest)
    if m:
        site, lut, bits = m.groups()
        for i, c in enumerate(bits):
            feat = f'{tt}.{site}.{lut}LUT.INIT[{i:02d}]'
            if feat not in R: continue
            (setfeat if c == '1' else clearfeat)(fr, order, tile, feat)
        applied += 1
        continue

    # site rows: SLICEL_X0/1.<CELL>.<SEL> or bitless site pips
    if rest.startswith('SLICEL_X'):
        key = f'{tt}.{rest}'
        if key in R:
            for vf in vfeat.get(tile, []):
                if vf.startswith(rest.rsplit('.', 1)[0] + '.') and vf != rest:
                    vk = f'{tt}.{vf}'
                    if vk in R: clearfeat(fr, order, tile, vk)
            setfeat(fr, order, tile, key); applied += 1
        else:
            print('bitless/unknown site row (ok if always-pip):', line)
        continue

    # site pip: DST.SRC (always-pips need no bits)
    m = re.match(r'^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$', rest)
    if not m:
        print('skip:', line); continue
    dst, src = m.groups()
    key = f'{tt}.{dst}.{src}'
    if key not in R:
        print('MISSING DB row:', key); continue
    # clear vendor pips with the same dst (one-hot mux conflict)
    for vf in vfeat.get(tile, []):
        vm = re.match(r'^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$', vf)
        if vm and vm.group(1) == dst and vm.group(2) != src:
            vk = f'{tt}.{vf}'
            if vk in R:
                clearfeat(fr, order, tile, vk)
    setfeat(fr, order, tile, key)
    applied += 1

# --- repoint the pad D1 route: EE2BEG0 <- LOGIC_OUTS_L18 ---
for vf in list(vfeat.get(TILE_INT, [])):
    if vf.startswith('EE2BEG0.'):
        vk = f'INT_L.{vf}'
        if vk in R: clearfeat(fr, order, TILE_INT, vk)
setfeat(fr, order, TILE_INT, 'INT_L.EE2BEG0.LOGIC_OUTS_L12')
applied += 1

order.sort()
with open('build/tmp/ring9graft.frames', 'w') as fh:
    for a in order:
        fh.write(hex(a) + ' ' + ','.join(f'{x:08x}' for x in fr[a]) + '\n')
print('applied features:', applied)
