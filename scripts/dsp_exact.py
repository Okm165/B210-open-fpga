#!/usr/bin/env python3
"""dsp_exact.py - does the FPGA compute what the RTL computes, bit for bit?

  dsp_exact.py rx   <capture prefix> --decim N  [--mcr 30.72e6] [--chans 0,1]
  dsp_exact.py loop <capture prefix> --interp N [--chans 0,1] [--dac round|truncate]

A tone shows that a datapath is roughly right.  A deterministic input shows
whether it is exactly right: every captured sample is compared with what the
repository's RTL computes from the same input, in Icarus Verilog.

  rx    <prefix>_ch<n>.sc16 was captured with the AD9361 sending its 16-bit
        pseudo-random BIST sequence in place of the converter samples
        (UHD_AD936X_BIST=0x09, scripts/rx_dump.cpp).  The sequence is known,
        its phase and the phase of the decimation are not; they are found.
  loop  <prefix>_ch<n>.sc16 was captured with the AD9361 in digital loopback
        while the host transmitted <prefix>_tx_ch<n>.sc16 over and over
        (scripts/rx_dump.cpp).  The delay through the loop is not known; it
        is found.

Files are interleaved little-endian int16 I,Q, as the FPGA sent them in the
sc16 wire format (UHD copies sc16 to sc16 without scaling, I in the upper
half of the word: host/lib/convert/convert_common.hpp:112, :143).

What is simulated.  tests/dspx_rx.v and tests/dspx_loop.v instantiate
src/rtl/dsp ddc_chain and duc_chain and what radio_legacy.v / b200.v put
between them and the pins: on receive the 12-bit pin word padded with zeros
to 24 bits; on transmit dac_slice (24 to 12 bits, round half even, saturate).
--dac truncate takes tx_fe[23:12] instead, which is what the upstream Ettus
radio_legacy.v does.  b200_io.v moves the 12-bit words unchanged.

Register values.  They are derived here the way UHD 3.15 derives them and
printed with their source lines (.tools/src/uhd/host/lib/usrp/...).  Channel
n is radio n (b200_io_impl.cpp:275).  --override NAME=VALUE replaces one
(rx_freq, rx_scale, rx_rate, rx_mux, tx_freq, tx_scale, tx_rate), which is
how a wrong value is shown to be noticed.

The comparison.  The last stage of the receive chain, round_sd, is a
first-order error-feedback rounder from 33 to 16 bits.  Its error state is
not cleared when streaming starts: on a board it carries everything received
since reset, so no simulation from reset can reproduce a capture.  Everything
in front of it has finite memory, so its 33-bit input is periodic with the
input (65535 samples of the PN sequence, one block of the transmit data).
The RTL simulation therefore provides one period of the rounder's input; it
is cached under build/tmp/dspx/cache.  The rounder itself is applied here, by
a model that is checked against the RTL rounder on every sample of every
simulation, and the unknown state is carried as the set of all states that
are still consistent with the capture: the set starts as every state the
rounder can hold and each captured sample narrows it.  A sample that no
state in the set can produce is a mismatch.  One wrong count in one sample
empties the set within a sample or two, so this is a bit-for-bit comparison
of every sample after --skip, not a statistical one.

After a mismatch, tracking continues, and the mismatch is classified by what
the rounder does next.  If the following samples are those of a rounder that
produced the expected value, the sample was computed right and altered
afterwards (a bit lost between the DSP and the file): reported as an isolated
sample, with the bits that differ.  If the rounder is in another state
afterwards, what went into it was different (a corrupted input sample, or a
datapath that computes something else): reported as bursts with position and
size, or as SYSTEMATIC when they do not stop.  As a closing check each
component is also recomputed explicitly from one definite rounder state and
compared with the capture sample by sample.

Exit status 0 and `RESULT: PASS` only if no channel has any mismatch.
"""
import argparse
import hashlib
import math
import os
import subprocess
import sys
import time

import numpy as np

class Fail(Exception):
    """The comparison cannot be made; reported as RESULT: FAIL."""


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRATCH = os.path.join(ROOT, 'build', 'tmp', 'dspx')
CACHE = os.path.join(SCRATCH, 'cache')
MAX_JOBS = 6

PN_PERIOD = 65535
SETTLE = 600            # output samples of a simulation left to its start-up
BURST_GAP = 256         # mismatches closer than this are one burst
DENSE = 400             # this many mismatches and the scan stops counting one by one

# ----------------------------------------------------------------------------
# What UHD programs (UHD 3.15, .tools/src/uhd/host/lib/usrp/)
# ----------------------------------------------------------------------------

def _ceil_log2(x):
    # template ceil_log2: std::ceil(std::log(num) / std::log(T(2)))
    return math.ceil(math.log(x) / math.log(2.0))


def _iround(x):
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def uhd_rx_regs(decim, radio):
    """SR_RX_DSP + 0..3 as rx_dsp_core_3000 writes them for a B200."""
    cic, hb0, hb1 = decim, 0, 0
    if cic % 2 == 0:                    # cores/rx_dsp_core_3000.cpp:146
        hb0, cic = 1, cic // 2
    if cic % 2 == 0:                    # :150
        hb1, cic = 1, cic // 2
    rate_pow = float(cic & 0xFF) ** 4   # :203
    adjust = 2.0 ** _ceil_log2(rate_pow) / (1.648 * rate_pow)        # :218
    return [
        ('rx_freq', 0,
         'cores/rx_dsp_core_3000.cpp:253 set_freq(0): tune_request_t(100e6) is policy AUTO, '
         'the AD9361 LO lands on 100e6 exactly (ad9361_device.cpp:1317: 64*100e6/80e6 = 80, '
         'no fraction), so the DSP gets actual - requested = 0 (multi_usrp.cpp:334)'),
        ('rx_scale', _iround((1 << 16) * adjust / 1.0),
         'cores/rx_dsp_core_3000.cpp:231,239 update_scalar: iround(2^16 * 2^ceil_log2(cic^4) '
         '/ (1.648 * cic^4)); B200 uses 1 << 16; sc16 on the wire: no extra scaling (:275)'),
        ('rx_rate', (hb0 << 9) | (hb1 << 8) | (cic & 0xFF),
         'cores/rx_dsp_core_3000.cpp:161 set_host_rate: (hb0 << 9) | (hb1 << 8) | cic, '
         'cic = decimation with up to two factors of 2 taken out (:146-:153)'),
        ('rx_mux', 0xC if radio == 1 else 0x0,
         'b200/b200_impl.cpp:884 set_mux(dspno == 1 ? "IbQb" : "IQ"); "IbQb" inverts I and Q: '
         'INVERT_I (1 << 3) | INVERT_Q (1 << 2) (cores/rx_dsp_core_3000.cpp:32,33,80-85)'),
    ]


def uhd_tx_regs(interp):
    """SR_TX_DSP + 0..2 as tx_dsp_core_3000 writes them."""
    cic, hb0, hb1 = interp, 0, 0
    if cic % 2 == 0:                    # cores/tx_dsp_core_3000.cpp:85
        hb0, cic = 1, cic // 2
    if cic % 2 == 0:                    # :89
        hb1, cic = 1, cic // 2
    rate_pow = float(cic & 0xFF) ** 3   # :109
    adjust = 2.0 ** _ceil_log2(rate_pow) / (1.648 * rate_pow)        # :114
    return [
        ('tx_freq', 0,
         'cores/tx_dsp_core_3000.cpp:142 set_freq(0): as on receive, the LO is exact, '
         'so the DSP frequency is 0 (multi_usrp.cpp:334,337)'),
        ('tx_scale', _iround((1 << 16) * adjust / 1.0),
         'cores/tx_dsp_core_3000.cpp:126,129 update_scalar: iround(2^16 * 2^ceil_log2(cic^3) '
         '/ (1.648 * cic^3)); sc16 on the wire: no extra scaling (:161)'),
        ('tx_rate', (hb1 << 9) | (hb0 << 8) | (cic & 0xFF),
         'cores/tx_dsp_core_3000.cpp:94 set_host_rate: (hb1 << 9) | (hb0 << 8) | cic; '
         'the transmit core has no mux register, so nothing differs on the second radio'),
    ]


def apply_overrides(regs, overrides):
    out = []
    for name, value, why in regs:
        if name in overrides:
            out.append((name, overrides[name], 'OVERRIDDEN on the command line (UHD writes 0x%x)' % value))
        else:
            out.append((name, value, why))
    return out


def show_regs(title, regs):
    print(title)
    for name, value, why in regs:
        print('  %-8s = 0x%08x (%d)\n             %s' % (name, value, value, why))


# ----------------------------------------------------------------------------
# The rounder (src/rtl/dsp/round_sd.v, WIDTH_IN 33, WIDTH_OUT 16)
# ----------------------------------------------------------------------------
#
#   sum   = clip33(in + err)                      add2_and_clip_reg
#   out   = sum[32:17] + sum[16]                  round, to nearest; no +1 when
#                                                 sum is positive with sum[31:17] all ones
#   err   = sum - (out << 17)                     18 bits, fed back
#
# Away from the rails this is: out = floor((in + err + 2^16) / 2^17), and the
# new err lies in [-2^16, 2^16).

E_MIN, E_MAX = -(1 << 16), (1 << 17) - 1       # every error the rounder can hold
P_MIN, P_MAX = -(1 << 16), (1 << 16) - 1       # after an ordinary step
TOP, BOT = (1 << 32) - 1, -(1 << 32)
# Inputs this close to a rail may clip or meet the no-round-up rule: they are
# stepped one by one.  Everything else is handled in bulk.
RAIL_HI, RAIL_LO = (1 << 32) - (1 << 18), -(1 << 32) + (1 << 17)


def rounder_step(x, e):
    """One sample through round_sd: (out, next error)."""
    s = x + e
    if s > TOP:
        s = TOP
    elif s < BOT:
        s = BOT
    up = (s >> 16) & 1
    if s >= 0 and ((s >> 17) & 0x7FFF) == 0x7FFF:
        up = 0
    out = (s >> 17) + up
    return out, s - (out << 17)


def rounder_run(x, e=0):
    """The whole array through round_sd from error state e (bulk where it can)."""
    x = np.asarray(x, dtype=np.int64)
    out = np.empty(len(x), dtype=np.int64)
    rails = np.flatnonzero((x >= RAIL_HI) | (x < RAIL_LO))
    pos = 0
    for r in list(rails) + [len(x)]:
        if r > pos:
            s = e + np.cumsum(x[pos:r])
            # s[k] - 2^17 * (outputs so far) must stay in [-2^16, 2^16):
            # the running total of the outputs is the rounded running sum
            tot = (s + (1 << 16)) >> 17
            out[pos:r] = np.diff(tot, prepend=0)
            e = int(s[-1] - (int(tot[-1]) << 17))
        if r < len(x):
            out[r], e = rounder_step(int(x[r]), e)
        pos = r + 1
    return out, e


class Tracker:
    """The set of rounder states still consistent with a capture.

    The rounder is monotonic in its state: a larger error never gives a
    smaller output or a smaller next error.  So the set of states that
    produce the captured outputs is always an interval [lo, hi], and it is
    enough to carry its two ends.
    """

    def __init__(self, pre, cap):
        self.pre = np.asarray(pre, dtype=np.int64)
        self.cap = np.asarray(cap, dtype=np.int64)
        self.step = self.pre - (self.cap << 17)             # change of the error per sample
        self.rail = (self.pre >= RAIL_HI) | (self.pre < RAIL_LO)
        self.rails = np.flatnonzero(self.rail)

    def expected(self, n, lo, hi):
        a = rounder_step(int(self.pre[n]), lo)[0]
        b = rounder_step(int(self.pre[n]), hi)[0]
        return (a, b)

    def _rail_sample(self, n, lo, hi):
        """Narrow [lo, hi] by sample n, stepping exactly.  None if impossible."""
        x, want = int(self.pre[n]), int(self.cap[n])
        if rounder_step(x, lo)[0] > want or rounder_step(x, hi)[0] < want:
            return None
        a, b = lo, hi                       # smallest state whose output reaches `want`
        while a < b:
            m = (a + b) // 2
            if rounder_step(x, m)[0] >= want:
                b = m
            else:
                a = m + 1
        first = a
        a, b = first, hi                    # largest state whose output is still `want`
        while a < b:
            m = (a + b + 1) // 2
            if rounder_step(x, m)[0] <= want:
                a = m
            else:
                b = m - 1
        last = a
        if rounder_step(x, first)[0] != want:
            return None
        return rounder_step(x, first)[1], rounder_step(x, last)[1]

    def run(self, start, stop, lo=E_MIN, hi=E_MAX, block=1 << 16):
        """Track from `start`.  Returns (first impossible sample or None, lo, hi)
        where lo, hi is the state set before that sample (or at `stop`)."""
        n = start
        while n < stop:
            if self.rail[n]:
                got = self._rail_sample(n, lo, hi)
                if got is None:
                    return n, lo, hi
                lo, hi = got
                n += 1
                continue
            end = min(stop, n + block)
            k = np.searchsorted(self.rails, n)
            if k < len(self.rails) and self.rails[k] < end:
                end = int(self.rails[k])
            d = np.cumsum(self.step[n:end])
            # error after sample j is e + d[j]; it must be in [P_MIN, P_MAX]
            los = np.maximum(lo, P_MIN - np.minimum.accumulate(d))
            his = np.minimum(hi, P_MAX - np.maximum.accumulate(d))
            bad = np.flatnonzero(los > his)
            if len(bad):
                j = int(bad[0])
                if j:
                    lo, hi = int(los[j - 1] + d[j - 1]), int(his[j - 1] + d[j - 1])
                return n + j, lo, hi
            lo, hi = int(los[-1] + d[-1]), int(his[-1] + d[-1])
            n = end
        return None, lo, hi


def compare(pre_i, pre_q, cap_i, cap_q, start):
    """Bit-for-bit comparison of one channel from sample `start`.

    Returns a dict:
      compared  samples compared
      events    [(sample, component, (expected lo, expected hi), got, kind)], sorted.
                kind 'word': the sample differs but every sample after it,
                up to the next mismatch, is that of a rounder that produced
                the expected value - the word was computed right and altered
                afterwards (or the rounder's input was off by a whole number
                of output counts, which no later sample can tell apart).
                kind 'state': the rounder is in another state afterwards,
                i.e. what went into it was different.
      dense     True if the scan gave up counting one by one
      explicit  per component, the outcome of the closing check: the RTL
                values run through the rounder from one definite state,
                compared with the capture sample by sample (None if it was
                not possible: samples at the rails, or a 'state' event)
    """
    n_total = len(cap_i)
    events = []
    dense = False
    explicit = {}
    for comp, pre, cap in (('I', pre_i, cap_i), ('Q', pre_q, cap_q)):
        tr = Tracker(pre, cap)
        n, lo, hi = start, E_MIN, E_MAX
        mine = []
        clean = True                      # one state trajectory from start to end
        carried = None                    # index of the last event the state was carried across
        while n < n_total:
            bad, lo, hi = tr.run(n, n_total, lo, hi)
            if bad is None:
                break
            if carried is not None:
                # The state was carried across the event at `carried` as if
                # the expected value had been produced there.  If any state
                # at all, picked up after that event, explains everything up
                # to and including this sample, then it was the rounder's
                # state that changed there, and this sample is fine.
                again, lo3, hi3 = tr.run(carried + 1, bad + 1, E_MIN, E_MAX)
                if again is None:
                    mine[-1] = mine[-1][:4] + ('state',)
                    clean = False
                    carried = None
                    n, lo, hi = bad + 1, lo3, hi3
                    continue
            exp = tr.expected(bad, lo, hi)
            if exp[0] == exp[1]:
                kind = 'word'
                lo = rounder_step(int(pre[bad]), lo)[1]
                hi = rounder_step(int(pre[bad]), hi)[1]
                carried = bad
            else:
                kind = 'state'
                lo, hi = E_MIN, E_MAX
                clean = False
                carried = None
            mine.append((bad, comp, exp, int(cap[bad]), kind))
            if len(mine) >= DENSE:
                dense = True
                break
            n = bad + 1
        events += mine
        # Closing check, explicit: one definite rounder state at `start`, the
        # whole RTL sequence through the rounder, compared sample by sample.
        if clean and not dense and not tr.rail[start:].any():
            want = cap[start:].copy()
            for ev in mine:
                want[ev[0] - start] = ev[2][0]
            e0 = lo - int(np.sum(pre[start:] - (want << 17)))
            out, _ = rounder_run(pre[start:], e0)
            diff = np.flatnonzero(out != cap[start:]) + start
            explicit[comp] = (e0, len(out), [int(d) for d in diff],
                              sorted(ev[0] for ev in mine) == [int(d) for d in diff])
        else:
            explicit[comp] = None
    events.sort()
    return dict(compared=n_total - start, events=events, dense=dense, explicit=explicit)


def bursts_of(events):
    """Group mismatch events into bursts: [(first, last, events in it)]."""
    out = []
    for ev in events:
        if out and ev[0] - out[-1][1] <= BURST_GAP:
            out[-1][1] = ev[0]
            out[-1][2].append(ev)
        else:
            out.append([ev[0], ev[0], [ev]])
    return out


# ----------------------------------------------------------------------------
# Running the RTL
# ----------------------------------------------------------------------------

def _sources():
    with open(os.path.join(ROOT, 'scripts', 'sources.txt')) as f:
        listed = [l.strip() for l in f if l.startswith('src/')]
    need = [s for s in listed if s.startswith('src/rtl/dsp/')]
    need += ['src/rtl/control/setting_reg.v', 'src/ip/xilinx_macros.v',
             'tests/sim/xilinx_prim_sim.v']           # DSP48E1 model for the transmit halfbands
    return [os.path.join(ROOT, s) for s in need]


def _digest(paths, extra=''):
    h = hashlib.sha1(extra.encode())
    for p in paths:
        with open(p, 'rb') as f:
            h.update(hashlib.sha1(f.read()).digest())
    return h.hexdigest()[:16]


def build_bench(name):
    """Compile tests/<name>.v with the repository's DSP sources; returns (vvp, digest)."""
    bench = os.path.join(ROOT, 'tests', name + '.v')
    srcs = _sources()
    dig = _digest([bench] + srcs)
    vvp = os.path.join(SCRATCH, '%s-%s.vvp' % (name, dig))
    if not os.path.exists(vvp):
        os.makedirs(SCRATCH, exist_ok=True)
        r = subprocess.run(['iverilog', '-g2005', '-s', name, '-o', vvp + '.part', bench] + srcs,
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit('iverilog failed:\n' + r.stderr[-2000:])
        os.replace(vvp + '.part', vvp)
    return vvp, dig


def run_jobs(vvp, jobs, max_jobs):
    """Run [(plusargs, outfile)] through vvp, at most max_jobs at a time."""
    pending = list(jobs)
    running = []
    while pending or running:
        while pending and len(running) < max_jobs:
            args, out = pending.pop(0)
            p = subprocess.Popen(['vvp', '-n', vvp] + args + ['+OUT=' + out],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            running.append((p, out))
        for item in list(running):
            p, out = item
            if p.poll() is not None:
                running.remove(item)
                msg = p.stdout.read()
                if p.returncode != 0 or not os.path.exists(out) or 'required' in msg:
                    sys.exit('simulation failed: ' + msg[-1000:])
        time.sleep(0.05)


def _signed33(v):
    return v - (1 << 33) if v >= (1 << 32) else v


def _signed16(v):
    return v - (1 << 16) if v >= (1 << 15) else v


def read_dump(path, key_base):
    """A bench dump: key, sample I, sample Q, rounder input I, rounder input Q."""
    key, si, sq, pi, pq = [], [], [], [], []
    with open(path) as f:
        for line in f:
            a, b, c, d = line.split()
            key.append(int(a, key_base))
            s = int(b, 16)
            si.append(_signed16(s >> 16))
            sq.append(_signed16(s & 0xFFFF))
            pi.append(_signed33(int(c, 16)))
            pq.append(_signed33(int(d, 16)))
    return (np.array(key, dtype=np.int64), np.array(si, dtype=np.int64), np.array(sq, dtype=np.int64),
            np.array(pi, dtype=np.int64), np.array(pq, dtype=np.int64))


def check_rounder_model(dumps):
    """The rounder model above against the RTL rounder, on everything simulated."""
    n = 0
    for key, si, sq, pi, pq in dumps:
        for s, p in ((si, pi), (sq, pq)):
            out, _ = rounder_run(p, 0)
            if not np.array_equal(out, s):
                bad = int(np.flatnonzero(out != s)[0])
                sys.exit('internal error: the rounder model differs from round_sd.v at '
                         'simulated sample %d (model %d, RTL %d)' % (bad, out[bad], s[bad]))
            n += len(s)
    return n


def fill_table(period, dumps):
    """Rounder inputs by position in the input period, from steady-state samples."""
    ti = np.zeros(period, dtype=np.int64)
    tq = np.zeros(period, dtype=np.int64)
    have = np.zeros(period, dtype=bool)
    for key, si, sq, pi, pq in dumps:
        k, a, b = key[SETTLE:], pi[SETTLE:], pq[SETTLE:]
        seen = have[k]
        if np.any(ti[k[seen]] != a[seen]) or np.any(tq[k[seen]] != b[seen]):
            sys.exit('internal error: the simulated rounder input is not periodic with the input')
        # the same position twice within one dump must agree too
        order = np.argsort(k, kind='stable')
        ks = k[order]
        same = np.flatnonzero(ks[1:] == ks[:-1])
        if np.any(a[order][same] != a[order][same + 1]) or np.any(b[order][same] != b[order][same + 1]):
            sys.exit('internal error: the simulated rounder input is not periodic with the input')
        ti[k], tq[k], have[k] = a, b, True
    return ti, tq, have


# ----------------------------------------------------------------------------
# The PN sequence of the AD9361 (analogdevicesinc/hdl axi_ad9361_rx_pnmon.v, pn0)
# ----------------------------------------------------------------------------

def pn_sequence():
    """words[k], k = 0..65534, from 0xFFFF; index[word] = k."""
    words = np.empty(PN_PERIOD, dtype=np.int64)
    w = 0xFFFF
    for k in range(PN_PERIOD):
        words[k] = w
        bit = (bin((w >> 4) & 0xFFF).count('1') ^ bin((w >> 1) & 3).count('1')) & 1
        w = ((w << 1) & 0xFFFF) | bit
    assert w == 0xFFFF
    index = np.full(1 << 16, -1, dtype=np.int64)
    index[words] = np.arange(PN_PERIOD)
    return words, index


# ----------------------------------------------------------------------------
# Finding the capture in the period
# ----------------------------------------------------------------------------

def best_offsets(seg, ref, keep=8):
    """Offsets k at which seg[n] ~ ref[(k + n) mod len(ref)], best first.

    Least squares over the whole segment, by FFT: sum |seg - ref|^2
    = sum |seg|^2 + sum |ref window|^2 - 2 Re sum conj(seg) ref.
    """
    q = len(ref)
    m = min(len(seg), q)
    s = np.zeros(q, dtype=np.complex128)
    s[:m] = seg[:m]
    corr = np.fft.ifft(np.fft.fft(ref) * np.conj(np.fft.fft(s)))
    power = np.abs(ref) ** 2
    csum = np.concatenate(([0.0], np.cumsum(np.concatenate((power, power[:m])))))
    window = csum[m:m + q] - csum[:q]
    err = np.sum(np.abs(seg[:m]) ** 2) + window - 2.0 * corr.real
    order = np.argsort(err)[:keep]
    return [(int(k), float(err[k] / m)) for k in order]


def load_capture(path):
    raw = np.fromfile(path, dtype='<i2').astype(np.int64)
    return raw[0::2], raw[1::2]


def report_channel(name, res, skip, align_text, first_clean, cap_i, cap_q):
    """Print one channel's result; returns True if it has no mismatch."""
    ev = res['events']
    print('%s: alignment: %s' % (name, align_text))
    print('%s: %d samples compared (from sample %d), %s%d mismatch%s' % (
        name, res['compared'], skip, 'at least ' if res['dense'] else '', len(ev),
        '' if len(ev) == 1 else 'es'))
    for comp in ('I', 'Q'):
        ex = res['explicit'][comp]
        if ex is not None:
            e0, count, diff, agrees = ex
            print('%s: %s, explicit: round_sd started in error state %d at sample %d reproduces the '
                  'capture in %d of %d samples%s' % (name, comp, e0, skip, count - len(diff), count,
                                                   '' if agrees else '  (INTERNAL DISAGREEMENT with the tracking)'))
    if first_clean is not None:
        print('%s: the capture agrees with the RTL from sample %d on' % (name, first_clean))
    if not ev:
        return True, 'bit-exact, %d samples' % res['compared']
    n, comp, exp, got, kind = ev[0]
    want = '%d' % exp[0] if exp[0] == exp[1] else '%d or %d' % exp
    print('%s: first mismatch at sample %d, %s: expected %s, got %d' % (name, n, comp, want, got))
    if res['dense']:
        span = ev[-1][0] - ev[0][0] + 1
        print('%s: SYSTEMATIC: %d mismatches within %d samples (one every %.1f samples); '
              'counting stopped there' % (name, len(ev), span, span / len(ev)))
        return False, 'SYSTEMATIC mismatch (the chain computes something else)'
    words = [e for e in ev if e[4] == 'word']
    states = [e for e in ev if e[4] == 'state']
    if words:
        # what was altered, and what the same bit is in the words around it
        kinds = {}
        for n, comp, exp, got, kind in words:
            x = (exp[0] ^ got) & 0xFFFF
            cap = cap_i if comp == 'I' else cap_q
            around = tuple(int((int(cap[m]) ^ got) & x) == 0 if 0 <= m < len(cap) else None
                           for m in (n - 1, n + 1))
            one = bin(x).count('1') == 1
            desc = ('bit %d %d->%d' % (x.bit_length() - 1, (exp[0] & x) != 0, (got & x) != 0)) if one \
                else 'bits 0x%04x' % x
            k = (comp, desc)
            kinds.setdefault(k, [0, 0])
            kinds[k][0] += 1
            kinds[k][1] += 1 if around == (True, True) else 0
        print('%s: %d ISOLATED single samples differ while the rounder runs on in the state of the '
              'expected value: computed right, altered afterwards' % (name, len(words)))
        for (comp, desc), (count, lonely) in sorted(kinds.items()):
            print('%s:   %s word, %s: %d times; in %d of them the same bit has the value '
                  'that was read in the word before and in the word after' % (name, comp, desc, count, lonely))
        for n, comp, exp, got, kind in words[:6]:
            print('%s:   sample %d, %s: expected %d (0x%04x), got %d (0x%04x)' % (
                name, n, comp, exp[0], exp[0] & 0xFFFF, got, got & 0xFFFF))
        if len(words) > 6:
            print('%s:   ... and %d more at samples %s' % (name, len(words) - 6,
                                                         ' '.join(str(e[0]) for e in words[6:30])))
    if states:
        bl = bursts_of(states)
        print('%s: %d burst%s after which the rounder is in another state - what went into it differed '
              '(mismatches less than %d samples apart are one burst):' % (
                  name, len(bl), '' if len(bl) == 1 else 's', BURST_GAP))
        for first, last, items in bl[:20]:
            big = max(abs(g - e) for _, _, ex, g, _ in items for e in ex)
            print('%s:   samples %d..%d (%d long), %d mismatches, largest deviation %d counts' % (
                name, first, last, last - first + 1, len(items), big))
        if len(bl) > 20:
            print('%s:   ... and %d more' % (name, len(bl) - 20))
    verdict = []
    if words:
        verdict.append('%d isolated altered word%s (arithmetic agrees)' % (len(words), '' if len(words) == 1 else 's'))
    if states:
        verdict.append('%d mismatch%s that changed the rounder state' % (len(states), '' if len(states) == 1 else 'es'))
    return False, ', '.join(verdict) + ', in %d samples' % res['compared']


def residual_stats(name, pre_i, pre_q, cap_i, cap_q, start):
    """How far the capture is from the unrounded RTL value, for a failing channel."""
    for comp, pre, cap in (('I', pre_i, cap_i), ('Q', pre_q, cap_q)):
        r = cap[start:] - pre[start:] / float(1 << 17)
        walk = np.cumsum(r)
        nearest = (pre[start:] + (1 << 16)) >> 17
        print('%s: %s: capture minus unrounded RTL value: mean %+.3f, rms %.3f, max |.| %.2f counts; '
              'its running sum wanders over %.1f counts (an error-feedback rounder keeps it within 2); '
              'plain round-to-nearest of the RTL value would differ in %d of %d samples' % (
                  name, comp, r.mean(), r.std(), np.abs(r).max(), walk.max() - walk.min(),
                  int(np.count_nonzero(nearest != cap[start:])), len(r)))


def find_first_clean(pre_i, pre_q, cap_i, cap_q, skip):
    """Smallest of a few start samples from which the capture has no mismatch."""
    best = None
    for s in (skip // 2, skip // 4, 1024, 256, 64, 16, 0):
        if s >= skip or (best is not None and s >= best):
            continue
        if compare(pre_i, pre_q, cap_i, cap_q, s)['events']:
            break
        best = s
    return best


def locate(cap_i, cap_q, skip, candidates, window=4096, verify=2048):
    """Pick the alignment.  candidates: [(label, ref_i, ref_q, positions)] where
    ref_* is one period of rounder inputs in time order.  Returns (label, k)."""
    seg = cap_i[skip:skip + window] + 1j * cap_q[skip:skip + window]
    scored = []
    for label, ri, rq, pos in candidates:
        ref = (ri + 1j * rq) / float(1 << 17)
        for k, e in best_offsets(seg, ref):
            scored.append((e, label, k))
    scored.sort(key=lambda t: t[0])
    # near-equal least-squares scores (a tone repeats): let the exact test decide
    best = None
    for e, label, k in scored[:24]:
        ri, rq, _ = [(a, b, c) for l, a, b, c in candidates if l == label][0]
        q = len(ri)
        idx = (k + np.arange(min(verify, len(cap_i) - skip))) % q
        res = compare(ri[idx], rq[idx], cap_i[skip:skip + len(idx)], cap_q[skip:skip + len(idx)], 0)
        score = (len(res['events']), e)
        if best is None or score < best[0]:
            best = (score, label, k)
        if not res['events']:
            break
    return best[1], best[2], best[0][1]


# ----------------------------------------------------------------------------
# rx
# ----------------------------------------------------------------------------

def rx_period(decim, regs, n_mux_total, max_jobs):
    """One period of rounder inputs for one receive configuration, by PN position.

    position p: the PN word with index p is on the receive pins on the clock
    of the output strobe.  Returns (I table, Q table, samples the rounder
    model was checked on, True) from the cache, or the simulations still to
    run as ('jobs', ...) for rx_finish.
    """
    vvp, dig = build_bench('dspx_rx')
    reg = {n: v for n, v, _ in regs}
    key = hashlib.sha1(('rx %s %d %x %x %x %x' % (dig, decim, reg['rx_freq'], reg['rx_scale'],
                                                 reg['rx_rate'], reg['rx_mux'])).encode()).hexdigest()[:20]
    path = os.path.join(CACHE, 'rx-%s.npz' % key)
    if os.path.exists(path):
        z = np.load(path)
        return z['ti'], z['tq'], int(z['checked']), True
    os.makedirs(CACHE, exist_ok=True)
    words, index = pn_sequence()
    g = math.gcd(PN_PERIOD, decim)
    q = PN_PERIOD // g                      # output samples per period and phase class
    parts = max(1, (max_jobs // max(1, n_mux_total)) // g)
    k0 = -(-q // parts)
    jobs = []
    for c in range(g):
        for j in range(parts):
            start = (decim * (k0 * j - SETTLE)) % PN_PERIOD
            out = os.path.join(SCRATCH, 'rx-%s-%d-%d.txt' % (key, c, j))
            jobs.append((['+FREQ=%x' % reg['rx_freq'], '+SCALE=%x' % reg['rx_scale'],
                          '+RATE=%x' % reg['rx_rate'], '+MUX=%x' % reg['rx_mux'],
                          '+W0=%x' % words[start], '+PHASE=%d' % c,
                          '+NOUT=%d' % (SETTLE + k0 + 32)], out))
    return ('jobs', vvp, jobs, path, index)


def rx_finish(pending):
    _, vvp, jobs, path, index = pending
    dumps = []
    for _, out in jobs:
        key, si, sq, pi, pq = read_dump(out, 16)
        dumps.append((index[key], si, sq, pi, pq))
    checked = check_rounder_model(dumps)
    ti, tq, have = fill_table(PN_PERIOD, dumps)
    if not have.all():
        raise Fail('the simulated chain did not cover the PN period at the expected output rate '
                   '(%d of 65535 positions missing): the rate word does not decimate as requested'
                   % int(np.count_nonzero(~have)))
    np.savez(path, ti=ti, tq=tq, checked=checked)
    for _, out in jobs:
        os.remove(out)
    return ti, tq, checked, False


def cmd_rx(a):
    chans = [int(c) for c in a.chans.split(',')]
    words, index = pn_sequence()
    print('receive, PN sequence: decimation %d, master clock %.6g MHz, host rate %.6g MS/s'
          % (a.decim, a.mcr / 1e6, a.mcr / a.decim / 1e6))
    per_chan = {}
    todo = []
    for ch in chans:
        regs = apply_overrides(uhd_rx_regs(a.decim, ch), a.override)
        show_regs('ch%d (radio %d), SR_RX_DSP = 144:' % (ch, ch), regs)
        got = rx_period(a.decim, regs, len(chans), a.jobs)
        per_chan[ch] = got
        if isinstance(got[0], str):
            todo.append(ch)
    if todo:
        t0 = time.time()
        vvp = per_chan[todo[0]][1]
        alljobs = [j for ch in todo for j in per_chan[ch][2]]
        print('simulating one PN period in RTL: %d runs, %d at a time ...' % (len(alljobs), a.jobs))
        run_jobs(vvp, alljobs, a.jobs)
        for ch in todo:
            per_chan[ch] = rx_finish(per_chan[ch])
        print('  done in %.0f s' % (time.time() - t0))
    ok = True
    summary, where = [], {}
    g = math.gcd(PN_PERIOD, a.decim)
    q = PN_PERIOD // g
    for ch in chans:
        ti, tq, checked, cached = per_chan[ch]
        name = 'ch%d' % ch
        print('%s: RTL period %s; rounder model checked against round_sd.v on %d simulated samples'
              % (name, 'from cache' if cached else 'simulated', checked))
        cap_i, cap_q = load_capture('%s_ch%d.sc16' % (a.prefix, ch))
        if len(cap_i) < a.skip + 8192:
            sys.exit('%s: capture too short' % name)
        cands = []
        for r in range(g):
            pos = (r + a.decim * np.arange(q)) % PN_PERIOD
            cands.append((r, ti[pos], tq[pos], pos))
        r, k, lsq = locate(cap_i, cap_q, a.skip, cands)
        pos = (r + a.decim * (k + np.arange(len(cap_i)) - a.skip)) % PN_PERIOD
        pre_i, pre_q = ti[pos], tq[pos]
        res = compare(pre_i, pre_q, cap_i, cap_q, a.skip)
        first_clean = find_first_clean(pre_i, pre_q, cap_i, cap_q, a.skip) if not res['events'] else None
        text = ('PN word 0x%04x (position %d of 65535) is on the pins at the strobe of capture sample %d; '
                'it advances %d words per sample' % (words[pos[a.skip]], pos[a.skip], a.skip, a.decim))
        good, verdict = report_channel(name, res, a.skip, text, first_clean, cap_i, cap_q)
        if res['dense'] or any(e[4] == 'state' for e in res['events']):
            residual_stats(name, pre_i, pre_q, cap_i, cap_q, a.skip)
        ok = ok and good
        summary.append('%s: %s' % (name, verdict))
        where[ch] = int(pos[a.skip])
    if len(chans) == 2 and not any('SYSTEMATIC' in t for t in summary):
        d = (where[chans[1]] - where[chans[0]] + PN_PERIOD // 2) % PN_PERIOD - PN_PERIOD // 2
        print('channels: at the same capture sample ch%d is %s' % (chans[1], (
            'on the same PN word as ch%d' % chans[0] if d == 0 else
            '%d PN word%s %s ch%d: the two receivers are skewed by that many input samples'
            % (abs(d), '' if abs(d) == 1 else 's', 'ahead of' if d > 0 else 'behind', chans[0]))))
    print('SUMMARY: ' + '; '.join(summary))
    return ok


# ----------------------------------------------------------------------------
# loop
# ----------------------------------------------------------------------------

def loop_period(total, tx_block, tregs, rregs, dac, max_jobs):
    vvp, dig = build_bench('dspx_loop')
    treg = {n: v for n, v, _ in tregs}
    rreg = {n: v for n, v, _ in rregs}
    blockdig = hashlib.sha1(tx_block.tobytes()).hexdigest()[:16]
    key = hashlib.sha1(('loop %s %d %s %s %s %s' % (dig, total, blockdig, sorted(treg.items()),
                                                   sorted(rreg.items()), dac)).encode()).hexdigest()[:20]
    path = os.path.join(CACHE, 'loop-%s.npz' % key)
    if os.path.exists(path):
        z = np.load(path)
        return z['ti'], z['tq'], int(z['checked']), True
    os.makedirs(CACHE, exist_ok=True)
    n = len(tx_block) // 2
    hexfile = os.path.join(SCRATCH, 'loop-%s.hex' % key)
    with open(hexfile, 'w') as f:
        for i, q in zip(tx_block[0::2], tx_block[1::2]):
            f.write('%04x%04x\n' % (int(i) & 0xFFFF, int(q) & 0xFFFF))
    jobs = []
    for s in range(total):
        out = os.path.join(SCRATCH, 'loop-%s-%d.txt' % (key, s))
        jobs.append((['+TXHEX=' + hexfile, '+TXLEN=%d' % n,
                      '+TFREQ=%x' % treg['tx_freq'], '+TSCALE=%x' % treg['tx_scale'],
                      '+TRATE=%x' % treg['tx_rate'],
                      '+FREQ=%x' % rreg['rx_freq'], '+SCALE=%x' % rreg['rx_scale'],
                      '+RATE=%x' % rreg['rx_rate'], '+MUX=%x' % rreg['rx_mux'],
                      '+TOTAL=%d' % total, '+DELAY=%d' % s,
                      '+DAC=%d' % (1 if dac == 'truncate' else 0),
                      '+NOUT=%d' % (SETTLE + n + 32)], out))
    return ('jobs', vvp, jobs, path, n, hexfile)


def loop_finish(pending):
    _, vvp, jobs, path, n, hexfile = pending
    tis, tqs, checked = [], [], 0
    for _, out in jobs:
        d = read_dump(out, 10)
        checked += check_rounder_model([d])
        ti, tq, have = fill_table(n, [d])
        if not have.all():
            raise Fail('the simulated chains did not cover the transmit block at the expected rate '
                       '(%d of %d positions missing): a rate word does not match the rate change requested'
                       % (int(np.count_nonzero(~have)), n))
        tis.append(ti)
        tqs.append(tq)
        os.remove(out)
    os.remove(hexfile)
    np.savez(path, ti=np.array(tis), tq=np.array(tqs), checked=checked)
    return np.array(tis), np.array(tqs), checked, False


def cmd_loop(a):
    chans = [int(c) for c in a.chans.split(',')]
    print('transmit -> AD9361 digital loopback -> receive: interpolation and decimation %d, '
          'DAC slice: %s' % (a.interp, 'tx_fe[23:12] (upstream Ettus)' if a.dac == 'truncate'
                             else 'dac_slice.v (round half even, saturate)'))
    per_chan, blocks, todo = {}, {}, []
    for ch in chans:
        block = np.fromfile('%s_tx_ch%d.sc16' % (a.prefix, ch), dtype='<i2')
        blocks[ch] = block
        tregs = apply_overrides(uhd_tx_regs(a.interp), a.override)
        rregs = apply_overrides(uhd_rx_regs(a.interp, ch), a.override)
        show_regs('ch%d (radio %d), SR_TX_DSP = 184:' % (ch, ch), tregs)
        show_regs('ch%d (radio %d), SR_RX_DSP = 144:' % (ch, ch), rregs)
        got = loop_period(a.interp, block, tregs, rregs, a.dac, a.jobs)
        per_chan[ch] = got
        if isinstance(got[0], str):
            todo.append(ch)
    if todo:
        t0 = time.time()
        vvp = per_chan[todo[0]][1]
        alljobs = [j for ch in todo for j in per_chan[ch][2]]
        print('simulating one transmit block in RTL: %d runs, %d at a time ...' % (len(alljobs), a.jobs))
        run_jobs(vvp, alljobs, a.jobs)
        for ch in todo:
            per_chan[ch] = loop_finish(per_chan[ch])
        print('  done in %.0f s' % (time.time() - t0))
    ok = True
    summary = []
    for ch in chans:
        tis, tqs, checked, cached = per_chan[ch]
        name = 'ch%d' % ch
        n = tis.shape[1]
        print('%s: RTL period (%d samples x %d loop delays) %s; rounder model checked against '
              'round_sd.v on %d simulated samples' % (name, n, tis.shape[0],
                                                      'from cache' if cached else 'simulated', checked))
        cap_i, cap_q = load_capture('%s_ch%d.sc16' % (a.prefix, ch))
        cands = [(s, tis[s], tqs[s], None) for s in range(tis.shape[0])]
        s, k, lsq = locate(cap_i, cap_q, a.skip, cands)
        pos = (k + np.arange(len(cap_i)) - a.skip) % n
        pre_i, pre_q = tis[s][pos], tqs[s][pos]
        res = compare(pre_i, pre_q, cap_i, cap_q, a.skip)
        first_clean = find_first_clean(pre_i, pre_q, cap_i, cap_q, a.skip) if not res['events'] else None
        text = ('host block sample %d (of %d) is at the DUC input at the strobe of capture sample %d; '
                'loop delay %d clock%s modulo %d' % (pos[a.skip], n, a.skip, s, '' if s == 1 else 's', a.interp))
        good, verdict = report_channel(name, res, a.skip, text, first_clean, cap_i, cap_q)
        if res['dense'] or any(e[4] == 'state' for e in res['events']):
            residual_stats(name, pre_i, pre_q, cap_i, cap_q, a.skip)
        ok = ok and good
        summary.append('%s: %s' % (name, verdict))
    print('SUMMARY: ' + '; '.join(summary))
    return ok


def _override(text):
    name, _, value = text.partition('=')
    if name not in ('rx_freq', 'rx_scale', 'rx_rate', 'rx_mux', 'tx_freq', 'tx_scale', 'tx_rate') or not value:
        raise argparse.ArgumentTypeError('expected NAME=VALUE with NAME one of rx_freq rx_scale '
                                         'rx_rate rx_mux tx_freq tx_scale tx_rate')
    return name, int(value, 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0],
                                 epilog='See the top of this file for what is compared and how.')
    sub = ap.add_subparsers(dest='mode', required=True)
    for mode in ('rx', 'loop'):
        p = sub.add_parser(mode)
        p.add_argument('prefix', help='capture files are <prefix>_ch<n>.sc16'
                       + (' and <prefix>_tx_ch<n>.sc16' if mode == 'loop' else ''))
        if mode == 'rx':
            p.add_argument('--decim', type=int, required=True, help='FPGA decimation (master clock / host rate)')
            p.add_argument('--chans', default='0,1')
        else:
            p.add_argument('--interp', type=int, required=True, help='FPGA interpolation = decimation')
            p.add_argument('--chans', default='0')
            p.add_argument('--dac', choices=('round', 'truncate'), default='round',
                           help='24 to 12 bits at the transmit pins: round = dac_slice.v (this '
                                'repository), truncate = tx_fe[23:12] (upstream Ettus)')
        p.add_argument('--mcr', type=float, default=30.72e6, help='master clock rate (reported only)')
        p.add_argument('--skip', type=int, default=4096,
                       help='samples at the start of the capture left out (start-up)')
        p.add_argument('--override', type=_override, action='append', default=[],
                       metavar='NAME=VALUE', help='simulate with this register value instead of UHD\'s')
        p.add_argument('--jobs', type=int, default=MAX_JOBS, help='simulator processes at a time (at most 6)')
    a = ap.parse_args()
    a.override = dict(a.override)
    a.jobs = max(1, min(MAX_JOBS, a.jobs))
    try:
        ok = cmd_rx(a) if a.mode == 'rx' else cmd_loop(a)
    except Fail as e:
        print('no comparison: %s' % e)
        ok = False
    print('RESULT: ' + ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
