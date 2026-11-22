#!/usr/bin/env python3
"""rx_capture.py - standard UHD receive capture + FFT/quality graphs.

This is the plain, industry-standard way to receive from a B210-class USRP:
continuous streaming (start_cont) with a large receive buffer, overflow
accounting, then offline analysis and PNG graphs.

Modes (matching the hardware's own limits, read from UHD):
    dual   : 2 channels, up to 30.72 MSPS per channel (61.44 MSPS total ADC)
    single : 1 channel,  up to 61.44 MSPS (double speed)

Usage:
    python3 scripts/rx_capture.py --rate 30.72e6 --chans 2 --secs 1
    python3 scripts/rx_capture.py --rate 61.44e6 --chans 1 --secs 1
    python3 scripts/rx_capture.py --args "type=b200,serial=31B92DD,fpga=..." ...
    python3 scripts/rx_capture.py --tune-sweep 900e6:1000e6:5 --chans 1

RX only.  Never transmits.
"""
import argparse
import json
import os
import time

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FULL_SCALE = 32768.0


def graph(chans, rate, outdir, tag, freqs=None, gains=None):
    """chans: list of (fs, iq) tuples."""
    os.makedirs(outdir, exist_ok=True)
    labels = [f"ch{i}" for i in range(len(chans))]
    colors = ["#1f4e79", "#b3541e", "#2e7d32", "#6a1b9a"]

    # ---------- per-channel figure ----------
    n = len(chans)
    fig, ax = plt.subplots(n, 4, figsize=(18, 3.4 * n), squeeze=False)
    for r, (fs, x) in enumerate(chans):
        t = np.arange(min(len(x), 4096)) / fs * 1e6
        ax[r, 0].plot(t, x.real[:len(t)], lw=0.5, color=colors[0], label="I")
        ax[r, 0].plot(t, x.imag[:len(t)], lw=0.5, color=colors[1], alpha=0.75, label="Q")
        ax[r, 0].set_title(f"{labels[r]} time domain (first 4096)")
        ax[r, 0].set_xlabel("us"); ax[r, 0].legend(fontsize=7); ax[r, 0].grid(alpha=0.3, lw=0.4)

        m = min(len(x), 1 << 16)
        win = np.hanning(m)
        X = np.fft.fftshift(np.fft.fft(x[:m] * win))
        X = 20 * np.log10(np.maximum(np.abs(X) / (m * FULL_SCALE), 1e-16))
        f = np.fft.fftshift(np.fft.fftfreq(m, 1 / fs)) / 1e6
        ax[r, 1].plot(f, X, lw=0.5, color=colors[r % 4])
        ax[r, 1].set_title(f"{labels[r]} spectrum (dBFS, {m}-pt FFT)")
        ax[r, 1].set_xlabel("MHz"); ax[r, 1].grid(alpha=0.3, lw=0.4)
        floor = np.median(X)
        peak = np.max(X)
        ax[r, 1].axhline(floor, color="grey", lw=0.6, ls="--")
        ax[r, 1].text(0.02, 0.95, f"floor {floor:.1f} dBFS\npeak {peak:.1f} dBFS\n"
                      f"noise {np.std(x.real):.1f} LSB rms",
                      transform=ax[r, 1].transAxes, fontsize=7, va="top")

        ax[r, 2].hist(x.real[:200000], bins=100, color=colors[0], alpha=0.65, label="I")
        ax[r, 2].hist(x.imag[:200000], bins=100, color=colors[1], alpha=0.65, label="Q")
        ax[r, 2].set_title(f"{labels[r]} amplitude distribution")
        ax[r, 2].legend(fontsize=7); ax[r, 2].grid(alpha=0.3, lw=0.4)

        ax[r, 3].plot(x.real[:5000], x.imag[:5000], ".", ms=1, color=colors[r % 4])
        ax[r, 3].set_title(f"{labels[r]} constellation")
        ax[r, 3].set_xlabel("I"); ax[r, 3].set_ylabel("Q"); ax[r, 3].axis("equal")

    fig.suptitle(f"USRP B210 RX capture - {tag} (RX only, no TX)", fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    p = os.path.join(outdir, f"{tag}.png")
    fig.savefig(p, dpi=110); plt.close(fig)
    return p


def capture(usrp, uhd, chans, rate, secs, freq, gain):
    for ch in range(chans):
        usrp.set_rx_rate(rate, ch)
        usrp.set_rx_freq(uhd.types.TuneRequest(freq), ch)
        usrp.set_rx_gain(gain, ch)
    got_rate = usrp.get_rx_rate(0)
    got_freq = usrp.get_rx_freq(0)

    st = uhd.usrp.StreamArgs("fc32", "sc16")
    st.channels = list(range(chans))
    rx = usrp.get_rx_stream(st)
    try:
        rx.recv_buff_size = max(1.0, secs * 4)   # seconds of buffering
    except Exception:
        pass

    target = int(secs * got_rate)
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.start_cont)
    if chans > 1:
        # Multiple channels in one streamer must start at a common, known time.
        cmd.stream_now = False
        cmd.time_spec = usrp.get_time_now() + uhd.types.TimeSpec(0.2)
    else:
        cmd.stream_now = True
    rx.issue_stream_cmd(cmd)

    # NOTE: pyuhd expects the buffer shaped (nchannels, nsamples); a
    # (nsamples,) or (nsamples, nchannels) buffer makes recv() return one
    # sample per call and silently caps throughput.
    buf = np.zeros((chans, 65536), dtype=np.complex64)
    md = uhd.types.RXMetadata()
    chunks = []
    total = 0
    overflows = 0
    timeouts = 0
    t0 = time.time()
    while total < target:
        n = rx.recv(buf, md, 1.0)
        if n == 0:
            if md.error_code == uhd.types.RXMetadataErrorCode.overflow:
                overflows += 1
            elif md.error_code == uhd.types.RXMetadataErrorCode.timeout:
                timeouts += 1
                if timeouts > 5:
                    break
            continue
        chunks.append(buf[:, :n].T.copy())
        total += n
    rx.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))
    dt = time.time() - t0

    data = np.concatenate(chunks, axis=0) if chunks else np.zeros((0, chans), np.complex64)
    return data, got_rate, got_freq, dt, overflows, timeouts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--args", default="type=b200")
    ap.add_argument("--rate", type=float, default=30.72e6)
    ap.add_argument("--chans", type=int, default=2, choices=[1, 2])
    ap.add_argument("--secs", type=float, default=0.5)
    ap.add_argument("--freq", type=float, default=100e6)
    ap.add_argument("--gain", type=float, default=0.0)
    ap.add_argument("--out", default="build/rx")
    ap.add_argument("--tag", default=None)
    ap.add_argument("--tune-sweep", default=None,
                    help="LO:MHz:step e.g. 900e6:1000e6:5 (single channel)")
    a = ap.parse_args()

    import uhd

    print(f"[rx_capture] {a.args}")
    usrp = uhd.usrp.MultiUSRP(a.args)
    print(f"[rx_capture] mboard={usrp.get_mboard_name()} "
          f"rx_chans={usrp.get_rx_num_channels()} "
          f"fpga_version={usrp.get_usrp_rx_info().get('fpga_version', '?')}")

    os.makedirs(a.out, exist_ok=True)
    results = []

    if a.tune_sweep:
        lo, hi, step_mhz = a.tune_sweep.split(":")
        freqs = np.arange(float(lo), float(hi) + 1, float(step_mhz) * 1e6)
    else:
        freqs = [a.freq]

    for f in freqs:
        data, rate, ff, dt, ovf, tmo = capture(usrp, uhd, a.chans, a.rate, a.secs, f, a.gain)
        n = len(data)
        msps = n / dt / 1e6 if dt > 0 else 0
        print(f"[rx_capture] LO {ff/1e6:.3f} MHz  rate {rate/1e6:.3f} MSPS  "
              f"chans {a.chans}  got {n} samples ({msps:.1f} MSPS sustained, "
              f"{n/max(1,(rate*a.secs))*100:.1f}% of request)  "
              f"overflows {ovf}  timeouts {tmo}")
        results.append(dict(freq=ff, rate=rate, chans=a.chans, n=n,
                            msps=msps, overflows=ovf, timeouts=tmo))
        if n == 0:
            continue
        tag = a.tag or (f"rx_{a.chans}ch_{rate/1e6:.2f}msps_{ff/1e6:.1f}mhz")
        np.save(os.path.join(a.out, f"{tag}_ch0.npy"), data[:, 0])
        if a.chans > 1:
            np.save(os.path.join(a.out, f"{tag}_ch1.npy"), data[:, 1])
        chans = [(rate, data[:, c]) for c in range(a.chans)]
        p = graph(chans, rate, a.out, tag)
        for c in range(a.chans):
            x = data[:, c]
            print(f"    ch{c}: {len(x)} samples  rms(I)={np.std(x.real):.2f} "
                  f"rms(Q)={np.std(x.imag):.2f}  peak={np.max(np.abs(x)):.1f} "
                  f"codes={len(np.unique(np.ascontiguousarray(x).view(np.float32)))}")
        print(f"    graph: {p}")

    with open(os.path.join(a.out, "capture_summary.json"), "w") as fh:
        json.dump(results, fh, indent=2)

    ok = all(r["n"] > 0.9 * r["rate"] * a.secs for r in results)
    print(f"[rx_capture] OVERALL: {'PASS' if ok else 'PARTIAL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
