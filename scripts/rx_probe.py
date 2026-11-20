#!/usr/bin/env python3
"""rx_probe.py - the RX-only hardware check, both channels, graphed.

This is layer 1 of BENCH-SESSION.md, automated: stream both receive
channels, graph what the hardware actually sends, and print PASS/FAIL
against the expectations simulation measured.  No TX is used anywhere.

Usage:
    python3 scripts/rx_probe.py [--args type=b200] [--out build/hw-probe] [--secs 0.05]
"""
import argparse
import os
import sys
import time

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FS = 61.44e6
FULL = 32768.0


def stats(x):
    prev = None; cur = 0; best = 0
    for v in x[:50000]:
        if v == prev:
            cur += 1; best = max(best, cur)
        else:
            cur = 0
        prev = v
    return dict(rms=float(np.std(x)), dc=float(np.mean(x)),
                peak=float(np.max(np.abs(x))), codes=len(np.unique(x)),
                stuck=best)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--args", default="type=b200")
    ap.add_argument("--out", default="build/hw-probe")
    ap.add_argument("--secs", type=float, default=0.05)
    ap.add_argument("--synthetic", action="store_true",
                    help="no hardware: codec-noise-like data, to test this tool")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    if a.synthetic:
        rng = np.random.default_rng(7)
        n = int(a.secs * FS)
        # codec-like: 12-bit codes on the 16-bit word (LSB nibble zero)
        c0 = np.round(rng.normal(0, 120, n)) * 16 + rng.integers(-2, 3, n)
        c1 = np.round(rng.normal(0, 125, n)) * 16 + rng.integers(-2, 3, n)
        c0 = c0.astype(np.complex64) + 1j*np.roll(c0, 3).astype(np.complex64)
        c1 = c1.astype(np.complex64) + 1j*np.roll(c1, 5).astype(np.complex64)
        got = n; dt = n/FS/0.95
        return report(c0, c1, got, dt, a.out, synthetic=True)
    import uhd
    print(f"[rx_probe] opening {a.args}")
    usrp = uhd.usrp.MultiUSRP(a.args)
    print(f"[rx_probe] mboard: {usrp.get_mboard_name()}")
    if usrp.get_rx_num_channels() < 2:
        sys.exit("[rx_probe] FAIL: fewer than 2 RX channels")

    for ch in (0, 1):
        usrp.set_rx_rate(FS, ch)
        usrp.set_rx_freq(uhd.types.TuneRequest(1e9), ch)
        usrp.set_rx_gain(0.0, ch)
    print(f"[rx_probe] rate {usrp.get_rx_rate(0)/1e6:.3f} MHz "
          f"freq {usrp.get_rx_freq(0)/1e6:.3f} MHz gain {usrp.get_rx_gain(0)} dB")

    nsamps = int(a.secs * FS)
    st = uhd.usrp.StreamArgs("fc32", "sc16")
    st.channels = [0, 1]
    streamer = usrp.get_rx_stream(st)
    buf = [np.zeros(nsamps, dtype=np.complex64) for _ in range(2)]
    md = uhd.types.RXMetadata()
    cmd = uhd.types.StreamCMD(uhd.types.StreamCMD.num_samps_done)
    cmd.num_samps = nsamps
    cmd.stream_now = True
    usrp.issue_stream_cmd(cmd)
    t0 = time.time()
    got = streamer.recv(buf, md, 5.0)
    usrp.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamCMD.mode_stop_cont))
    dt = time.time() - t0
    eff = got / dt / FS * 100 if dt > 0 else 0
    print(f"[rx_probe] recv {got}/{nsamps} in {dt*1e3:.1f} ms ({eff:.0f}% of rate) "
          f"err {md.error_code}")
    return report(buf[0][:got], buf[1][:got], got, dt, a.out)

def report(c0, c1, got, dt, outdir, synthetic=False):
    i0, q0, i1, q1 = c0.real, c0.imag, c1.real, c1.imag
    eff = got / dt / FS * 100 if dt > 0 else 0
    if not synthetic:
        print(f"[rx_probe] recv {got} in {dt*1e3:.1f} ms ({eff:.0f}% of rate)")
        if got < 1000:
            sys.exit("[rx_probe] FAIL: stream came back short - data path not flowing")
    s0i, s0q, s1i, s1q = stats(i0), stats(q0), stats(i1), stats(q1)

    ok = True
    def chk(cond, what, detail=""):
        nonlocal ok
        print(f"[rx_probe] {'PASS' if cond else 'FAIL'}: {what} {detail}")
        ok = ok and cond

    chk(s0i["codes"] > 100 and s0q["codes"] > 100,
        "ch0 many distinct codes", f"{s0i['codes']}/{s0q['codes']}")
    chk(s1i["codes"] > 100 and s1q["codes"] > 100,
        "ch1 many distinct codes", f"{s1i['codes']}/{s1q['codes']}")
    chk(s0i["stuck"] < 64 and s0q["stuck"] < 64,
        "ch0 no stuck words", f"longest run {s0i['stuck']}/{s0q['stuck']}")
    chk(s1i["stuck"] < 64 and s1q["stuck"] < 64,
        "ch1 no stuck words", f"longest run {s1i['stuck']}/{s1q['stuck']}")
    chk(abs(s0i["dc"]) < 1000 and abs(s0q["dc"]) < 1000,
        "ch0 DC near zero at minimum gain", f"{s0i['dc']:.1f}/{s0q['dc']:.1f} LSB")
    chk(not np.array_equal(i0[:1000], i1[:1000]),
        "channels independent (not one wire fed twice)")
    chk(eff > 90, "stream rate sustains", f"{eff:.0f}% of 61.44 MSPS")

    # ---- graphs: what the hardware actually sent ----
    t = np.arange(min(got, 4096)) / FS * 1e6
    fig, ax = plt.subplots(2, 2, figsize=(13, 7.5))
    ax[0, 0].plot(t, i0[:len(t)], lw=0.4, color="#1f4e79", label="ch0 I")
    ax[0, 0].plot(t, i1[:len(t)], lw=0.4, color="#b3541e", alpha=0.7, label="ch1 I")
    ax[0, 0].set_title("time domain, first 4096 samples (hardware, RX only)")
    ax[0, 0].set_xlabel("us"); ax[0, 0].legend(fontsize=7); ax[0, 0].grid(alpha=0.3, lw=0.4)
    for x, col, lab in ((c0, "#1f4e79", "ch0"), (c1, "#b3541e", "ch1")):
        n = min(len(x), 65536)
        X = np.abs(np.fft.fft(x[:n])) / (n * FULL)
        X = 20 * np.log10(np.maximum(X, 1e-16))
        f = np.fft.fftfreq(n, 1 / FS)[: n // 2] / 1e6
        ax[0, 1].plot(f, X[: n // 2], lw=0.5, color=col, label=lab)
    ax[0, 1].set_title("spectrum, dBFS (codec noise floor expected)")
    ax[0, 1].set_xlabel("MHz"); ax[0, 1].legend(fontsize=7); ax[0, 1].grid(alpha=0.3, lw=0.4)
    ax[1, 0].hist(i0[:100000], bins=80, color="#1f4e79", alpha=0.6, label="ch0 I")
    ax[1, 0].hist(i1[:100000], bins=80, color="#b3541e", alpha=0.6, label="ch1 I")
    ax[1, 0].set_title("I distribution, both channels"); ax[1, 0].legend(fontsize=7)
    ax[1, 1].plot(c0.real[:5000], c0.imag[:5000], ".", ms=1, color="#1f4e79", label="ch0")
    ax[1, 1].plot(c1.real[:5000], c1.imag[:5000], ".", ms=1, color="#b3541e", label="ch1")
    ax[1, 1].set_title("constellation (noise ball expected, not a line)")
    ax[1, 1].set_xlabel("I"); ax[1, 1].set_ylabel("Q"); ax[1, 1].legend(fontsize=7)
    for r in ax:
        for a2 in r:
            a2.tick_params(labelsize=7)
    fig.suptitle("USRP B210 + this FPGA image: RX only, both channels, no TX", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    out = os.path.join(outdir, "hw_rx_probe.png")
    fig.savefig(out, dpi=110); plt.close(fig)
    np.save(os.path.join(outdir, "rx_ch0.npy"), c0)
    np.save(os.path.join(outdir, "rx_ch1.npy"), c1)
    print(f"[rx_probe] graphs: {out}" + ("  (synthetic self-test)" if synthetic else ""))
    print(f"[rx_probe] ch0: {s0i} | Q {s0q}")
    print(f"[rx_probe] ch1: {s1i} | Q {s1q}")
    print(f"[rx_probe] OVERALL: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
