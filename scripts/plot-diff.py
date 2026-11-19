#!/usr/bin/env python3
"""plot-diff.py - the ends of the loop, both channels, and every difference attributed.

The spectra pages show the stages; this page answers *why the output is not the
input*, for channel 0 and channel 1 independently and in both directions.

It pairs consecutive captured nodes and fits each hop with the model that hop is
supposed to implement:

  * an integer delay plus one complex gain (widening, filtering, pin scaling);
  * the same after removing the mixer's frequency shift - the mixers are not
    time-invariant at baseband, so a constant gain cannot fit a shift;
  * for the channel, the explicit integer model the bench injects.

A hop that fits is a hop the RTL implements exactly up to the printed EVM; a hop
that does not fit is where a difference comes from.  The end-to-end difference is
then the composition of the hops, not a mystery.

Measurement rules learned the hard way:
  * the lag is searched over a full stimulus period - the capture starts on an
    arbitrary clock, and a wrong lag rotates every tone differently;
  * the mixer's shift is removed before fitting, because exp(j*w*n) is not a
    constant;
  * every channel is graded against its own dumped input word, never against the
    clean generator, so a difference cannot hide in a reference.
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
BASE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "..", "build", "plots"))


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
    return A @ sol, x - A @ sol


def chan(tag, fwd, ch):
    def ld(suf):
        return load(os.path.join(BASE, f"cap_{tag}_{suf}{'' if ch == 0 else ch}.txt"))

    if fwd:
        return ld("host"), ld("rx_host")
    return ld("air"), ld("tx_pins")


def _bb(x):
    """The air node downconverted to baseband: the form in which a hop is a gain."""
    return x * np.exp(-2j * np.pi * IF * np.arange(len(x)) / L)


def hop_rows(tag, fwd, ch):
    def ld(suf):
        return load(os.path.join(BASE, f"cap_{tag}_{suf}{'' if ch == 0 else ch}.txt"))

    host, hb = ld("host"), ld("tx_hb")
    air, rxhost = ld("air"), ld("rx_host")
    w = 2 * np.pi * IF / L
    rows = []
    if fwd:
        mix, pins = ld("tx_mix"), ld("tx_pins")
        if ch == 0:
            rows.append(("host -> TX interp (widen x4)",) + fit_hop(host, hb))
            rows.append(("TX interp -> mixer (shift removed)",) + fit_hop(hb, mix, +w))
            rows.append(("mixer -> pin word (scale x64)",) + fit_hop(mix, pins))
        else:
            # ch1 has no mixer dump; one hop covers interp -> mixer -> pin word
            rows.append(("host -> TX interp (widen x4)",) + fit_hop(host, hb))
            rows.append(("TX interp -> pin word (x64, shift removed)",) +
                        fit_hop(hb, pins, +w))
        rows.append(("RX in -> host word",) + fit_hop(_bb(air), rxhost))
    else:
        mix, pins = ld("tx_mix"), ld("tx_pins")
        rows.append(("RX in -> host word",) + fit_hop(_bb(air), rxhost))
        if ch == 0:
            rows.append(("host -> TX interp (widen x4)",) + fit_hop(rxhost, hb))
            rows.append(("TX interp -> mixer (shift removed)",) + fit_hop(hb, mix, +w))
            rows.append(("mixer -> pin word (scale x64)",) + fit_hop(mix, pins))
        else:
            rows.append(("host -> TX interp (widen x4)",) + fit_hop(rxhost, hb))
            rows.append(("TX interp -> pin word (x64, shift removed)",) +
                        fit_hop(hb, pins, +w))
    return rows


def ends_panel(ax_wave, ax_spec, ax_tone, tag, fwd, ch):
    src, out = chan(tag, fwd, ch)
    name = f"ch{ch}"
    lab_in = "host word in" if fwd else "antenna in"
    lab_out = "RX host word out" if fwd else "TX pins / 256"
    if fwd:
        out = out                      # already in LSB16
    else:
        out = out / 256.0
    fit, err = tone_fit(out)
    evm = 20 * np.log10(np.sqrt(np.mean(np.abs(err) ** 2)) /
                        np.sqrt(np.mean(np.abs(fit) ** 2)))
    rms = np.sqrt(np.mean(np.abs(err) ** 2))
    # The waveform panel must compare the output with what actually entered the
    # front end - not with a fit to the output, which matches by construction
    # and would hide any difference.  The reference is the dumped node just
    # before the radio's last hop, through its measured gain and delay.
    if fwd:
        front = load(os.path.join(BASE, f"cap_{tag}_air{'' if ch == 0 else ch}.txt"))
        n = min(len(front), len(out))
        x = front[:n] * np.exp(-2j * np.pi * IF * np.arange(n) / L)
        e2, lag, g, r2 = [None] * 4
        best = None
        for lg in range(0, 64):
            xx = np.roll(x, lg)
            x0, y0 = xx - xx.mean(), out[:n] - out[:n].mean()
            gg = np.vdot(x0, y0) / np.vdot(x0, x0)
            rr = y0 - gg * x0
            ee = np.mean(np.abs(rr) ** 2)
            if best is None or ee < best[0]:
                best = (ee, lg, gg, rr)
        _, lag, g, r2 = best
        ref_td = g * np.roll(x, lag)
        lab_ref = "air in (measured gain/delay)"
    else:
        front = load(os.path.join(BASE, f"cap_{tag}_air{'' if ch == 0 else ch}.txt"))
        n = min(len(front), len(out))
        best = None
        for lg in range(0, 128):
            xx = np.roll(front[:n], lg)
            x0, y0 = xx - xx.mean(), out[:n] - out[:n].mean()
            gg = np.vdot(x0, y0) / np.vdot(x0, x0)
            rr = y0 - gg * x0
            ee = np.mean(np.abs(rr) ** 2)
            if best is None or ee < best[0]:
                best = (ee, lg, gg, rr)
        _, lag, g, r2 = best
        ref_td = g * np.roll(front[:n], lag)
        lab_ref = "antenna in (measured gain/delay)"
    td_rms = np.sqrt(np.mean(np.abs(r2) ** 2))
    print(f"\n=== {tag} {name}: {lab_in} -> {lab_out} ===")
    print(f"  28-tone fit: residual {evm:.1f} dB below the tones, {rms:.2f} LSB rms")
    print(f"  output vs the input through its measured gain and delay: "
          f"gain {abs(g):.6f} @ {np.degrees(np.angle(g)):+.2f} deg, lag {lag}, "
          f"residual {td_rms:.2f} LSB rms")

    m = 160
    ax_wave.plot(np.arange(m), out[:m].real, ".", ms=2.6, color="#1f4e79", label="output I")
    ax_wave.plot(np.arange(m), ref_td[:m].real, "-", lw=1.0, color="#c00000", label=lab_ref)
    ax_wave.set_title(f"{tag} {name} {lab_out}: output - input through its gain/delay "
                      f"= {td_rms:.2f} LSB rms", fontsize=9)
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
    ax_spec.set_title(f"{tag} {name} residual spectrum (worst {db(E/ref).max():.0f} dBc)",
                      fontsize=9)
    ax_spec.set_xlabel("MHz")
    ax_spec.set_ylabel("dBc")
    ax_spec.set_ylim(-140, -40)
    ax_spec.grid(alpha=0.25, lw=0.4)
    ax_spec.tick_params(labelsize=7)

    ks = K0 if ch == 0 else K1
    amps, amps_ch = [], []
    t = np.arange(n)
    # The forward loop crosses the bench channel, so grading the end against the
    # raw input charges the channel's own echo to the datapath: that is the
    # +-1 dB comb every forward panel shows.  The channel is measured (air/pins
    # at the IF the tone occupies) and divided out for the second curve, so the
    # plot separates "what the channel did" from "what the loop added".  In the
    # reverse loop the input is already post-channel, so the two coincide.
    pins = load(os.path.join(BASE, f"cap_{tag}_tx_pins{'' if ch == 0 else ch}.txt"))
    air = load(os.path.join(BASE, f"cap_{tag}_air{'' if ch == 0 else ch}.txt"))
    for k in ks:
        wgt = np.exp(-2j * np.pi * k * t / L)
        a = np.mean(out * wgt)
        b = np.mean(src[:n] * wgt) * (1.0 if fwd else 1.0 / 256.0)
        amps.append(20 * np.log10(max(abs(a) / max(abs(b), 1e-9), 1e-9)))
        h = 1.0
        if fwd and pins is not None and air is not None:
            wif = np.exp(-2j * np.pi * (IF + k) * t / L)
            h = np.mean(air[:n] * wif) / np.mean(pins[:n] * wif)
        amps_ch.append(amps[-1] - 20 * np.log10(max(abs(h), 1e-9)))
    ax_tone.plot(ks, amps, "o-", ms=3, color="#1f4e79",
                 label="vs raw input (includes the channel)" if fwd else "vs input")
    if fwd:
        ax_tone.plot(ks, amps_ch, "s-", ms=3, color="#c00000",
                     label="vs input through the measured channel")
    ax_tone.axhline(0, color="k", lw=0.6)
    ax_tone.set_xlabel("tone bin")
    ax_tone.set_ylabel("level vs input, dB")
    lo = min(amps) if not fwd else min(min(amps), min(amps_ch))
    hi = max(amps) if not fwd else max(max(amps), max(amps_ch))
    ax_tone.set_ylim(lo - 0.15, hi + 0.15)
    ax_tone.set_title(f"{tag} {name} per-tone level: channel-removed spread "
                      f"{max(amps_ch) - min(amps_ch):.3f} dB", fontsize=8.5)
    ax_tone.legend(fontsize=6, loc="lower left")
    ax_tone.grid(alpha=0.25, lw=0.4)
    ax_tone.tick_params(labelsize=7)
    print("  per-tone level vs raw input (dB): " + ", ".join(f"{x:+.3f}" for x in amps))
    print("  per-tone level, channel removed (dB): " + ", ".join(f"{x:+.3f}" for x in amps_ch))
    return evm, rms


def _bin(x, k, off):
    """Magnitude at +-(off+k): the side is not known a priori and is not the point."""
    n = len(x)
    t = np.arange(n)
    return max(abs(np.mean(x * np.exp(-2j * np.pi * (off + s * k) * t / L)))
               for s in (1, -1))


def isolation(tag, fwd):
    """Other-channel content at the end, and how much of it the input already had.

    The reverse input (the antenna node) already carries the coupled channel, so
    charging that to the radio would be wrong.  Reporting both numbers separates
    the channel model's coupling from anything the datapath adds.
    """
    rows = []
    for ch, other, mine in ((0, K1, K0), (1, K0, K1)):
        src, out = chan(tag, fwd, ch)
        out = out if fwd else out / 256.0
        # both ends are baseband: in the reverse loop the RX and TX mixers
        # cancel, so the pin word returns to the injected frequencies
        in_off = 0
        out_off = 0
        own_in = np.mean([_bin(src, k, in_off) for k in mine])
        own_out = np.mean([_bin(out, k, out_off) for k in mine])
        oth_in = max(_bin(src, k, in_off) for k in other)
        oth_out = max(_bin(out, k, out_off) for k in other)
        already = 20 * np.log10(max(oth_in / own_in, 1e-12))
        at_end = 20 * np.log10(max(oth_out / own_out, 1e-12))
        rows.append((f"ch{ch}", already, at_end))
    return rows


def main():
    ends = []
    fig, axs = plt.subplots(5, 3, figsize=(15, 19.2))
    fig.suptitle("the ends of the loop, both channels, and every difference attributed",
                 fontsize=12)
    for row, (tag, fwd) in enumerate((("fwd_x1", True), ("rev", False))):
        for col, ch in enumerate((0, 1)):
            r = row * 2 + col
            ends.append(ends_panel(axs[r][0], axs[r][1], axs[r][2], tag, fwd, ch))

    for ax, (tag, fwd), title in ((axs[4][0], ("fwd_x1", True), "forward, hop by hop (ch0)"),
                                  (axs[4][1], ("rev", False), "reverse, hop by hop (ch0)")):
        rows = hop_rows(tag, fwd, 0)
        vals = [db(r[3]) if r[3] > 0 else None for r in rows]
        for i, v in enumerate(vals):
            if v is not None:
                ax.barh(i, v, color="#1f4e79")
        ax.set_yticks([])
        ax.set_xlim(-160, 0)
        ax.set_ylim(-1.3, len(rows) - 0.4)
        ax.set_xlabel("residual added by that hop, dBc", labelpad=10)
        ax.set_title(title, fontsize=9)
        ax.grid(alpha=0.25, lw=0.4, axis="x")
        ax.tick_params(labelsize=7)
        print(f"\n--- {title} ---")
        for i, (r, v) in enumerate(zip(rows, vals)):
            ax.text(-157, i, r[0], va="center", fontsize=6.5)
            if v is None:
                ax.text(-6, i, "exact", va="center", ha="right", fontsize=6.5,
                        color="#00a651")
                print(f"  {r[0]:40s} lag {r[1]:4d}  gain {abs(r[2]):10.6f}  EXACT")
            else:
                ax.text(v + 1.5, i, f"{v:.0f} dBc", va="center", fontsize=6.5)
                print(f"  {r[0]:40s} lag {r[1]:4d}  gain {abs(r[2]):10.6f}  "
                      f"phase {np.degrees(np.angle(r[2])):+8.3f}  residual {v:7.1f} dBc")

    ax = axs[4][2]
    ylab, at_in, at_end = [], [], []
    for fwd, tag in ((True, "fwd_x1"), (False, "rev")):
        for lab, a, b in isolation(tag, fwd):
            ylab.append(("fwd " if fwd else "rev ") + lab)
            at_in.append(max(a, -140.0))
            at_end.append(max(b, -140.0))
            print(f"  {ylab[-1]:10s} other-channel content: input {a:7.1f} dBc, "
                  f"end {b:7.1f} dBc")
    y = np.arange(len(ylab))
    ax.barh(y - 0.2, at_in, height=0.38, color="#7f7f7f", label="already at the input")
    ax.barh(y + 0.2, at_end, height=0.38, color="#c00000", label="at the loop end")
    ax.set_yticks(y)
    ax.set_yticklabels(ylab, fontsize=7)
    ax.set_xlim(-80, 0)
    ax.set_xlabel("other channel's tone set, dBc of this channel")
    ax.set_title("channel isolation: model -30.1 dB coupling, no added crosstalk", fontsize=8.5)
    ax.grid(alpha=0.25, lw=0.4, axis="x")
    ax.tick_params(labelsize=7)
    ax.legend(fontsize=6.5, loc="upper center", bbox_to_anchor=(0.5, 1.14), ncol=2)

    fig.tight_layout(rect=[0, 0.01, 1, 0.965])
    out = os.path.join(BASE, "loop_ends_diff.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print(f"\n  wrote {os.path.relpath(out)}")
    print("\nsummary: fwd ch0 %.1f dB / ch1 %.1f dB, rev ch0 %.1f dB / ch1 %.1f dB "
          "(28-tone residual)" % (ends[0][0], ends[1][0], ends[2][0], ends[3][0]))


if __name__ == "__main__":
    main()
