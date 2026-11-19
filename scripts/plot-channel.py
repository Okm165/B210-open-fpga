#!/usr/bin/env python3
"""plot-channel.py - what changes in mid air, and whether the radio changes anything.

The spectra pages show that the pin word and the antenna node differ and that
the forward end has a +-1 dB tilt across the band.  This page answers whether
any of that is the DSP, using only dumped nodes:

  1. the antenna node is recomputed from the pin words with the bench's exact
     integer channel (echo 1/8 at 3 samples, coupling 1/32) and compared sample
     by sample;
  2. the measured per-tone |air / pins| is compared with the analytic echo comb
     |1 - (1/8) exp(-j w 3)| across the occupied band, per channel;
  3. every remaining hop is fitted as a pure complex gain: air -> RX host
     (forward) and air -> TX pins (reverse).  A radio that filtered, drooped or
     distorted would not collapse to one gain with a dither-sized residual;
  4. the ends: the loop output divided by the measured channel, tone by tone.

Nothing here assumes a sign convention for the mixers: the references are the
nodes the bench actually produced.
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

L, IF = 1024, 128
K0 = [8, 24, 47, 83, 115, 138, 150]
K1 = [13, 31, 59, 97, 124, 143, 149]
E, C = 8, 32
BASE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "..", "build", "plots"))


def ld(suf):
    p = os.path.join(BASE, suf)
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None
    try:
        d = np.loadtxt(p, dtype=np.int64)
    except ValueError:
        raise SystemExit(f"capture {p!r} contains non-numeric values (x/z): the "
                         f"RTL was not fully initialised in that run")
    return d[:, 0].astype(float) + 1j * d[:, 1].astype(float)


def ld_raw(suf):
    return np.loadtxt(os.path.join(BASE, suf), dtype=np.int64)


def db(x):
    return 20.0 * np.log10(np.maximum(np.abs(x), 1e-12))


def tdiv(x, d):
    q = np.abs(x) // d
    return np.where(x < 0, -q, q)


def int_channel(pins0, pins1):
    n = len(pins0)
    out = np.zeros_like(pins0)
    for c in (0, 1):
        d = np.zeros(n, dtype=np.int64)
        d[3:] = pins0[:n - 3, c]
        m = pins0[:, c] - tdiv(d, E) + tdiv(pins1[:n, c], C)
        out[:, c] = np.clip(m, -8388608, 8388607)
    return out


def fit_gain(x, y, maxlag=64):
    n = min(len(x), len(y))
    y = y[:n]
    best = None
    for lag in range(maxlag):
        xx = np.roll(x[:n], lag)
        x0, y0 = xx - xx.mean(), y - y.mean()
        g = np.vdot(x0, y0) / np.vdot(x0, x0)
        r = y0 - g * x0
        e = np.mean(np.abs(r) ** 2)
        if best is None or e < best[0]:
            best = (e, lag, g, r)
    return best


def tone_fit(x):
    n = len(x)
    t = np.arange(n)
    A = []
    for kk in K0 + K1:
        A += [np.exp(2j * np.pi * kk * t / L), np.exp(-2j * np.pi * kk * t / L)]
    A = np.stack(A, axis=1)
    sol, *_ = np.linalg.lstsq(A, x, rcond=None)
    return A @ sol, x - A @ sol


def tone(x, k, sign, t):
    return np.mean(x * np.exp(-2j * np.pi * sign * k * t / L))


def main():
    fig, axs = plt.subplots(3, 2, figsize=(13.5, 12.8))
    fig.suptitle("mid-air change is the channel, bit for bit; each radio hop is one pure gain; the one line is a bench-precision artifact", fontsize=11)

    # ---- 1. bit-exact channel ---------------------------------------------
    p0, p1 = ld_raw("cap_fwd_x1_tx_pins.txt"), ld_raw("cap_fwd_x1_tx_pins1.txt")
    air = ld_raw("cap_fwd_x1_air.txt")
    model = int_channel(p0, p1)
    n = min(len(model), len(air))
    d = model[:n] - air[:n]
    exact = 100.0 * np.mean(d == 0)
    after = d[3:]
    bad_rows = int(np.sum(np.any(d != 0, axis=1)))
    print(f"air node = integer channel applied to the pin words: {exact:.3f} % identical, "
          f"{bad_rows} startup rows, worst |diff| after startup {int(np.abs(after).max())} LSB24")
    a = axs[0][0]
    a.hist(after.ravel(), bins=40, color="#1f4e79")
    a.set_yscale("log")
    a.set_title(f"antenna node rebuilt from the pin words\n"
                f"{exact:.2f} % identical; {bad_rows} unprimed rows; rest 0 LSB", fontsize=9)
    a.set_xlabel("model - dumped air, LSB24")
    a.set_ylabel("samples")
    a.grid(alpha=0.25, lw=0.4)
    a.tick_params(labelsize=7)

    # ---- 2. measured vs analytic comb -------------------------------------
    pins, pins1 = ld("cap_fwd_x1_tx_pins.txt"), ld("cap_fwd_x1_tx_pins1.txt")
    airs = [ld("cap_fwd_x1_air.txt"), ld("cap_fwd_x1_air1.txt")]
    nn = len(pins)
    t = np.arange(nn)
    b = axs[0][1]
    worst = 0.0
    for ch, K in ((0, K0), (1, K1)):
        meas, ana, ks = [], [], []
        for k in K:
            for s in (1, -1):
                # the antenna node lives at the transmit IF: project at IF + s*k
                r = (tone(airs[ch], (IF + s * k) % L, 1, t)
                     / tone(pins if ch == 0 else pins1, (IF + s * k) % L, 1, t))
                H = 1.0 - (1.0 / E) * np.exp(-2j * np.pi * ((IF + s * k) % L) * 3 / L)
                meas.append(db(r)); ana.append(db(H)); ks.append(s * k)
        o = np.argsort(ks)
        ks, meas, ana = np.array(ks)[o], np.array(meas)[o], np.array(ana)[o]
        worst = max(worst, float(np.max(np.abs(meas - ana))))
        b.plot(ks, meas, "o", ms=3.5, label=f"ch{ch} measured |air/pins|")
        b.plot(ks, ana, "-", lw=1.0, label=f"ch{ch} analytic echo comb")
    print(f"channel comb: measured vs analytic worst {worst:.4f} dB over all 28 tones")
    b.set_xlabel("tone bin (signed)")
    b.set_ylabel("|air / pins|, dB")
    b.set_title(f"the +-1 dB band tilt is the channel's echo\n"
                f"measured = analytic within {worst:.3f} dB at every tone", fontsize=9)
    b.grid(alpha=0.25, lw=0.4)
    b.legend(fontsize=6.3, ncol=2)
    b.tick_params(labelsize=7)

    # ---- 3. every remaining hop is one pure gain ---------------------------
    c = axs[1][0]
    rows = []
    for ch, suf in ((0, ""), (1, "1")):
        airch = ld(f"cap_fwd_x1_air{suf}.txt")
        y = ld(f"cap_fwd_x1_rx_host{suf}.txt")
        m = min(len(airch), len(y))
        x = airch[:m] * np.exp(-2j * np.pi * IF * np.arange(m) / L)
        e, lag, g, r = fit_gain(x, y)
        rows.append((f"fwd ch{ch} air -> host", abs(g), np.degrees(np.angle(g)),
                     np.sqrt(np.mean(np.abs(r) ** 2))))
    airr, pinr = ld("cap_rev_air.txt"), ld("cap_rev_tx_pins.txt") / 256.0
    e, lag, g, r = fit_gain(airr, pinr, 128)
    rows.append(("rev air -> pins (both mixers)", abs(g), np.degrees(np.angle(g)),
                 np.sqrt(np.mean(np.abs(r) ** 2))))
    for i, (lab, gg, ph, res) in enumerate(rows):
        print(f"  {lab:30s} gain {gg:.6f}  phase {ph:+.3f} deg  residual {res:.2f} LSB")
    ypos = np.arange(len(rows))
    c.barh(ypos, [np.log10(max(r[3], 1e-6)) for r in rows], color="#1f4e79")
    c.set_yticks(ypos)
    c.set_yticklabels([r[0] for r in rows], fontsize=7)
    c.set_xlabel("log10(residual, LSB)")
    c.set_title("each remaining hop is one gain (128..256):\n"
                "residual is the host dither, both channels, both directions", fontsize=9)
    for i, r in enumerate(rows):
        c.text(np.log10(max(r[3], 1e-6)) + 0.02, i,
               f"gain {r[1]:.6f} @ {r[2]:+.2f} deg, {r[3]:.2f} LSB",
               va="center", fontsize=6.5)
    c.set_xlim(-0.2, 1.2)
    c.grid(alpha=0.25, lw=0.4, axis="x")
    c.tick_params(labelsize=7)

    # ---- 4. the ends, divided by the measured channel ----------------------
    host, out = ld("cap_fwd_x1_host.txt"), ld("cap_fwd_x1_rx_host.txt")
    n2 = min(len(host), len(out))
    t2 = np.arange(n2)
    ratios, labs = [], []
    for k in K0:
        for s in (1, -1):
            x = tone(host, k, s, t2)
            y = tone(out, k, s, t2)
            # the channel measured at the air node for this tone (at the IF)
            H = (tone(airs[0], (IF + s * k) % L, 1, t)
                 / tone(pins, (IF + s * k) % L, 1, t))
            ratios.append(y / (x * H))
            labs.append(s * k)
    ratios = np.array(ratios)
    ks_arr = np.array(labs)
    # The loop's latency is two delays: tau_TX applied to the pin word (whose
    # tones sit at IF+sk) and tau_RX applied at baseband.  Fitting both makes
    # the per-tone phases collapse exactly; a single delay cannot, which is
    # what made the first versions of this page look like dispersion.
    best = None
    for tau1 in np.arange(0, 32, 0.1):
        for tau2 in np.arange(0, 32, 0.1):
            pred = -2 * np.pi * (IF * tau1 + ks_arr * (tau1 + tau2)) / L
            r = np.angle(np.exp(1j * (np.angle(ratios) - pred)))
            e = float(np.mean(r ** 2))
            if best is None or e < best[0]:
                best = (e, tau1, tau2)
    _, tau_tx, tau_rx = best
    pred = -2 * np.pi * (IF * tau_tx + ks_arr * (tau_tx + tau_rx)) / L
    phase_res = np.degrees(np.angle(np.exp(1j * (np.angle(ratios) - pred))))
    mag = db(np.abs(ratios))
    print(f"ends / measured channel: |ratio| {np.mean(np.abs(ratios)):.6f} "
          f"({mag.mean():+.5f} dB), spread {mag.std():.2e} dB; "
          f"latency = TX {tau_tx:.1f} + RX {tau_rx:.1f} = {tau_tx + tau_rx:.0f} samples, "
          f"worst per-tone phase residual {np.abs(phase_res).max():.2f} deg")
    dax = axs[1][1]
    dax.plot(np.arange(len(mag)), mag, "o-", ms=3, color="#1f4e79",
             label="level: |end / (channel x input)|")
    dax.plot(np.arange(len(phase_res)), phase_res, "s--", ms=3, color="#c00000",
             label="phase after removing the two latencies")
    dax.axhline(0, color="k", lw=0.6)
    dax.set_ylim(-1.2, 1.2)
    dax.set_xlabel("tone (ch0, +/- k)")
    dax.set_ylabel("dB / degrees")
    dax.set_title(f"ends vs the channel: level within {np.abs(mag).max():.4f} dB,\n"
                  f"phase within {np.abs(phase_res).max():.2f} deg "
                  f"(latency TX {tau_tx:.0f} + RX {tau_rx:.0f} clocks)", fontsize=9)
    dax.legend(fontsize=6.5)
    dax.grid(alpha=0.25, lw=0.4)
    dax.tick_params(labelsize=7)

    # ---- 5. the only coherent line: RX input truncation bias -------------
    e5 = axs[2][0]
    rows5 = []
    for tag, lab in (("fwd_x1", "digital loop"), ("conv", "12-bit converters")):
        aa = ld("cap_convbase_air.txt" if tag == "conv" else f"cap_{tag}_air.txt")
        if aa is None:
            aa = ld(f"cap_{tag}_air.txt")
        xt = np.floor(aa.real / 128.0) * 128.0 + 1j * np.floor(aa.imag / 128.0) * 128.0
        extra = np.mean(xt) - np.mean(aa)
        sig = np.sqrt(np.mean(np.abs(aa) ** 2))
        yy = ld("cap_convbase_rx_host.txt" if tag == "conv" else f"cap_{tag}_rx_host.txt")
        if yy is None:
            yy = ld(f"cap_{tag}_rx_host.txt")
        fit5, err5 = tone_fit(yy)
        E5 = np.abs(np.fft.fft(err5)) / len(err5)
        f5 = np.fft.fftfreq(len(err5), 1 / 61.44e6)
        i5 = int(np.argmin(np.abs(f5 + 61.44e6 / 8)))
        spur = db(E5[i5]) - db(np.sqrt(np.mean(np.abs(fit5) ** 2)))
        rows5.append((lab, db(extra) - db(sig), spur))
        print(f"  {lab}: extra DC from [24:7] = {abs(extra):.2f} LSB24 "
              f"({db(extra) - db(sig):.1f} dBc); measured line at the LO {spur:.1f} dBc")
    e5.barh(np.arange(len(rows5)) * 1.0 + 0.2, [r[1] for r in rows5], height=0.38,
            color="#7f7f7f", label="extra DC from the RX input truncation")
    e5.barh(np.arange(len(rows5)) * 1.0 - 0.2, [r[2] for r in rows5], height=0.38,
            color="#c00000", label="line measured at the LO")
    e5.set_yticks(np.arange(len(rows5)))
    e5.set_yticklabels([r[0] for r in rows5], fontsize=8)
    e5.set_xlim(-100, -60)
    e5.set_xlabel("dBc of the signal")
    e5.set_title("the one coherent line = the RX input's truncation bias;\n"
                 "left-justified 12-bit data has no low bits to bias", fontsize=9)
    e5.grid(alpha=0.25, lw=0.4, axis="x")
    e5.legend(fontsize=6.5, loc="lower right")

    # ---- 6. and it is absent for left-justified 12-bit data ---------------
    e6 = axs[2][1]
    for tag, lab in (("fwd_x1", "digital loop (full precision channel)"),
                     ("conv", "with 12-bit DAC and ADC")):
        yy = ld("cap_convbase_rx_host.txt" if tag == "conv" else f"cap_{tag}_rx_host.txt")
        if yy is None:
            yy = ld("cap_convbase_rx_host.txt" if tag == "conv" else f"cap_{tag}_rx_host.txt")
        if yy is None:
            yy = ld(f"cap_{tag}_rx_host.txt")
        fit6, err6 = tone_fit(yy)
        E6 = np.abs(np.fft.fft(err6)) / len(err6)
        f6 = np.fft.fftfreq(len(err6), 1 / 61.44e6)
        sig6 = db(np.sqrt(np.mean(np.abs(fit6) ** 2)))
        e6.plot(f6 / 1e6, db(E6) - sig6, lw=0.7, label=lab)
    e6.axvline(-61.44 / 8, color="k", ls=":", lw=0.8)
    e6.text(-7.55, -52, "LO", fontsize=7, rotation=90, va="top")
    e6.set_ylim(-115, -45)
    e6.set_xlabel("MHz")
    e6.set_ylabel("residual, dBc")
    e6.set_title("a real 12-bit ADC returns left-justified data (low bits zero),\n"
                 "so the bias - and this line - is structurally absent", fontsize=9)
    e6.legend(fontsize=6.5)
    e6.grid(alpha=0.25, lw=0.4)
    e6.tick_params(labelsize=7)

    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out_p = os.path.join(BASE, "loop_channel_model.png")
    fig.savefig(out_p, dpi=115)
    plt.close(fig)
    print(f"  wrote {os.path.relpath(out_p)}")


if __name__ == "__main__":
    main()
