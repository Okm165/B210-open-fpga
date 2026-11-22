#!/usr/bin/env python3
"""rx_quality.py - signal quality analysis of captured RX data.

Reads the .npy captures produced by rx_capture.py and reports, per channel:
  - noise floor, DC offset, RMS/peak, code utilisation
  - SNR (integrated signal vs noise over the observed band)
  - SFDR (largest spur vs carrier/DC reference)
  - ENOB estimate from SNR
  - IQ image rejection (amplitude/phase imbalance)
  - top spurs with frequency
and, for dual captures, cross-channel correlation (both channels share the
B210's single LO, so they must NOT be identical).

Usage:
  python3 scripts/rx_quality.py build/rx/dod_dual_fullrate/*.npy
  python3 scripts/rx_quality.py --dir build/rx/dod_dual_fullrate --tag rx_2ch_30.72msps_100.0mhz
"""
import argparse
import glob
import json
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FULL = 32768.0


def analyse(x, fs):
    n = len(x)
    dc = complex(np.mean(x))
    xc = x - dc
    rms = float(np.sqrt(np.mean(np.abs(xc) ** 2)))
    peak = float(np.max(np.abs(x)))
    q = np.abs(xc)

    win = np.hanning(n)
    X = np.fft.fftshift(np.fft.fft(xc * win))
    mag = np.abs(X) / (n * FULL)
    db = 20 * np.log10(np.maximum(mag, 1e-18))
    f = np.fft.fftshift(np.fft.fftfreq(n, 1 / fs))

    # noise floor = median of the spectrum (robust against narrow spurs)
    floor = float(np.median(db))
    # total signal power vs noise power (spectral integration)
    p_tot = float(np.sum(mag ** 2))
    noise_bins = db < (floor + 6.0)          # exclude spurs from noise estimate
    p_noise = float(np.sum(mag[noise_bins] ** 2)) / max(np.mean(noise_bins), 1e-9)
    snr = 10 * np.log10(max(p_tot, 1e-30) / max(p_noise, 1e-30))

    # spurs: local maxima well above the floor
    order = np.argsort(db)[::-1]
    spurs = []
    used = []
    for i in order:
        if db[i] < floor + 10:
            break
        if any(abs(i - j) < 8 for j in used):
            continue
        used.append(i)
        spurs.append({"f_mhz": float(f[i] / 1e6), "db": float(db[i])})
        if len(spurs) >= 8:
            break
    sfdr = float(spurs[0]["db"] - floor) if spurs else 0.0
    enob = (snr - 1.76) / 6.02

    # IQ imbalance -> image rejection
    # compare positive and negative frequency power around DC symmetry
    half = n // 2
    pos = float(np.sum(mag[half:] ** 2))
    neg = float(np.sum(mag[:half] ** 2))
    irr = 10 * np.log10(max(pos, neg) / max(min(pos, neg), 1e-30))

    return dict(n=int(n), fs=float(fs), dc_i=float(dc.real), dc_q=float(dc.imag),
                rms=rms, peak=peak, crest=float(peak / max(rms, 1e-12)),
                noise_floor_dbfs=floor, snr_db=snr, sfdr_db=sfdr, enob=enob,
                iq_imbalance_db=irr, spurs=spurs,
                codes=int(len(np.unique(np.ascontiguousarray(xc).view(np.float32)))))


def graph(results, fs, outdir, tag):
    os.makedirs(outdir, exist_ok=True)
    chans = [k for k in results if not k.startswith("_")]
    fig, ax = plt.subplots(len(chans), 2, figsize=(16, 4 * len(chans)), squeeze=False)
    for r, ch in enumerate(chans):
        x = results[ch]["_data"]
        n = min(len(x), 1 << 18)
        xc = x[:n] - np.mean(x[:n])
        w = np.hanning(n)
        X = np.fft.fftshift(np.fft.fft(xc * w))
        db = 20 * np.log10(np.maximum(np.abs(X) / (n * FULL), 1e-18))
        f = np.fft.fftshift(np.fft.fftfreq(n, 1 / fs)) / 1e6
        ax[r, 0].plot(f, db, lw=0.35, color="#1f4e79")
        for s in results[ch]["spurs"][:5]:
            ax[r, 0].annotate(f"{s['db']:.1f}", (s["f_mhz"], s["db"]), fontsize=6,
                              xytext=(3, 3), textcoords="offset points")
        ax[r, 0].axhline(results[ch]["noise_floor_dbfs"], color="grey", ls="--", lw=0.6)
        ax[r, 0].set_title(f"{ch}: PSD + spurs (floor {results[ch]['noise_floor_dbfs']:.1f} dBFS)")
        ax[r, 0].set_xlabel("MHz"); ax[r, 0].set_ylabel("dBFS")
        ax[r, 0].grid(alpha=0.25, lw=0.3)

        # zoom on the passband (DC +/- 5 MHz) to see the noise shape
        m = np.abs(f) < 5
        ax[r, 1].plot(f[m], db[m], lw=0.4, color="#b3541e")
        ax[r, 1].set_title(f"{ch}: zoom +/-5 MHz | SNR {results[ch]['snr_db']:.1f} dB, "
                           f"SFDR {results[ch]['sfdr_db']:.1f} dB, ENOB {results[ch]['enob']:.1f} b, "
                           f"IQ img {results[ch]['iq_imbalance_db']:.1f} dB")
        ax[r, 1].set_xlabel("MHz"); ax[r, 1].grid(alpha=0.25, lw=0.3)
    fig.suptitle(f"RX signal quality - {tag}", fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    p = os.path.join(outdir, f"quality_{tag}.png")
    fig.savefig(p, dpi=110)
    plt.close(fig)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--dir")
    ap.add_argument("--tag")
    ap.add_argument("--rate", type=float, default=30.72e6)
    ap.add_argument("--out")
    a = ap.parse_args()

    files = a.files
    if a.dir:
        tag = a.tag or ""
        pat = os.path.join(a.dir, f"*{tag}*ch*.npy")
        files = sorted(glob.glob(pat))
    if not files:
        raise SystemExit("no .npy captures found")

    results = {}
    for fpath in files:
        x = np.load(fpath)
        ch = os.path.basename(fpath).replace(".npy", "")
        r = analyse(x, a.rate)
        r["_data"] = x
        results[ch] = r

    if len(results) == 2:
        ks = list(results)
        a0, a1 = results[ks[0]]["_data"], results[ks[1]]["_data"]
        m = min(len(a0), len(a1), 200000)
        c = np.corrcoef(np.ascontiguousarray(a0[:m]).view(np.float32),
                        np.ascontiguousarray(a1[:m]).view(np.float32))[0, 1]
        results["_cross_channel_corr"] = float(c)

    outdir = a.out or (a.dir or os.path.dirname(files[0]))
    tag = a.tag or os.path.basename(os.path.normpath(outdir))
    p = graph(results, a.rate, outdir, tag)

    summary = {k: ({kk: vv for kk, vv in v.items() if kk != "_data"}
                   if isinstance(v, dict) else v)
               for k, v in results.items()}
    with open(os.path.join(outdir, f"quality_{tag}.json"), "w") as fh:
        json.dump(summary, fh, indent=2)

    for k, v in results.items():
        if k.startswith("_"):
            print(f"[quality] {k} = {v:.4f}")
            continue
        print(f"[quality] {k}: n={v['n']} fs={v['fs']/1e6:.2f} MSPS  "
              f"floor={v['noise_floor_dbfs']:.1f} dBFS  SNR={v['snr_db']:.1f} dB  "
              f"SFDR={v['sfdr_db']:.1f} dB  ENOB={v['enob']:.1f} b  "
              f"DC=({v['dc_i']:.1f},{v['dc_q']:.1f})  IQimg={v['iq_imbalance_db']:.1f} dB  "
              f"codes={v['codes']}")
        for s in v["spurs"][:3]:
            print(f"    spur {s['f_mhz']:+.3f} MHz at {s['db']:.1f} dBFS")
    print(f"[quality] graph: {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
