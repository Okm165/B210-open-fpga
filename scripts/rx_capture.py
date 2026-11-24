#!/usr/bin/env python3
"""rx_capture.py - standard UHD receive capture + FFT/quality graphs.

A timed, fixed-length capture through the stock UHD API, then offline
analysis and PNG graphs.

Modes (matching the hardware's own limits, read from UHD):
    dual   : 2 channels, up to 30.72 MSPS per channel (61.44 MSPS total ADC)
    single : 1 channel,  up to 61.44 MSPS (double speed)

PASS means: exactly the requested number of samples on every channel, no
overflow, timeout or sequence error reported by the streamer, no constant
channel, and (dual) the two channels not identical.

Usage:
    python3 scripts/rx_capture.py --args type=b200,fpga=<image.bin> --rate 30.72e6 --chans 2 --secs 1
    python3 scripts/rx_capture.py --args type=b200,fpga=<image.bin> --rate 61.44e6 --chans 1 --secs 1

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

FULL_SCALE = 1.0      # fc32 samples: 1.0 is converter full scale


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
                      f"rms {20*np.log10(max(float(np.std(x)), 1e-9)):.1f} dBFS",
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
    """Continuous capture of exactly secs*rate samples per channel.

    Returns (data[n, chans], rate, freq, seconds, errors) where errors counts
    every metadata error the streamer reported, by name.
    """
    for ch in range(chans):
        usrp.set_rx_rate(rate, ch)
        usrp.set_rx_freq(uhd.types.TuneRequest(freq), ch)
        usrp.set_rx_gain(gain, ch)
    got_rate = usrp.get_rx_rate(0)
    got_freq = usrp.get_rx_freq(0)

    st = uhd.usrp.StreamArgs("fc32", "sc16")
    st.channels = list(range(chans))
    rx = usrp.get_rx_stream(st)

    target = int(round(secs * got_rate))
    # Buffers exist, with their pages mapped, before the stream starts: page
    # faults at 245 MB/s are an overflow in the first milliseconds.
    # pyuhd expects the buffer shaped (nchannels, nsamples).
    buf = np.empty((chans, 65536), dtype=np.complex64)
    data = np.empty((chans, target), dtype=np.complex64)
    buf.fill(0)
    data.fill(0)
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.num_done)
    cmd.num_samps = target
    # Channels of one streamer start at a common, known time.
    cmd.stream_now = False
    cmd.time_spec = usrp.get_time_now() + uhd.types.TimeSpec(0.2)
    rx.issue_stream_cmd(cmd)

    md = uhd.types.RXMetadata()
    none = uhd.types.RXMetadataErrorCode.none
    errors = {}
    total = 0
    t0 = time.time()
    while total < target and sum(errors.values()) < 100:
        n = rx.recv(buf, md, 2.0)
        if md.error_code != none:
            name = str(md.error_code).split(".")[-1]
            errors[name] = errors.get(name, 0) + 1
            if md.error_code == uhd.types.RXMetadataErrorCode.timeout:
                break
        n = min(n, target - total)
        data[:, total:total + n] = buf[:, :n]
        total += n
    dt = time.time() - t0
    return data[:, :total].T, got_rate, got_freq, dt, errors


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--args", required=True,
                    help="UHD device args; must carry fpga=<image>, otherwise "
                         "UHD loads its own image and that is what gets tested")
    ap.add_argument("--rate", type=float, default=30.72e6)
    ap.add_argument("--chans", type=int, default=2, choices=[1, 2])
    ap.add_argument("--secs", type=float, default=0.5)
    ap.add_argument("--freq", type=float, default=100e6)
    ap.add_argument("--gain", type=float, default=0.0)
    ap.add_argument("--out", default="build/rx")
    ap.add_argument("--tag", default=None)
    a = ap.parse_args()
    if "fpga=" not in a.args:
        ap.error("--args has no fpga=<image>")

    import uhd

    print(f"[rx_capture] {a.args}")
    usrp = uhd.usrp.MultiUSRP(a.args)
    os.makedirs(a.out, exist_ok=True)

    data, rate, freq, dt, errors = capture(usrp, uhd, a.chans, a.rate, a.secs, a.freq, a.gain)
    want = int(round(a.secs * rate))
    print(f"[rx_capture] LO {freq/1e6:.3f} MHz  rate {rate/1e6:.3f} MSPS x {a.chans}  "
          f"got {len(data)}/{want} samples in {dt:.2f} s  errors {errors or 'none'}")

    problems = []
    if len(data) != want:
        problems.append(f"{len(data)} of {want} samples")
    if errors:
        problems.append(f"stream errors {errors}")
    tag = a.tag or f"rx_{a.chans}ch_{rate/1e6:.2f}msps_{freq/1e6:.1f}mhz"
    if len(data):
        for c in range(a.chans):
            x = data[:, c]
            np.save(os.path.join(a.out, f"{tag}_ch{c}.npy"), x)
            rms = float(np.sqrt(np.mean(np.abs(x) ** 2)))
            print(f"    ch{c}: rms {20*np.log10(max(rms, 1e-9)):.1f} dBFS  "
                  f"peak {20*np.log10(max(float(np.max(np.abs(x))), 1e-9)):.1f} dBFS  "
                  f"dc {20*np.log10(max(abs(np.mean(x)), 1e-9)):.1f} dBFS")
            if rms == 0 or np.all(x == x[0]):
                problems.append(f"ch{c} is constant")
        if a.chans == 2 and np.array_equal(data[:, 0], data[:, 1]):
            problems.append("both channels carry identical samples")
        print("    graph: " + graph([(rate, data[:, c]) for c in range(a.chans)], rate, a.out, tag))
    with open(os.path.join(a.out, f"{tag}.json"), "w") as fh:
        json.dump(dict(freq=freq, rate=rate, chans=a.chans, samples=len(data), wanted=want,
                       seconds=dt, errors=errors, problems=problems), fh, indent=2)

    print("[rx_capture] OVERALL: " + ("PASS" if not problems else "FAIL - " + "; ".join(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
