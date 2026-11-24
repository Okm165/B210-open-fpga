#!/usr/bin/env python3
"""sample_check.py - sample content of an image against known digital signals.

  sample_check.py <image.bin> [--ref <reference.bin>] <mode> [options]

Modes (the AD9361 supplies or returns the signal, no RF is involved):

  --tone         receive path, spectral: the AD9361 replaces the converter
                 output by its digital test tone (fs/32, -6 dBFS).
  --prbs         receive path, bit exact: the AD9361 replaces the converter
                 output by its 16-bit pseudo-random sequence.  With FPGA
                 decimation 1 and the 16-bit wire format every 12-bit code is
                 recovered from the DDC output and checked against the
                 sequence: a dropped, repeated, swapped or altered sample
                 anywhere in the capture is an error.
  --loopback F   transmit path: the host transmits a tone at F on channel 0
                 and 2F on channel 1 (half of full scale), the AD9361 returns
                 its transmit data port on its receive data port.

Everything between the converter and the host is in the path: the FPGA
sample interface, the 2R2T channel demultiplexing, the clock-domain
crossings, the DDC/DUC, the framing and the USB transport.  --mcr above
--rate puts the rate-changing filters in the path as well.

The whole capture is analysed, in overlapping windows, and the worst window
counts.  With --ref the same capture is first taken from the reference image
and this image must match it: level within 0.3 dB, SFDR, SINAD and DC within
3 dB, the phase relation between the two channels within 2 degrees (or one
sample of skew away from it, which the reference image itself shows from
session to session), and in --prbs mode the same channel polarities and gain.  The --prbs requirements
are absolute and do not depend on the reference: zero errors, and both
channels carrying the same word at the same index (the AD9361 sends one word
to both receivers per sample period, so anything else is a one-sample skew
between the channels).

Uses .tools/uhd315/bin/rx_dump (scripts/toolchain.sh uhd).
"""
import argparse
import os
import subprocess
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UHD = os.path.join(ROOT, '.tools', 'uhd315')
SKIP = 4096          # start-of-stream samples left out of every check
GUARD = 6            # half width of the Blackman main lobe, in bins
BIST_TONE, BIST_PRBS = '0x1B', '0x09'
# The capture runs with real-time priority when the account may use it, as
# UHD asks for at these rates; otherwise other work on the host shows up as
# overflows (reported, never hidden).
REALTIME = ['chrt', '-f', '50'] if subprocess.run(
    ['chrt', '-f', '50', 'true'], capture_output=True).returncode == 0 else []


def capture(image, a):
    """Run rx_dump on `image`; returns ([int32 I/Q array per channel], summary line)."""
    out = os.path.join(ROOT, 'build', 'samples')
    os.makedirs(out, exist_ok=True)
    prefix = os.path.join(out, os.path.basename(image).replace('.bin', ''))
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.join(UHD, 'lib'),
               UHD_IMAGES_DIR=os.environ.get('UHD_IMAGES_DIR', '/usr/share/uhd/images'))
    tail = []
    if a.loopback is not None:
        env['UHD_AD936X_LOOPBACK'] = '1'
        tail = [str(a.loopback)]
    else:
        env['UHD_AD936X_BIST'] = BIST_PRBS if a.prbs else BIST_TONE
    dev = (f"type=b200,serial={os.environ.get('SERIAL', '31B92DD')},fpga={image},"
           f"master_clock_rate={a.mcr}")
    files = [f'{prefix}_ch{ch}.sc16' for ch in a.chans.split(',')]
    for f in files:
        if os.path.exists(f):
            os.remove(f)                     # never analyse an earlier capture
    r = subprocess.run(REALTIME + [os.path.join(UHD, 'bin', 'rx_dump'), dev, str(a.rate), a.chans,
                                   str(a.samples), prefix, '100e6', '0', a.otw] + tail,
                       env=env, capture_output=True, text=True, timeout=300)
    line = [l for l in r.stdout.splitlines() if l.startswith('rx_dump:')]
    summary = line[0] if line else 'rx_dump: no result: ' + (r.stdout + r.stderr)[-300:].replace('\n', ' | ')
    if r.returncode != 0:
        return None, summary
    return [np.fromfile(f, dtype=np.int16).astype(np.int32) for f in files], summary


def windows(n_total):
    """(start, length) windows of one power-of-two length covering [SKIP, n_total)."""
    span = n_total - SKIP
    n = 1 << int(np.log2(span / 1.5))
    count = int(np.ceil(span / n)) + 1
    return [(int(s), n) for s in np.linspace(SKIP, n_total - n, count)]


def spectrum_metrics(raw, rate, expect_hz):
    """Worst-window tone metrics of one channel, and its phase at sample 0."""
    x = (raw[0::2] + 1j * raw[1::2]) / 32768.0
    worst = dict(level_lo=np.inf, level_hi=-np.inf, sfdr=np.inf, sinad=np.inf,
                 dc=-np.inf, freq_err=0.0)
    for start, n in windows(len(x)):
        seg = x[start:start + n]
        win = np.blackman(n)
        power = (np.abs(np.fft.fft(seg * win)) / np.sum(win)) ** 2
        idx = np.arange(n)
        k = int(np.argmax(np.where(np.minimum(idx, n - idx) > GUARD, power, 0)))
        dist = np.minimum((idx - k) % n, (k - idx) % n)
        is_dc = np.minimum(idx, n - idx) <= GUARD
        tone = power[dist <= GUARD].sum()
        level = 10 * np.log10(max(tone, 1e-20))
        f = (k if k < n // 2 else k - n) * rate / n
        worst['level_lo'] = min(worst['level_lo'], level)
        worst['level_hi'] = max(worst['level_hi'], level)
        worst['sfdr'] = min(worst['sfdr'], 10 * np.log10(tone / max(power[(dist > GUARD) & ~is_dc].max(), 1e-30)))
        worst['sinad'] = min(worst['sinad'], 10 * np.log10(tone / max(power[dist > GUARD].sum(), 1e-30)))
        worst['dc'] = max(worst['dc'], 10 * np.log10(max(power[is_dc].sum(), 1e-30)))
        if abs(f - expect_hz) > abs(worst['freq_err']):
            worst['freq_err'] = f - expect_hz
    body = x[SKIP:]
    n = np.arange(SKIP, len(x))
    worst['phasor'] = np.sum(body * np.exp(-2j * np.pi * expect_hz * n / rate))
    worst['iq_db'] = 20 * np.log10(np.std(body.real) / max(np.std(body.imag), 1e-12))
    worst['rails'] = int(np.count_nonzero(np.abs(raw) >= 32767))
    return worst


def _bit_reverse12(v):
    r = np.zeros_like(v)
    for b in range(12):
        r |= ((v >> b) & 1) << (11 - b)
    return r


def _parity(v):
    p = np.zeros_like(v)
    while v.any():
        p ^= v & 1
        v = v >> 1
    return p


def prbs_metrics(raw):
    """Decode the AD9361 BIST sequence from one channel of DDC output.

    The device sends, per sample, a 16-bit word W = {I[11:0], bitrev(Q)[3:0]}
    with bitrev(Q)[11:4] == I[7:0], and W' = {W[14:0], ^W[15:4] ^ ^W[2:1]}
    (analogdevicesinc/hdl axi_ad9361_rx_pnmon.v, pn0).  At decimation 1 the
    DDC scales a code k to about 16 * 0.9992 * k, possibly negated (UHD sets
    the second radio's DDC to inverted I and Q), so k is recovered exactly as
    long as the residual stays well under half a code (8 output counts).
    """
    i, q = raw[0::2].astype(np.int64), raw[1::2].astype(np.int64)
    span = float(i.max() - i.min())
    gain = span / (16 * 4095.0)
    best = None
    for sign in (1, -1):
        ki = sign * np.rint(i / (16 * gain)).astype(np.int64)
        kq = sign * np.rint(q / (16 * gain)).astype(np.int64)
        if ki.min() < -2048 or ki.max() > 2047 or kq.min() < -2048 or kq.max() > 2047:
            continue
        rq = _bit_reverse12(kq & 0xFFF)
        word = ((ki & 0xFFF) << 4) | (rq & 0xF)
        nxt = ((word[:-1] << 1) & 0xFFFF) | (_parity((word[:-1] >> 4) & 0xFFF) ^ _parity((word[:-1] >> 1) & 3))
        seq_bad = np.flatnonzero(nxt[SKIP:] != word[1:][SKIP:]) + SKIP
        iq_bad = np.flatnonzero(((ki & 0xFF) != (rq >> 4))[SKIP:]) + SKIP
        m = dict(sign=sign, gain=gain, word=word, checked=len(word) - SKIP - 1,
                 seq_errors=len(seq_bad), iq_errors=len(iq_bad),
                 first_error=int(seq_bad[0]) if len(seq_bad) else None,
                 residual=float(np.abs(i - sign * 16 * gain * ki).max()))
        if best is None or m['seq_errors'] < best['seq_errors']:
            best = m
    if best is None:
        best = dict(sign=0, gain=gain, word=None, checked=0, seq_errors=-1, iq_errors=-1,
                    first_error=None, residual=float('nan'))
    best['rails'] = int(np.count_nonzero(np.abs(raw) >= 32767))
    return best


def measure(image, a):
    """Capture from `image` and return (summary line, per-channel metrics, relation).

    An incomplete capture is not a measurement; it is shown and taken again,
    three times at most.
    """
    for attempt in range(3):
        data, summary = capture(image, a)
        if data is not None:
            break
        print(f'  incomplete capture, attempt {attempt + 1}: {summary}')
    if data is None:
        return summary, None, None
    chans = [int(c) for c in a.chans.split(',')]
    if a.prbs:
        m = [prbs_metrics(d) for d in data]
        rel = None
        if len(m) == 2 and m[0]['word'] is not None and m[1]['word'] is not None:
            w0, w1 = m[0]['word'], m[1]['word']
            rel = next((lag for lag in (0, 1, -1, 2, -2, 3, -3)
                        if np.array_equal(w0[SKIP + 8:-8], np.roll(w1, lag)[SKIP + 8:-8])), None)
        return summary, m, rel
    expect = [a.mcr / 32 if a.loopback is None else a.loopback * (c + 1) for c in chans]
    m = [spectrum_metrics(d, a.rate, f) for d, f in zip(data, expect)]
    rel = None
    if len(m) == 2:
        # invariant to a common time shift: equal tones -> phi0 - phi1,
        # tones F and 2F -> 2 phi0 - phi1
        mult = 1 if a.loopback is None else 2
        rel = float(np.degrees(np.angle(m[0]['phasor'] ** mult * np.conj(m[1]['phasor']))))
    return summary, m, rel


def show(tag, a, summary, m, rel):
    print(f'{tag}{summary}')
    if m is None:
        return
    for ch, c in zip(a.chans.split(','), m):
        if a.prbs:
            where = '' if c['first_error'] is None else f" (first at sample {c['first_error']})"
            print(f"{tag}  ch{ch}: {c['checked']} samples checked, sequence errors {c['seq_errors']}{where}, "
                  f"I/Q consistency errors {c['iq_errors']}, polarity {c['sign']:+d}, "
                  f"gain {c['gain']:.5f}, residual {c['residual']:.2f}/8, rails {c['rails']}")
        else:
            print(f"{tag}  ch{ch}: tone {c['level_lo']:6.2f}..{c['level_hi']:6.2f} dBFS "
                  f"(off by {c['freq_err']:+.0f} Hz)  SFDR {c['sfdr']:5.1f} dB  SINAD {c['sinad']:5.1f} dB  "
                  f"DC {c['dc']:6.1f} dBFS  I/Q {c['iq_db']:+.2f} dB  rails {c['rails']}")
    if rel is not None or len(m) == 2:
        what = 'channel alignment (samples)' if a.prbs else 'channel phase relation (deg)'
        print(f"{tag}  {what}: {'none found' if rel is None else (rel if a.prbs else round(rel, 2))}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('image')
    ap.add_argument('--ref', help='reference image this one must match (the vendor image)')
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--tone', action='store_true')
    mode.add_argument('--prbs', action='store_true')
    mode.add_argument('--loopback', type=float, metavar='TX_TONE_HZ')
    ap.add_argument('--rate', type=float, default=30.72e6)
    ap.add_argument('--mcr', type=float, default=None, help='master clock rate (default: the sample rate)')
    ap.add_argument('--chans', default='0,1')
    ap.add_argument('--otw', default='sc16')
    ap.add_argument('--samples', type=int, default=1 << 21)
    ap.add_argument('--min-sfdr', type=float, default=None,
                    help='absolute SFDR floor in dB (default: 60, or 50 with --ref)')
    a = ap.parse_args()
    a.mcr = a.mcr or a.rate
    if a.min_sfdr is None:
        # With a reference image the comparison with it does the real work, but
        # an absolute floor keeps a board fault that degrades both images from
        # passing: the worst healthy measurement recorded here is 69.8 dB.
        a.min_sfdr = 50.0 if a.ref else 60.0
    if a.prbs and (a.mcr != a.rate or a.otw != 'sc16'):
        sys.exit('--prbs needs decimation 1 (mcr == rate) and the sc16 wire format')

    problems = []
    ref = None
    if a.ref:
        ref = measure(os.path.abspath(a.ref), a)
        show('reference: ', a, *ref)
        if ref[1] is None:
            print('RESULT: INCONCLUSIVE - no capture from the reference image')
            sys.exit(3)
    summary, m, rel = measure(os.path.abspath(a.image), a)
    show('', a, summary, m, rel)
    if m is None:
        print('RESULT: FAIL - capture incomplete')
        sys.exit(1)

    for n, c in enumerate(m):
        ch = a.chans.split(',')[n]
        r = ref[1][n] if ref else None
        if c['rails']:
            problems.append(f"ch{ch}: {c['rails']} values at the rails")
        if a.prbs:
            if c['seq_errors'] != 0 or c['iq_errors'] != 0 or c['checked'] < a.samples // 2:
                problems.append(f"ch{ch}: sequence not received intact")
            # The decoded word only depends on the top 12 bits, so a sample
            # path that is quiet but wrong in amplitude or offset still
            # decodes: the residual is the check that the samples themselves
            # sit on the PRBS levels to within half a 16-bit output code.
            if not (c['residual'] < 8.0):
                problems.append(f"ch{ch}: samples are {c['residual']:.1f} counts off the "
                                f"PRBS levels, limit 8")
            if r and (c['sign'] != r['sign'] or abs(c['gain'] - r['gain']) > 2e-4):
                problems.append(f"ch{ch}: polarity/gain {c['sign']:+d}/{c['gain']:.5f}, "
                                f"reference {r['sign']:+d}/{r['gain']:.5f}")
            continue
        if abs(c['freq_err']) > a.rate / 4096:
            problems.append(f"ch{ch}: tone at the wrong frequency")
        if abs(c['iq_db']) > 0.1:
            problems.append(f"ch{ch}: I and Q amplitudes differ")
        if c['sfdr'] < a.min_sfdr:
            problems.append(f"ch{ch}: SFDR {c['sfdr']:.1f} dB below {a.min_sfdr:.0f}")
        if r:
            if max(abs(c['level_lo'] - r['level_lo']), abs(c['level_hi'] - r['level_hi'])) > 0.3:
                problems.append(f"ch{ch}: level differs from the reference")
            for key, name in (('sfdr', 'SFDR'), ('sinad', 'SINAD')):
                if c[key] < r[key] - 3.0:
                    problems.append(f"ch{ch}: {name} {c[key]:.1f} dB, reference {r[key]:.1f}")
            if c['dc'] > max(r['dc'], -80.0) + 3.0:
                problems.append(f"ch{ch}: DC {c['dc']:.1f} dBFS, reference {r['dc']:.1f}")
    if len(m) == 2:
        if a.prbs and rel != 0:
            problems.append('the two channels are skewed against each other' if rel is not None
                            else 'the two channels do not carry the same sequence')
        if ref and ref[2] is not None:
            if not a.prbs:
                # One sample of skew between the channels moves the relation
                # by `step`.  The reference image itself comes up with or
                # without that skew from session to session, so either is
                # accepted here; --prbs decides the alignment exactly.
                step = 360.0 / 32 if a.loopback is None else 360.0 * 2 * a.loopback / a.mcr
                d = min(abs((rel - ref[2] - k * step + 180.0) % 360.0 - 180.0) for k in (-1, 0, 1))
                if d > 2.0:
                    problems.append(f'channel phase relation {rel:.1f} deg, reference {ref[2]:.1f} '
                                    f'(one sample of skew is {step:.1f})')
    for p in problems:
        print('  problem: ' + p)
    print('RESULT: ' + ('FAIL' if problems else 'PASS'))
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
