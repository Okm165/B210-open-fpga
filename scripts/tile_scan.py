#!/usr/bin/env python3
"""tile_scan.py - locate a tile's frames in a .bin by pattern matching, then
decode ALL db features for that tile from the raw bits.

Usage: tile_scan.py <bin> <tile_type> <fasm_file> <tile_name>
  fasm_file/tile_name supply the expected feature set used only to locate the
  window; the printed decode comes from the raw bits alone.
"""
import json
import struct
import sys
import os

ROOT = 'third_party/prjxray-db-openxc7/kintex7'
GRID = json.load(open(f'{ROOT}/xc7k325t/tilegrid.json'))


def load_payload(path):
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
    p = f'{ROOT}/segbits_{tile_type.lower()}.db'
    if not os.path.exists(p):
        return {}
    out = {}
    for line in open(p):
        line = line.strip()
        if not line.startswith(tile_type + '.'):
            continue
        feat, _, bits = line.partition(' ')
        toks = []
        for b in bits.split():
            neg = b.startswith('!')
            w, bit = map(int, b.lstrip('!').split('_'))
            toks.append((neg, w, bit))
        out[feat] = toks
    return out


def fasm_features(path, tile):
    out = set()
    for line in open(path):
        line = line.split('#')[0].strip()
        if line.startswith(tile + '.'):
            out.add(line)
    return out


def main():
    path, ttype, fasm, tile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    db = segbits(ttype)
    # tile frame count from tilegrid
    nf = max(b['frames'] for b in GRID[tile]['bits'].values())
    expected = fasm_features(fasm, tile)
    exp_toks = []
    for f in expected:
        key = ttype + '.' + f.split('.', 1)[1]
        if key in db:
            exp_toks += db[key]
    payload = load_payload(path)

    best, best_score, best_base = None, -1, None
    for base in range(0, len(payload) - nf):
        score = 0
        for neg, w, bit in exp_toks:
            if w >= nf:
                continue
            word = payload[base + w]
            on = (word >> (bit % 32)) & 1
            if (not neg and on) or (neg and not on):
                score += 1
            else:
                score = -1
                break
        if score > best_score:
            best_score, best_base = score, base
    print(f'{tile}: best base frame {best_base} score {best_score}/{len(exp_toks)} (payload {len(payload)} frames, tile {nf} frames)')

    # decode from raw bits at best_base
    b = set()
    for n in range(nf):
        word = payload[best_base + n]
        for bit in range(32):
            if (word >> bit) & 1:
                b.add((n, 31 - bit))
    for feat, toks in sorted(db.items()):
        if not toks:
            continue
        ok = True
        for neg, w, bit in toks:
            present = (w, bit // 32, 31 - (bit % 32)) in b
            if neg == present:
                ok = False
                break
        if ok:
            matched.append(feat)
    known = set()
    for toks in db.values():
        known |= {(w, bit // 32, bit % 32) for neg, w, bit in toks}
    unknown = sorted(x for x in b if x not in known)
    print(f'  matched features: {len(matched)}')
    for f in matched:
        print('   ', f)
    print(f'  bits not covered by any db row: {len(unknown)}')
    for x in unknown[:40]:
        print('    ?', x)


if __name__ == '__main__':
    main()
