#!/usr/bin/env python3
"""rx_explore.py - signal exploration for our FPGA image: 1 or 2 RX channels,
FFT quality panels, and the complete tuning surface exposed by UHD.

Single-channel mode streams at the FULL converter rate (61.44 MSPS, the
maximum this hardware can do on one channel).  Two-channel mode streams
2 x 30.72 MSPS (MIMO) - the 2-channel aggregate is the same 245.76 MB/s.

Every setting (master clock rate, RF frequency, analog gain, bandwidth,
DC offset) is settable from the command line, and every capture produces a
PNG: time domain, spectrum with the noise floor + SFDR annotated, and
spectrogram for drift/instability.

Usage (hardware):
    python3 scripts/rx_explore.py --ch 1 --freq 1e9 --gain 20 --rate 61.44e6
    python3 scripts/rx_explore.py --ch 2 --freq 2.4e9 --gain 30
Self-test (no hardware, synthetic 2-tone signal through a 12-bit codec model):
    python3 scripts/rx_explore.py --synthetic --out /tmp/opencode/explore
"""
import argparse
import os
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FS_MAX = 61.44e6
FULL = 32768.0


def spectrum(x, nfft=65536):
    x = x[: nfft * (len(x) // nfft)][:nfft]
    w = np.hanning(len(x))
    X = np.fft.fftshift(np.fft.fft(x * w))
    f = np.fft.fftshift(np.fft.fftfreq(len(x), 1 / FS_MAX)) / 1e6
    db = 20 * np.log10(np.maximum(np.abs(X) / (len(x) * FULL), 1e-16))
    return f, db


def quality(db, fs_mhz):
    """noise floor (median), strongest spur vs carrier, in dB."""
    pk = db.argmax()
    mask = np.ones(len(db), bool)
    mask[max(0, pk - 40):pk + 40] = False
    floor = float(np.median(db))
    spur_db = float(db[mask].max())
    return floor, spur_db, pk


def make_fig(chans, fs_mhz, out, title):
    n = len(chans)
    fig, ax = plt.subplots(n, 3, figsize=(14, 3.4 * n), squeeze=False)
    for i, c in enumerate(chans):
        t = np.arange(min(len(c), 2048)) / (fs_mhz * 1e6) * 1e6
        ax[i][0].plot(t, c.real[:len(t)], lw=0.5, color="#1f4e79")
        ax[i][0].set_title(f"ch{i} time domain"); ax[i][0].set_xlabel("us")
        ax[i][0].grid(alpha=0.3, lw=0.4)
        f, db = spectrum(c)
        floor, spur, pk = quality(db, fs_mhz)
        ax[i][1].plot(f, db, lw=0.5, color="#b3541e")
        ax[i][1].axhline(floor, color="grey", ls="--", lw=0.8)
        ax[i][1].annotate(f"floor {floor:.1f} dBFS", (f[10], floor + 3), fontsize=7)
        ax[i][1].annotate(f"peak/spur {spur:.1f} dB", (f[pk], db[pk] + 3), fontsize=7, color="#c62828")
        ax[i][1].set_title(f"ch{i} spectrum (SFDR-relevant spurs annotated)")
        ax[i][1].set_xlabel("MHz"); ax[i][1].grid(alpha=0.3, lw=0.4)
        n2 = min(len(c), 8 * 65536)
        ax[i][2].specgram(c[:n2], NFFT=1024, Fs=fs_mhz, noverlap=512, cmap="viridis")
        ax[i][2].set_title(f"ch{i} spectrogram (drift / instability)")
        ax[i][2].set_xlabel("s"); ax[i][2].set_ylabel("MHz")
    fig.suptitle(title, fontsize=11, weight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(out, dpi=120); plt.close(fig)
    print(f"[rx_explore] wrote {out}")


def synth(chans, fs):
    """codec-like model: 2 tones on ch0, 2 different tones on ch1, 12-bit grid."""
    rng = np.random.default_rng(11)
    n = int(0.02 * fs)
    out = []
    for i, (k1, k2) in enumerate([(913, 1500), (733, 1877)]):
        t = np.arange(n) / fs
        x = 0.3 * np.exp(2j * np.pi * k1 * 1e3 * t) + 0.15 * np.exp(2j * np.pi * k2 * 1e3 * t)
        x += 0.01 * np.exp(2j * np.pi * (2 * k1) * 1e3 * t)     # a real 2nd harmonic
        x *= 16384
        q = np.round(x.real / 16) * 16 + 1j * (np.round(x.imag / 16) * 16)   # 12-bit codes
        q = q + rng.normal(0, 6, n) * 16                        # codec dither
        out.append(q.astype(np.complex64))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--args", default="type=b200")
    ap.add_argument("--out", default="build/hw-probe")
    ap.add_argument("--ch", type=int, choices=(1, 2), default=1,
                    help="1 = single channel at FULL 61.44 MSPS; 2 = MIMO 2 x 30.72")
    ap.add_argument("--freq", type=float, default=1e9, help="RX RF frequency Hz")
    ap.add_argument("--gain", type=float, default=0.0, help="analog gain dB")
    ap.add_argument("--rate", type=float, default=61.44e6, help="master clock rate")
    ap.add_argument("--bw", type=float, default=0.0, help="analog bandwidth Hz (0 = default)")
    ap.add_argument("--secs", type=float, default=0.05)
    ap.add_argument("--dc-i", type=float, default=None, help="ch0 DC offset I (-1..1)")
    ap.add_argument("--dc-q", type=float, default=None, help="ch0 DC offset Q (-1..1)")
    ap.add_argument("--synthetic", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    if a.synthetic:
        chans = synth(None, FS_MAX)
        fs_mhz = FS_MAX / 1e6
        make_fig(chans, fs_mhz, os.path.join(a.out, "rx_explore.png"),
                 f"rx_explore synthetic self-test - {a.ch} channel mode model, "
                 f"rate {fs_mhz:.2f} MSPS")
        return 0

    import uhd
    usrp = uhd.usrp.MultiUSRP(a.args)
    nch = min(a.ch, usrp.get_rx_num_channels())
    rate = a.rate if (a.ch == 1 or a.rate <= 30.72e6) else 30.72e6
    for ch in range(nch):
        usrp.set_rx_rate(rate, ch)
        usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), ch)
        usrp.set_rx_gain(a.gain, ch)
        if a.bw: usrp.set_rx_bandwidth(a.bw, ch)
        if a.dc_i is not None and hasattr(usrp, "set_rx_dc_offset"):
            usrp.set_rx_dc_offset(True if a.dc_i is None else (a.dc_i, a.dc_q), ch)
    print(f"[rx_explore] {nch} ch, rate {usrp.get_rx_rate(0)/1e6:.2f} MSPS, "
          f"freq {usrp.get_rx_freq(0)/1e6:.3f} MHz, gain {usrp.get_rx_gain(0)} dB")

    nsamps = int(a.secs * usrp.get_rx_rate(0))
    st = uhd.usrp.StreamArgs("fc32", "sc16")
    st.channels = list(range(nch))
    streamer = usrp.get_rx_stream(st)
    buf = [np.zeros(nsamps, dtype=np.complex64) for _ in range(nch)]
    md = uhd.types.RXMetadata()
    cmd = uhd.types.StreamCMD(uhd.types.StreamCMD.num_samps_done)
    cmd.num_samps = nsamps; cmd.stream_now = True
    usrp.issue_stream_cmd(cmd)
    got = streamer.recv(buf, md, 5.0)
    usrp.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamCMD.mode_stop_cont))
    print(f"[rx_explore] got {got}/{nsamps}, err {md.error_code}")
    chans = [b[:got] for b in buf]
    make_fig(chans, usrp.get_rx_rate(0) / 1e6, os.path.join(a.out, "rx_explore.png"),
             f"rx_explore - {nch} channel(s) @ {usrp.get_rx_rate(0)/1e6:.2f} MSPS, "
             f"{usrp.get_rx_freq(0)/1e6:.3f} MHz, gain {usrp.get_rx_gain(0)} dB")
    for i, c in enumerate(chans):
        np.save(os.path.join(a.out, f"explore_ch{i}.npy"), c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
