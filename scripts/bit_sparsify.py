#!/usr/bin/env python3
"""bit_sparsify.py - rewrite a 7-series .bin with only non-zero frames.

The FX3 loader on this B210-class board cannot take images larger than
~8-10 MB; our uncompressed xc7frames2bit output is 11.44 MB, while the
vendor's compressed/sparse image is 4.58 MB.  Configuration memory is zero
after PROGRAM_B, so frames that are all-zero need not be transmitted.  This
tool keeps the original preamble/epilogue, walks the FDRI payload as
101-word frames, and re-emits only frames that contain data, grouping
consecutive data frames and setting FAR before each run.

Usage: bit_sparsify.py <in.bin> <out.bin>
"""
import struct
import sys

FRAME_WORDS = 101  # 7-series xc7k325t frame payload words


def parse_packets(w):
    """Yield (kind, reg, count, header_index, payload_words)."""
    i = 0
    out = []
    while i < len(w):
        h = w[i]
        t = h >> 29
        if t == 1:
            op = (h >> 27) & 3
            reg = (h >> 13) & 0x3FFF
            cnt = h & 0x7FF
            if op == 2:
                payload = w[i + 1:i + 1 + cnt]
                out.append(("w", reg, cnt, i, payload))
                i += 1 + cnt
            elif op == 1:
                out.append(("r", reg, cnt, i, w[i + 1:i + 1 + cnt]))
                i += 1 + cnt
            else:
                out.append(("n", reg, 0, i, []))
                i += 1
        elif t == 2:
            cnt = h & 0x7FFFFFF
            out.append(("t2", None, cnt, i, w[i + 1:i + 1 + cnt]))
            i += 1 + cnt
        elif t == 0 and h == 0:
            out.append(("zero", None, 0, i, []))
            i += 1
        else:
            out.append(("cmd", None, 0, i, [h]))
            i += 1
    return out


def pack_t1(op, reg, cnt):
    return (1 << 29) | (op << 27) | (reg << 13) | cnt


def pack_t2(cnt):
    return (2 << 29) | cnt


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = open(src, 'rb').read()
    w = list(struct.unpack('>%dI' % (len(d) // 4), d[:len(d) // 4 * 4]))

    # locate FDRI: type1 write to reg 2 whose payload is continued by type2
    pkts = parse_packets(w)
    fdri_idx = None
    for n, p in enumerate(pkts):
        if p[0] == 'w' and p[1] == 2:
            fdri_idx = n
            break
    if fdri_idx is None:
        raise SystemExit("no FDRI packet found")
    fdri = pkts[fdri_idx]
    # gather payload: type1 count words + following type2 blocks
    payload = list(fdri[4])
    idx = fdri_idx + 1
    while idx < len(pkts) and pkts[idx][0] == 't2':
        payload.extend(pkts[idx][4])
        idx += 1
    end_idx = idx  # first packet after FDRI payload

    if len(payload) % FRAME_WORDS:
        raise SystemExit(f"FDRI payload {len(payload)} not a multiple of {FRAME_WORDS}")

    # preamble = everything before FDRI packet, as raw words
    pre = w[:fdri[3]]
    post = w[pkts[end_idx][3]:] if end_idx < len(pkts) else []

    # the FAR value in effect at FDRI time tells us the first frame address
    far = None
    for p in reversed(pkts[:fdri_idx]):
        if p[0] == 'w' and p[1] == 1 and p[4]:
            far = p[4][0]
            break
    if far is None:
        raise SystemExit("no FAR before FDRI")

    # find the last address in preamble after which FDRI starts: FAR is a
    # preamble word; keep preamble but remove the trailing FAR/MASK/CTL block
    # we will re-emit ourselves.  Simpler: emit preamble up to and including
    # CMD WCFG, then our own FAR/FDRI, then epilogue.
    # locate CMD WCFG (reg 4, value 1)
    wcfg_word = None
    for p in pkts[:fdri_idx]:
        if p[0] == 'w' and p[1] == 4 and p[4] and (p[4][0] & 0x1F) == 1:
            wcfg_word = p[3]
            break
    if wcfg_word is None:
        raise SystemExit("no WCFG")
    head = w[:wcfg_word + 2]

    frames = [payload[i:i + FRAME_WORDS] for i in range(0, len(payload), FRAME_WORDS)]
    runs = []
    cur = []
    cur_addr = None
    for n, fr in enumerate(frames):
        if any(fr):
            addr = far + n  # FAR advances one per frame
            if cur and addr == cur_addr + len(cur):
                cur.append(fr)
            else:
                if cur:
                    runs.append((cur_addr, cur))
                cur = [fr]
                cur_addr = addr
    if cur:
        runs.append((cur_addr, cur))

    out = []
    out.extend(head)
    for addr, frs in runs:
        out.append(pack_t1(2, 1, 1))       # write FAR
        out.append(addr)
        words = [x for fr in frs for x in fr]
        first = min(len(words), 0x7FF)
        out.append(pack_t1(2, 2, first))   # write FDRI, first chunk
        out.extend(words[:first])
        rest = words[first:]
        while rest:
            chunk = min(len(rest), 0x7FFFFFF)
            out.append(pack_t2(chunk))
            out.extend(rest[:chunk])
            rest = rest[chunk:]
    out.extend(post)

    data = struct.pack('>%dI' % len(out), *out)
    open(dst, 'wb').write(data)
    kept = sum(len(f) for _, f in runs)
    print(f"{src}: {len(d)} B, {len(frames)} frames, {kept} non-zero frames in {len(runs)} runs")
    print(f"{dst}: {len(data)} B")


if __name__ == '__main__':
    main()
