#!/usr/bin/env python3
"""tilecmp.py - decode clock-path tiles from .frames files and compare.

Frame addressing per this repo's convention: frame f of a tile lives at
FAR = baseaddr + f*0x65 (0x65 = 101 words per frame).  DB tokens f_wb:
f = frame in tile block, wb = bit index; word = wb//32 (relative to the
tile's own word window), bit = wb%32 (LSB of the word).

Usage: tilecmp.py <framesA> <framesB> <tile> [...]
"""
import json
import sys

DB = 'third_party/prjxray-db/kintex7'
TG = json.load(open(f'{DB}/xc7k325t/tilegrid.json'))


def load_frames(path):
    frames = {}
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        a, words = line.split()
        frames[int(a, 16)] = [int(x, 16) for x in words.split(',')]
    return frames


def segbits(tt):
    out = {}
    for suffix in ('.db', '_sing.db'):
        try:
            path = f'{DB}/segbits_{tt.lower()}{suffix}'
            for line in open(path):
                line = line.strip()
                if not line.startswith(tt + '.'):
                    continue
                feat, _, bits = line.partition(' ')
                toks = []
                for b in bits.split():
                    neg = b.startswith('!')
                    f, wb = map(int, b.lstrip('!').split('_'))
                    toks.append((neg, f, wb // 32, wb % 32))
                out.setdefault(feat, toks)
        except FileNotFoundError:
            pass
    return out


def tile_words(frames, tile):
    info = TG[tile]
    blk = info['bits']['CLB_IO_CLK']
    base = int(blk['baseaddr'], 16)
    off, words = blk['offset'], blk['words']
    out = {}
    for f in range(blk['frames']):
        fr = frames.get(base + f)
        if fr is None:
            continue
        for w in range(words):
            if off + w < len(fr):
                out[(f, off + w)] = fr[off + w]
    return out


def decode(tile, words, db, off):
    b = set()
    for (f, w), v in words.items():
        for bit in range(32):
            if (v >> bit) & 1:
                b.add((f, w, bit))
    matched = []
    for feat, toks in sorted(db.items()):
        if not toks:
            continue
        ok = True
        for neg, f, w, bit in toks:
            present = (f, off + w, bit) in b
            if neg == present:
                ok = False
                break
        if ok:
            matched.append(feat)
    return matched, len(b)


def main():
    fa, fb = load_frames(sys.argv[1]), load_frames(sys.argv[2])
    for tile in sys.argv[3:]:
        tt = TG[tile]['type']
        db = segbits(tt)
        wa, wb_ = tile_words(fa, tile), tile_words(fb, tile)
        off = TG[tile]['bits']['CLB_IO_CLK']['offset']
        ma, na = decode(tile, wa, db, off)
        mb, nb = decode(tile, wb_, db, off)
        print(f'==== {tile} ({tt}) bits A={na} B={nb}')
        for f in sorted(set(ma) | set(mb)):
            a = 'A' if f in ma else ' '
            b = 'B' if f in mb else ' '
            print(f'  [{a}{b}] {f}')


if __name__ == '__main__':
    main()
