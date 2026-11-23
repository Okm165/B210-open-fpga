#!/usr/bin/env python3
"""tile_decode.py - decode specific clock-path tiles from two .bin files
using the openXC7 prjxray-db (kintex7 xc7k325t tilegrid + segbits).

Usage: tile_decode.py <binA> <binB> <tile> [<tile> ...]
Prints the decoded features of each tile for both bitstreams.
"""
import json
import struct
import sys
import os

ROOT = 'third_party/prjxray-db-openxc7/kintex7'
GRID = json.load(open(f'{ROOT}/xc7k325t/tilegrid.json'))
FRAME_WORDS = 101


def load_frames(path):
    d = open(path, 'rb').read()
    w = struct.unpack('>%dI' % (len(d) // 4), d[:len(d) // 4 * 4])
    i = 0
    payload = []
    while i < len(w):
        h = w[i]
        t = h >> 29
        if t == 1 and ((h >> 27) & 3) == 2:
            reg = (h >> 13) & 0x3FFF
            cnt = h & 0x7FF
            if reg == 2:
                payload += list(w[i + 1:i + 1 + cnt])
                i += 1 + cnt
                while i < len(w) and (w[i] >> 29) == 2:
                    c = w[i] & 0x7FFFFFF
                    payload += list(w[i + 1:i + 1 + c])
                    i += 1 + c
                continue
            i += 1 + cnt
            continue
        if t == 2:
            i += 1 + (h & 0x7FFFFFF)
            continue
        i += 1
    return payload


def segbits(tile_type):
    name = tile_type.lower()
    p = f'{ROOT}/segbits_{name}.db'
    if not os.path.exists(p):
        return {}
    out = {}
    for line in open(p):
        line = line.strip()
        if not line or not line.startswith(tile_type + '.'):
            continue
        feat, _, bits = line.partition(' ')
        toks = []
        for b in bits.split():
            neg = b.startswith('!')
            b = b.lstrip('!')
            w, bit = map(int, b.split('_'))
            toks.append((neg, w, bit))
        out[feat] = toks
    return out


def tile_bits(tile, frames):
    info = GRID[tile]
    fset = set()
    for bus, blk in info['bits'].items():
        base = int(blk['baseaddr'], 16)
        off = blk['offset']
        words = blk['words']
        for n in range(words):
            f = frames[base + n]
            for bit in range(32):
                if (f >> (31 - bit)) & 1:
                    fset.add((off + n, bit))
    return fset


def decode(tile, frames):
    info = GRID[tile]
    tt = info['type']
    db = segbits(tt)
    if not db:
        return tt, [], 0
    b = tile_bits(tile, frames)
    matched, partial = [], 0
    for feat, toks in db.items():
        if not toks:
            continue
        ok = True
        for neg, w, bit in toks:
            present = (w, bit) in b
            if neg == present:  # '!' bit must be absent, normal bit must be present
                ok = False
                break
        if ok:
            matched.append(feat)
    # unknown set bits (present but no db row matches fully)
    known = set()
    for feat, toks in db.items():
        known |= {(w, bit) for neg, w, bit in toks}
    unknown = sum(1 for x in b if x not in known)
    return tt, matched, unknown


def main():
    framesA = load_frames(sys.argv[1])
    framesB = load_frames(sys.argv[2])
    for tile in sys.argv[3:]:
        if tile not in GRID:
            print(f'{tile}: not in tilegrid')
            continue
        tt, fa, ua = decode(tile, framesA)
        _, fb, ub = decode(tile, framesB)
        print(f'==== {tile} ({tt}) unknown_bits A={ua} B={ub}')
        for f in sorted(set(fa) | set(fb)):
            a = 'A' if f in fa else ' '
            bb = 'B' if f in fb else ' '
            print(f'  [{a}{bb}] {f}')


if __name__ == '__main__':
    main()
