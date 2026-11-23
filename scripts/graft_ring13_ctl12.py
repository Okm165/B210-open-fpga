#!/usr/bin/env python3
"""Graft diag_ring13 (4-inverter ring in vendor-empty CLBLM_R_X37Y119) into
the WORKING vendor bitstream, feeding GPIF_D[26]'s ODDR D1 through the
documented crossing: INT_R_X95Y115.IMUX34 <- LOGIC_OUTS9.

Vendor's IFCLK self-toggle keeps PCLK alive; the observable is bit 26 of the
FX3 IN-endpoint data (ring toggling = varying bit, constant tap = static bit).
"""
import json, os, re, sys

DB = 'third_party/prjxray-db/kintex7'
tg = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))

R = {}
for tt in ('clblm_r', 'int_r', 'int_l'):
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

vfeat = {}
for line in open('build/vendor.fasm'):
    m = re.match(r'^([A-Za-z0-9_]+_X\d+Y\d+)\.(\S+)$', line.strip())
    if m: vfeat.setdefault(m.group(1), []).append(m.group(2))

applied = 0
for line in open('build/fpga/ring2/pnr/diag_ring13.fasm'):
    line = line.strip()
    tile = line.split('.', 1)[0]
    if tile not in ('CLBLM_R_X37Y119', 'INT_R_X37Y119'):
        continue
    tt = tg[tile]['type']
    rest = line.split('.', 1)[1]
    m = re.match(r'^(SLICEM_X[01]|SLICEL_X[01])\.[ABCD]LUT\.INIT\[\d+:\d+\] = \d+\'b([01]+)$', rest)
    if m:
        site, bits = m.groups()
        lut = re.search(r'\.([ABCD])LUT\.INIT', rest).group(1)
        for i, c in enumerate(bits):
            feat = f'{tt}.{site}.{lut}LUT.INIT[{i:02d}]'
            if feat not in R: continue
            (setfeat if c == '1' else clearfeat)(fr, order, tile, feat)
        applied += 1
        continue
    if rest.startswith('SLICE'):
        key = f'{tt}.{rest}'
        if key in R:
            base_cell = rest.rsplit('.', 1)[0]
            for vf in vfeat.get(tile, []):
                if vf.startswith(base_cell + '.') and vf != rest:
                    vk = f'{tt}.{vf}'
                    if vk in R: clearfeat(fr, order, tile, vk)
            setfeat(fr, order, tile, key); applied += 1
        continue
    m = re.match(r'^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$', rest)
    if not m: continue
    dst, src = m.groups()
    key = f'{tt}.{dst}.{src}'
    if key not in R:   # always-pips need no bits
        continue
    for vf in vfeat.get(tile, []):
        vm = re.match(r'^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)$', vf)
        if vm and vm.group(1) == dst and vm.group(2) != src:
            vk = f'{tt}.{vf}'
            if vk in R: clearfeat(fr, order, tile, vk)
    setfeat(fr, order, tile, key); applied += 1

# repoint the GPIF_D[26] data crossing
T = 'INT_R_X95Y109'
for vf in list(vfeat.get(T, [])):
    if vf.startswith('IMUX34.'):
        vk = f'INT_R.{vf}'
        if vk in R: clearfeat(fr, order, T, vk)
setfeat(fr, order, T, 'INT_R.IMUX34.LOGIC_OUTS9')
applied += 1

order.sort()
with open('build/tmp/ring13ctl12.frames', 'w') as fh:
    for a in order:
        fh.write(hex(a) + ' ' + ','.join(f'{x:08x}' for x in fr[a]) + '\n')
print('applied features:', applied)
