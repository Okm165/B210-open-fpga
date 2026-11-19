#!/usr/bin/env python3
"""plot-diff.py - the ends of the loop, and every difference attributed to a hop.

The spectra pages show the stages; this page answers *why the output is not the
input*.  It pairs consecutive captured nodes and fits each hop with the model
that hop is supposed to implement:

  * an integer delay plus one complex gain (widening, filtering, pin scaling);
  * the same after removing the mixer's frequency shift (the mixers are not
    time-invariant at baseband - a constant gain cannot fit a shift);
  * for the channel, the explicit integer model the bench injects.

A hop that fits is a hop the RTL implements exactly up to the printed EVM; a
hop that does not fit is where a difference comes from.  The end-to-end
difference is then the composition of the hops, not a mystery.

Two measurement rules learned the hard way:
  * the lag is searched over a full stimulus period - the capture starts on an
    arbitrary clock and a wrong lag rotates every tone differently;
  * the mixer's shift is removed before fitting, because exp(j*w*n) is not a
    constant.
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

L = 1024
NT = 7
K0 = [8, 24, 47, 83, 115, 138, 150]
K1 = [13, 31, 59, 97, 124, 143, 149]
IF = 128
FS = 61.44e6


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    d = np.loadtxt(path, dtype=np.int64)
    if d.ndim == 1:
        d = d.reshape(1, -1)
    return d[:, 0].astype(float) + 1j * d[:, 1].astype(float)


def db(x):
    return 20.0 * np.log10(np.maximum(np.abs(x), 1e-12))


def fit_hop(a, b, derot=0):
    """Best integer delay and complex gain for b[n] = g*a[n-lag]*exp(j*derot*n)."""
    n = min(len(a), len(b))
    t = np.arange(n)
    bd = b[:n] * np.exp(-1j * derot * t)
    best = None
    for lag in range(0, L + 64):
        x = a[:n - lag]
        y = bd[lag:n]
        x0 = x - x.mean()
        den = np.vdot(x0, x0)
        g = np.vdot(x0, y - y.mean()) / den if den else 0
        e = np.mean(np.abs(y - y.mean() - g * x0) ** 2)
        if best is None or e < best[0]:
            best = (e, lag, g)
    e, lag, g = best
    x = a[:n - lag] - a[:n - lag].mean()
    y = bd[lag:n]
    resid = y - y.mean() - g * x
    sig = np.sqrt(np.mean(np.abs(g * x) ** 2))
    return lag, g, np.sqrt(np.mean(np.abs(resid) ** 2)) / max(sig, 1e-12)


def tone_fit(x):
    n = len(x)
    t = np.arange(n)
    A = []
    for kk in K0 + K1:
        A += [np.exp(1j * 2 * np.pi * kk * t / L), np.exp(-1j * 2 * np.pi * kk * t / L)]
    A = np.stack(A, axis=1)
    sol, *_ = np.linalg.lstsq(A, x, rcond=None)
    return sol, A @ sol, x - A @ sol


def hop_rows(fwd):
    base = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "build", "plots"))
    tag = "fwd_x1" if fwd else "rev"

    def ld(suf):
        return load(os.path.join(base, f"cap_{tag}_{suf}.txt"))

    host, hb, mix, pins = ld("host"), ld("tx_hb"), ld("tx_mix"), ld("tx_pins")
    air, rxmix, rxhost = ld("air"), ld("rx_mix"), ld("rx_host")
    w = 2 * np.pi * IF / L
    rows = []
    if fwd:
        rows.append(("host -> TX interp (widen x4)",) + fit_hop(host, hb))
        rows.append(("TX interp -> mixer (shift removed)",) + fit_hop(hb, mix, +w))
        rows.append(("mixer -> pin word (scale x64)",) + fit_hop(mix, pins))
        rows.append(("RX in -> mixer (shift removed)",) + fit_hop(air, rxmix, -w))
        rows.append(("RX mixer -> host (1/256 + dither)",) + fit_hop(rxmix, rxhost))
    else:
        rows.append(("RX in -> mixer (shift removed)",) + fit_hop(air, rxmix, -w))
        rows.append(("RX mixer -> host (1/256 + dither)",) + fit_hop(rxmix, rxhost))
        rows.append(("host -> TX interp (widen x4)",) + fit_hop(rxhost, hb))
        rows.append(("TX interp -> mixer (shift removed)",) + fit_hop(hb, mix, +w))
        rows.append(("mixer -> pin word (scale x64)",) + fit_hop(mix, pins))
    return rows


def ends_panel(ax_wave, ax_spec, ax_tone, tag, fwd):
    base = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "build", "plots"))
    if fwd:
        src = load(os.path.join(base, f"cap_{tag}_host.txt"))
        out = load(os.path.join(base, f"cap_{tag}_rx_host.txt"))
        lab_in, lab_out, lsb = "host word in", "RX host word out", 1.0
    else:
        # the antenna node already carries the channel (echo + coupling), so the
        # reference for "what arrived at the end unchanged" is that node
        src = load(os.path.join(base, f"cap_{tag}_air.txt"))
        out = load(os.path.join(base, f"cap_{tag}_tx_pins.txt")) / 256.0
        lab_in, lab_out, lsb = "antenna in", "TX pins / 256", 1.0

    # tone-basis fit: the residual is everything that is not the 28 tones
    sol, fit, err = tone_fit(out)
    evm = 20 * np.log10(np.sqrt(np.mean(np.abs(err) ** 2)) /
                        np.sqrt(np.mean(np.abs(fit) ** 2)))
    print(f"\n=== {tag}: {lab_in} -> {lab_out} ===")
    print(f"  28-tone fit: residual {evm:.1f} dB below the tones, "
          f"{np.sqrt(np.mean(np.abs(err)**2))/lsb:.2f} LSB rms")

    m = 160
    ax_wave.plot(np.arange(m), out[:m].real, ".", ms=2.5, color="#1f4e79", label="out I")
    ax_wave.plot(np.arange(m), fit[:m].real, "-", lw=0.9, color="#c00000", label="tone fit I")
    ax_wave.set_title(f"{lab_out}: residual {evm:.1f} dB, {np.sqrt(np.mean(np.abs(err)**2)):.2f} LSB rms",
                      fontsize=9)
    ax_wave.set_xlabel("sample")
    ax_wave.set_ylabel("LSB")
    ax_wave.legend(fontsize=6.5, ncol=2)
    ax_wave.grid(alpha=0.25, lw=0.4)
    ax_wave.tick_params(labelsize=7)

    n = len(err)
    E = np.fft.fftshift(np.fft.fft(err)) / n
    f = np.fft.fftshift(np.fft.fftfreq(n, 1 / FS))
    ref = np.sqrt(np.mean(np.abs(fit) ** 2))
    ax_spec.plot(f / 1e6, db(E / ref), lw=0.6, color="#7030a0")
    ax_spec.set_title(f"residual spectrum (worst {db(E/ref).max():.0f} dBc)", fontsize=9)
    ax_spec.set_xlabel("MHz")
    ax_spec.set_ylabel("dBc")
    ax_spec.set_ylim(-140, -40)
    ax_spec.grid(alpha=0.25, lw=0.4)
    ax_spec.tick_params(labelsize=7)

    # per-tone level and phase relative to the injected tone set
    amps, phases, ks = [], [], []
    t = np.arange(n)
    for k in K0:
        wgt = np.exp(-2j * np.pi * k * t / L)
        a = np.mean(out * wgt)
        # the pin word is the host word x256, so compare in the same units
        b = np.mean(src[:n] * wgt) * (1.0 if fwd else 1.0/256.0)
        # the reference is the signal that actually entered the loop at that bin
        amps.append(20 * np.log10(max(abs(a) / max(abs(b), 1e-9), 1e-9)))
        phases.append(np.degrees(np.angle(a * np.conj(b))))
        ks.append(k)
    ax_tone.plot(ks, amps, "o-", ms=3, color="#1f4e79")
    ax_tone.axhline(0, color="k", lw=0.6)
    ax_tone.set_xlabel("tone bin")
    ax_tone.set_ylabel("level vs injected, dB")
    ax_tone.set_title(f"level of each injected tone at the end: spread "
                      f"{max(amps) - min(amps):.2f} dB", fontsize=8.5)
    ax_tone.grid(alpha=0.25, lw=0.4)
    ax_tone.tick_params(labelsize=7)
    print("  per-tone level vs injected (dB): " +
          ", ".join(f"{x:+.2f}" for x in amps))


def main():
    base = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "build", "plots"))
    fig, axs = plt.subplots(3, 3, figsize=(15, 11.5))
    fig.suptitle("the ends of the loop, and every difference attributed to a hop", fontsize=12)
    ends_panel(axs[0][0], axs[0][1], axs[0][2], "fwd_x1", True)
    ends_panel(axs[1][0], axs[1][1], axs[1][2], "rev", False)

    for ax, fwd, title in ((axs[2][0], True, "forward loop, hop by hop"),
                           (axs[2][1], False, "reverse loop, hop by hop")):
        rows = hop_rows(fwd)
        y = np.arange(len(rows))
        vals = [db(r[3]) if r[3] > 0 else None for r in rows]
        for i, v in enumerate(vals):
            if v is not None:
                ax.barh(i, v, color="#1f4e79")
        ax.set_yticks([])
        ax.set_xlim(-160, 0)
        ax.set_xlabel("residual added by that hop, dBc", labelpad=12)
        ax.set_title(title, fontsize=9)
        ax.grid(alpha=0.25, lw=0.4, axis="x")
        ax.tick_params(labelsize=7)
        print(f"\n--- {title} ---")
        for r in rows:
            lab, lag, g, ev = r
            print(f"  {lab:38s} lag {lag:4d}  gain {abs(g):10.6f}  "
                  f"phase {np.degrees(np.angle(g)):+8.3f}  residual "
                  f"{db(ev) if ev > 0 else -999:7.1f} dBc")
            if ev > 0:
                ax.text(min(db(ev) + 2, -2), y[rows.index(r)], f"{db(ev):.0f}",
                        va="center", fontsize=6.5)
        for i, (r, v) in enumerate(zip(rows, vals)):
            ax.text(-157, i, r[0], va="center", fontsize=6.5)
            if v is None:
                ax.text(-6, i, "exact", va="center", ha="right", fontsize=6.5,
                        color="#00a651")
            else:
                ax.text(v + 1.5, i, f"{v:.0f} dBc", va="center", fontsize=6.5)
    axs[2][2].axis("off")
    fig.tight_layout(rect=[0, 0.01, 1, 0.96])
    out = os.path.join(base, "loop_ends_diff.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print(f"\n  wrote {os.path.relpath(out)}")


if __name__ == "__main__":
    main()
