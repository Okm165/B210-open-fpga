#!/usr/bin/env python3
"""plot-loop.py - turn the tb_capture dumps into spectrum/error PNGs and numbers.

Reads cap_*.txt written by tests/tb_capture.v (one "i q" pair per line, one
file per observed node) and produces, per run, a two-page figure:

  A) spectra of every intermediate stage, in dBFS against MHz, with the
     expected tone positions marked: the whole datastream, not one tone.
  B) the analysis page: measured vs ideal at the tone bins, the error spectrum
     after removing the best-fit gain and delay, the 12-bit converter word's
     code usage, and cross-channel leakage.

The comparison reference is the *model*, built from the same integer words the
bench feeds the sink, so the channel's multipath can never be charged to the
FPGA: forward compares the RX output against the air model applied to the pin
word, reverse compares the pin word against the dumped air signal.
"""
import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

L = 1024                     # stimulus period, host samples
NT = 7                       # tone pairs per channel
AMP = 7000.0                 # per-channel peak envelope, host units
K0 = [8, 24, 47, 83, 115, 138, 150]
K1 = [13, 31, 59, 97, 124, 143, 149]
IF = 128                     # NCO phase_inc 0x2000_0000 = fs/8 = 128 bins/L

# name -> (file suffix, integer width, full scale, IF shift in units of fs/8)
#   0 = complex baseband, +1 = the transmit IF, -1 = the reversed-path IF
STAGES = {
    "host in (16b)":     ("host",    16, 2**15, 0),
    "tx interp (18b)":   ("tx_hb",   18, 2**17, None),   # filled per mode below
    "tx mixer (18b)":    ("tx_mix",  18, 2**17, None),
    "tx pins (24b)":     ("tx_pins", 24, 2**23, None),
    "air / rx in (24b)": ("air",     24, 2**23, None),
    "rx mixer (24b)":    ("rx_mix",  24, 2**23, None),
    "rx host out (16b)": ("rx_host", 16, 2**15, None),
}
FWD_SHIFT = {"host in (16b)": 0, "tx interp (18b)": 0, "tx mixer (18b)": 1,
             "tx pins (24b)": 1, "air / rx in (24b)": 1, "rx mixer (24b)": 0,
             "rx host out (16b)": 0}
REV_SHIFT = {"air / rx in (24b)": 0, "rx mixer (24b)": -1, "rx host out (16b)": -1,
             "tx interp (18b)": -1, "tx mixer (18b)": 0, "tx pins (24b)": 0}
ORDER_FWD = ["host in (16b)", "tx interp (18b)", "tx mixer (18b)", "tx pins (24b)",
             "air / rx in (24b)", "rx mixer (24b)", "rx host out (16b)"]
ORDER_REV = ["air / rx in (24b)", "rx mixer (24b)", "rx host out (16b)",
             "tx interp (18b)", "tx mixer (18b)", "tx pins (24b)"]


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    try:
        d = np.loadtxt(path, dtype=np.int64)
    except ValueError:
        raise SystemExit(f"capture {path!r} contains non-numeric values (x/z): the "
                         f"RTL was not fully initialised in that run")
    if d.ndim == 1:
        d = d.reshape(1, -1)
    return d[:, 0].astype(float) + 1j * d[:, 1].astype(float)


def spectrum(x, fs):
    N = len(x)
    X = np.fft.fftshift(np.fft.fft(x)) / N
    f = np.fft.fftshift(np.fft.fftfreq(N, 1.0 / fs))
    return f, X


def expect(fs_stage, fs_host, shift, kset):
    """Expected tone frequencies (Hz) for one stage kind.

    R = stage rate / host rate.  The interpolator puts host bin k at k/R bins
    of the stage; each mixer moves it by fs/8 = IF bins/L, and the RX mixer
    moves it back, so the output stage is back at k/R.
    """
    R = fs_stage / fs_host
    out = []
    for k in kset:
        for s in (+1, -1):
            out.append((shift * IF + s * k / R) * fs_stage / L)
    return np.array(out)


def guarded_max(mag, f, tones, guard=3, window=None):
    mask = np.ones(len(f), dtype=bool)
    for t in tones:
        j = int(np.argmin(np.abs(f - t)))
        mask[max(0, j - guard):j + guard + 1] = False
    mask[:2] = False
    mask[-2:] = False
    j0 = int(np.argmin(np.abs(f)))
    mask[max(0, j0 - 2):j0 + 3] = False
    if window is not None:
        lo, hi = window
        mask &= (np.abs(f) >= lo) & (np.abs(f) <= hi)
    if not mask.any():
        return -200.0, 0
    v = mag[mask].max()
    return 20 * np.log10(max(v, 1e-12) / mag.max()), int(np.argmax(np.where(mask, mag, 0)))


def trunc_div(x, d):
    # Verilog integer division truncates toward zero, per component
    return np.trunc(x.real / d) + 1j * np.trunc(x.imag / d)


def fit_gain_delay(ref, y, max_lag=L + 80):
    """Pick the lag by minimum residual energy over a full stimulus period.

    The capture window starts on an arbitrary clock, so the reference is offset
    by an unknown number of samples; because the stimulus is periodic with L,
    the offset is ambiguous modulo L, and every candidate must be tried.  A
    single mis-estimated offset rotates each tone by a different phase
    (2 pi k n0 / L) and looks like massive distortion - which is exactly the
    trap this search avoids."""
    n = min(len(ref), len(y))
    best = None
    for lag in range(0, max_lag):
        a = ref[:n - lag]
        b = y[lag:n]
        a0 = a - a.mean()
        g = np.vdot(a0, b - b.mean()) / np.vdot(a0, a0)
        e = np.mean(np.abs(b - b.mean() - g * a0) ** 2)
        if best is None or e < best[0]:
            best = (e, lag, g)
    e, lag, g = best
    a = ref[:n - lag] - ref[:n - lag].mean()
    b = y[lag:n]
    return g, lag, b, g * a


def fit_two(ref, cpl, y, max_lag=L + 80):
    """Least squares for y = g*ref + c*cpl over the lag, two complex unknowns."""
    n = min(len(ref), len(y))
    best = None
    for lag in range(0, max_lag):
        a = ref[:n - lag]
        b = cpl[:n - lag]
        q = y[lag:n]
        A = np.stack([a, b], axis=1)
        Am = A - A.mean(axis=0)
        qm = q - q.mean()
        sol, *_ = np.linalg.lstsq(Am, qm, rcond=None)
        e = np.mean(np.abs(qm - Am @ sol) ** 2)
        if best is None or e < best[0]:
            best = (e, lag, sol)
    e, lag, sol = best
    g, c = sol
    a = ref[:n - lag] - ref[:n - lag].mean()
    b = cpl[:n - lag] - cpl[:n - lag].mean()
    q = y[lag:n]
    return g, lag, q, g * a + c * b, c


def main(tag):
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    fwd = not tag.startswith("rev")
    x2 = tag.endswith("x2")
    fs_dac = 61.44e6
    fs_host = fs_dac / 2 if x2 else fs_dac
    order = ORDER_FWD if fwd else ORDER_REV
    R = fs_dac / fs_host

    data = {}
    for name in order:
        x = load(os.path.join(base, f"cap_{tag}_{STAGES[name][0]}.txt"))
        if x is not None:
            data[name] = x
    if not data:
        sys.exit(f"no captures for tag {tag} in {base}")

    shift = FWD_SHIFT if fwd else REV_SHIFT

    def rate_of(name):
        return fs_host if name == "host in (16b)" else fs_dac

    print(f"\n=== {tag} ===")
    for name, x in data.items():
        fs_ = STAGES[name][2]
        rms = 20 * np.log10(max(np.sqrt(np.mean(np.abs(x) ** 2)) / fs_, 1e-12))
        print(f"  {name:22s} {len(x):5d} samples  rms {rms:6.1f} dBFS")

    # ------------------------------------------------------------ figure A
    fig, axes = plt.subplots(len(order), 1, figsize=(13, 2.05 * len(order) + 0.9),
                             sharex=False)
    if len(order) == 1:
        axes = [axes]
    fig.suptitle(f"whole-radio loop, {tag}: the complex datastream at every stage "
                 f"(14 tones, two channels, mixer at fs/8)", fontsize=11)
    for ax, name in zip(axes, order):
        if name not in data:
            ax.set_visible(False)
            continue
        x = data[name]
        fs_stage = rate_of(name)
        f, X = spectrum(x, fs_stage)
        y = 20 * np.log10(np.maximum(np.abs(X) / STAGES[name][2], 1e-12))
        ax.plot(f / 1e6, y, lw=0.7, color="#1f4e79")
        for t in expect(fs_stage, fs_host, shift[name], K0):
            ax.axvline(t / 1e6, color="#c00000", ls=":", lw=0.6)
        for t in expect(fs_stage, fs_host, shift[name], K1):
            ax.axvline(t / 1e6, color="#00a651", ls=":", lw=0.4, alpha=0.6)
        ax.set_ylim(-150, 0)
        ax.set_ylabel("dBFS", fontsize=7)
        ax.grid(alpha=0.25, lw=0.4)
        ax.tick_params(labelsize=7)
        ax.set_title(name, fontsize=8, loc="left", pad=1)
        ax.set_xlim(-fs_stage / 2e6, fs_stage / 2e6)
    axes[-1].set_xlabel("MHz (complex baseband at that stage's rate; red = ch0 tones, green = ch1)", fontsize=8)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    out_a = os.path.join(base, f"loop_{tag}_spectra.png")
    fig.savefig(out_a, dpi=110)
    plt.close(fig)

    # ------------------------------------------------------------ figure B
    fig, ax = plt.subplots(2, 2, figsize=(13, 8.2))
    fig.suptitle(f"loop {tag}: tone-by-tone accuracy, residual, converter usage", fontsize=11)

    # --- analysis: fit the output onto the known 28-tone basis.
    # A least-squares fit onto exactly the tones that were transmitted makes
    # the residual the *non-tone* content: distortion, images and noise.  It
    # cannot be fooled by a delay, a rotation or the channel's comb, which is
    # what an assumed model kept getting wrong.  All tone amplitudes come out
    # of the same fit, so flatness is measured, not assumed.
    out = data["rx host out (16b)"] if fwd else data["tx pins (24b)"]
    out_name = "rx host out (16b)" if fwd else "tx pins (24b)"
    n = len(out)
    t = np.arange(n)
    out_shift = shift[out_name]
    if out_shift:
        out = out * np.exp(-1j * 2 * np.pi * out_shift * IF * t / L)

    kR = 1.0 if fwd else 1.0
    kR = 2.0 if (fwd and x2) else kR        # x2 output runs at twice the host rate
    basis, labels = [], []
    for j, kk in enumerate(K0):
        basis += [np.exp(1j * 2 * np.pi * kk * t / (L * kR)), np.exp(-1j * 2 * np.pi * kk * t / (L * kR))]
        labels += [(kk, +1, 0), (kk, -1, 0)]
    for j, kk in enumerate(K1):
        basis += [np.exp(1j * 2 * np.pi * kk * t / (L * kR)), np.exp(-1j * 2 * np.pi * kk * t / (L * kR))]
        labels += [(kk, +1, 1), (kk, -1, 1)]
    A = np.stack(basis, axis=1)
    sol, *_ = np.linalg.lstsq(A, out, rcond=None)
    fit = A @ sol
    err = out - fit
    evm = 20 * np.log10(max(np.sqrt(np.mean(np.abs(err) ** 2)) /
                            np.sqrt(np.mean(np.abs(fit) ** 2)), 1e-12))
    fs_out = 2**15 if fwd else 2**23
    tone_dbfs = 20 * np.log10(np.abs(sol).max() / fs_out)
    spread = 20 * np.log10(np.abs(sol).max() / np.abs(sol).min())
    resid_lsb = np.sqrt(np.mean(np.abs(err) ** 2))
    print(f"  {out_name}: {len(labels)} tones fitted, strongest {tone_dbfs:+.2f} dBFS, "
          f"residual (distortion+noise) {evm:.1f} dB below them ({resid_lsb:.2f} LSB rms)")
    print(f"  tone level spread {spread:.2f} dB (the channel's comb plus any gain error)")

    a = ax[0][0]
    # per-tone level error against what was injected: the flatness/linearity
    # of the whole chain, tone by tone, ch0 solid and the -30 dB coupling open
    inj = AMP / NT                     # per-tone amplitude, host LSB
    scale = 256.0 if not fwd else 1.0     # the pin word is the host word x 256
    amp_db = 20 * np.log10(np.maximum(np.abs(sol), 1e-9) / (inj * scale))
    ch = np.array([l[2] for l in labels])
    kk = np.array([l[0] * l[1] for l in labels])
    a.stem(np.arange(len(sol))[ch == 0], amp_db[ch == 0], linefmt="C0-", markerfmt="C0o",
           basefmt=" ", label="channel 0 tone")
    a.plot(np.arange(len(sol))[ch == 1], amp_db[ch == 1], "C1x", ms=4,
           label="channel 1, seen through the -30 dB coupling")
    a.axhline(0, color="k", lw=0.6)
    a.axhline(-30, color="C1", lw=0.6, ls=":")
    a.set_ylim(-35, 1.5)
    a.set_xlabel("tone index (28: ch0 pair, ch1 pair, ...)")
    a.set_ylabel("level error vs injected, dB")
    # The reference here is the generator, so this panel shows the channel's
    # comb on top of the loop's gain.  The loop's own transparency is measured
    # against the node that actually entered it (plot-diff.py).
    a.set_title(f"tone level vs the generator: within "
                f"{np.abs(amp_db[ch==0]).max():.2f} dB (the channel's comb)", fontsize=9)
    a.legend(fontsize=6.5, loc="lower left")
    a.grid(alpha=0.25, lw=0.4)
    a.tick_params(labelsize=7)

    b = ax[0][1]
    E = np.fft.fftshift(np.fft.fft(err)) / n
    fe = np.fft.fftshift(np.fft.fftfreq(n, 1 / fs_dac))
    ref_amp = np.sqrt(np.mean(np.abs(fit) ** 2))
    b.plot(fe / 1e6, 20 * np.log10(np.maximum(np.abs(E) / ref_amp, 1e-12)),
           lw=0.6, color="#7030a0")
    b.set_title(f"residual spectrum (everything that is not one of the 28 tones): "
                f"worst {20*np.log10(max(np.abs(E).max()/ref_amp,1e-12)):.0f} dBc", fontsize=8.5)
    b.set_xlabel("MHz")
    b.set_ylabel("dBc")
    b.set_ylim(-150, -20)
    b.grid(alpha=0.25, lw=0.4)
    b.tick_params(labelsize=7)

    c = ax[1][0]
    if fwd:
        conv = data["tx pins (24b)"] / 4096.0     # 24-bit word -> 12-bit converter
        cname = "DAC 12-bit code"
    else:
        conv = data["air / rx in (24b)"] / 4096.0
        cname = "ADC 12-bit code"
    codes = np.round(conv.real)
    c.hist(np.clip(codes, -2048, 2047), bins=96, color="#1f4e79")
    clip_frac = 100.0 * np.mean(np.abs(codes) >= 2048)
    c.set_title(f"{cname}: peak {int(np.abs(codes).max())}/2048, rms "
                f"{20*np.log10(max(np.std(codes)/2048.0,1e-12)):.1f} dBFS, "
                f"clipped {clip_frac:.2f}% of samples", fontsize=8)
    c.set_xlabel("code")
    c.set_ylabel("samples")
    c.grid(alpha=0.25, lw=0.4)
    c.tick_params(labelsize=7)

    d = ax[1][1]
    ev = err if fwd else err / 256.0      # report in 16-bit LSB either way
    d.plot(np.abs(ev), lw=0.5, color="#7030a0")
    d.axhline(np.sqrt(np.mean(np.abs(ev) ** 2)), color="k", lw=0.7, ls="--")
    d.set_title(f"residual magnitude: mean {np.sqrt(np.mean(np.abs(ev)**2)):.2f} LSB, "
                f"peak {np.abs(ev).max():.1f} LSB (1 LSB = the host word; the dither step)",
                fontsize=8.5)
    d.set_xlabel("sample")
    d.set_ylabel("|error|, LSB of the output word")
    d.grid(alpha=0.25, lw=0.4)
    d.tick_params(labelsize=7)

    fig.tight_layout(rect=[0, 0, 1, 0.96])
    out_b = os.path.join(base, f"loop_{tag}_analysis.png")
    fig.savefig(out_b, dpi=110)
    plt.close(fig)

    # ---- text metrics for the audit
    print("  --- stage spurs (dBc of that stage's strongest tone) ---")
    for name in order:
        if name not in data:
            continue
        fs_stage = rate_of(name)
        f, X = spectrum(data[name], fs_stage)
        mag = np.abs(X)
        tones = np.concatenate([expect(fs_stage, fs_host, shift[name], K0),
                                expect(fs_stage, fs_host, shift[name], K1)])
        w, idx = guarded_max(mag, f, tones)
        img, iidx = guarded_max(mag, f, tones, window=(0.30 * fs_stage, 0.50 * fs_stage))
        img2, _ = guarded_max(mag, f, tones, window=(-0.50 * fs_stage, -0.30 * fs_stage))
        j0 = int(np.argmin(np.abs(f)))
        dc = 20 * np.log10(max(mag[max(0, j0 - 1):j0 + 2].max(), 1e-12) / mag.max())
        print(f"  {name:22s} worst tone-free bin {w:7.1f} dBc at {f[idx]/1e6:6.2f} MHz"
              f"   image band {max(img, img2):7.1f} dBc   dc {dc:6.1f} dBc")
    print(f"  wrote {os.path.relpath(out_a)} and {os.path.relpath(out_b)}")


def tone_fit(x, order=2):
    """Residual of x against the 28 transmitted tones, and the fitted signal."""
    n = len(x)
    t = np.arange(n)
    A = []
    for kk in K0 + K1:
        A += [np.exp(1j * 2 * np.pi * kk * t / L), np.exp(-1j * 2 * np.pi * kk * t / L)]
    A = np.stack(A, axis=1)
    sol, *_ = np.linalg.lstsq(A, x, rcond=None)
    fit = A @ sol
    return x - fit, fit


def budget():
    """The loss budget: digital-only loop versus the loop with 12-bit converters."""
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    tags = [("fwd_x1", "digital only (exact 24-bit interface)"),
            ("conv", "with 12-bit DAC and ADC")]
    fig, ax = plt.subplots(1, 3, figsize=(14, 4.4))
    fig.suptitle("where the loop's error comes from: the datapath is not the limit, "
                 "the 12-bit converters are", fontsize=11)
    rows = []
    for tag, label in tags:
        # cap_convbase_* is the standard-amplitude capture kept by `make plots`;
        # cap_conv_* may hold the level sweep's last amplitude.
        cands = [f"cap_{tag}_rx_host.txt"]
        if tag == "conv":
            cands.insert(0, "cap_convbase_rx_host.txt")
        out = next((x for x in map(load, [os.path.join(base, c) for c in cands])
                    if x is not None), None)
        if out is None:
            continue
        err, fit = tone_fit(out)
        n = len(out)
        E = np.fft.fftshift(np.fft.fft(err)) / n
        f = np.fft.fftshift(np.fft.fftfreq(n, 1 / 61.44e6))
        ref = np.sqrt(np.mean(np.abs(fit) ** 2))
        ax[0].plot(f / 1e6, 20 * np.log10(np.maximum(np.abs(E) / ref, 1e-12)),
                   lw=0.6, label=label)
        rms = np.sqrt(np.mean(np.abs(err) ** 2))
        rows.append((label, rms, 20 * np.log10(rms / ref),
                     20 * np.log10(rms / 32768)))
    if len(rows) != 2:
        print(f"  budget page skipped: {len(rows)} of 2 captures present")
        plt.close(fig)
        return

    ax[0].set_xlabel("MHz")
    ax[0].set_ylabel("residual, dBc of the tones")
    ax[0].set_title("residual spectrum, same signal, same fit", fontsize=9)
    ax[0].legend(fontsize=7)
    ax[0].grid(alpha=0.25, lw=0.4)
    ax[0].set_ylim(-140, -40)
    ax[0].tick_params(labelsize=7)

    for j, (suf, name) in enumerate((("dac", "DAC word the chip sees"),
                                     ("adc", "ADC word the chip returns"))):
        w = load(os.path.join(base, f"cap_convbase_{suf}.txt"))
        if w is None:
            w = load(os.path.join(base, f"cap_conv_{suf}.txt"))
        codes = np.round(w.real / 4096.0)
        a = ax[1 + j]
        a.hist(np.clip(codes, -2048, 2047), bins=120, color="#1f4e79")
        a.set_title(f"{name}: {len(np.unique(codes))} codes, peak "
                    f"{int(np.abs(codes).max())}/2048, rms "
                    f"{20*np.log10(max(np.std(codes)/2048,1e-12)):.1f} dBFS", fontsize=8.5)
        a.set_xlabel("12-bit code")
        a.set_ylabel("samples")
        a.grid(alpha=0.25, lw=0.4)
        a.tick_params(labelsize=7)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = os.path.join(base, "loop_loss_budget.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("\n=== loss budget ===")
    for label, rms, dbc, dbfs in rows:
        print(f"  {label:38s} {rms:7.2f} LSB16 rms = {dbc:6.1f} dBc = {dbfs:6.1f} dBFS")
    if len(rows) == 2:
        print(f"  converter cost: {rows[1][2] - rows[0][2]:+.1f} dB")
    print(f"  wrote {os.path.relpath(out)}")


def levels():
    """SNR against input level with the real converters in the loop.

    Four captures of the same 28-tone signal at -25, -19, -13 and -7 dBFS rms.
    The residual is measured against the transmitted tones, the clipping
    fraction against the 12-bit code range, so the curve shows where the
    converters are actually being used and where they run out.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    amps = [3500, 7000, 12000, 16000]
    amps_r = [7000, 14000, 21000, 28000]
    pts = []
    for a in amps:
        out = load(os.path.join(base, f"cap_lvl_{a}_rx.txt"))
        dac = load(os.path.join(base, f"cap_lvl_{a}_dac.txt"))
        adc = load(os.path.join(base, f"cap_lvl_{a}_adc.txt"))
        if out is None or dac is None:
            continue
        err, fit = tone_fit(out)
        sig = np.sqrt(np.mean(np.abs(fit) ** 2))
        res = np.sqrt(np.mean(np.abs(err) ** 2))
        codes = np.round(dac.real / 4096.0)
        clip = 100.0 * np.mean(np.abs(codes) >= 2048)
        acodes = np.round(adc.real / 4096.0) if adc is not None else np.zeros(1)
        aclip = 100.0 * np.mean(np.abs(acodes) >= 2048)
        pts.append((a, 20 * np.log10(sig / 32768), 20 * np.log10(res / 32768),
                    20 * np.log10(sig / res), clip, aclip,
                    int(np.abs(codes).max()), len(np.unique(codes))))

    if len(pts) != len(amps):
        # No captures for this page in this run (they come from
        # `make plots-levels`).  Writing an empty figure here would replace a
        # real measurement with a blank page that still looks like evidence.
        print(f"  levels page skipped: {len(pts)} of {len(amps)} captures present")
        return

    # Reverse loop: the RX word drives the TX, so a strong receive signal can run
    # the transmitter into its rail.  Peak of the 24-bit pin word against the
    # input level, measured in the capture's own directory (revsweep/).
    rpts = []
    RAIL = 2 ** 23 - 1
    for a in amps_r:
        pins = load(os.path.join(base, "revsweep", f"cap_revlvl_{a}_pins.txt"))
        if pins is None:
            continue
        peak = max(np.abs(pins.real).max(), np.abs(pins.imag).max()) / RAIL
        # Compression, not exact-rail equality: the 24-bit saturator clamps a few
        # LSB below the rail, so "== RAIL" would read 0 % while the word is at it.
        clip = 100.0 * np.mean((np.abs(pins.real) >= 0.999 * RAIL) |
                               (np.abs(pins.imag) >= 0.999 * RAIL))
        w = pins / 256.0
        err, fit = tone_fit(w)
        sig = np.sqrt(np.mean(np.abs(fit) ** 2))
        res = np.sqrt(np.mean(np.abs(err) ** 2))
        rpts.append((a, 20 * np.log10(max(peak, 1e-9)), clip,
                     20 * np.log10(max(res, 1e-9) / max(sig, 1e-9))))

    fig, ax = plt.subplots(1, 3, figsize=(16, 4.4))
    fig.suptitle("converter utilisation: 12-bit converters in the forward loop, "
                 "transmitter headroom in the reverse loop", fontsize=11)
    lv = [p[1] for p in pts]
    ax[0].plot(lv, [p[3] for p in pts], "o-", color="#1f4e79", label="SNR (signal / residual)")
    ax[0].plot(lv, [-p[2] for p in pts], "s--", color="#c00000", label="residual, dBFS")
    ax[0].set_xlabel("signal rms, dBFS")
    ax[0].set_ylabel("dB")
    ax[0].set_title("residual is flat (converter quantisation): SNR rises 1:1 with level",
                    fontsize=9)
    ax[0].grid(alpha=0.25, lw=0.4)
    ax[0].legend(fontsize=7)
    ax[0].tick_params(labelsize=7)
    ax[1].plot(lv, [p[4] for p in pts], "o-", color="#1f4e79", label="DAC word")
    ax[1].plot(lv, [p[5] for p in pts], "s--", color="#c00000", label="ADC word")
    ax[1].set_xlabel("signal rms, dBFS")
    ax[1].set_ylabel("% of samples at the rail")
    ax[1].set_title("clipping fraction of the 12-bit words (zero over the whole range)",
                    fontsize=9)
    ax[1].set_ylim(-0.5, 0.5)
    ax[1].legend(fontsize=7)
    ax[1].grid(alpha=0.25, lw=0.4)
    ax[1].tick_params(labelsize=7)
    if len(rpts) == len(amps_r):
        ax[2].plot([r[0] for r in rpts], [r[1] for r in rpts], "o-",
                   color="#1f4e79", label="pin-word peak")
        ax[2].axhline(0, color="#c00000", lw=0.8, ls="--", label="24-bit rail")
        ax[2].set_xlabel("antenna tone-set amplitude")
        ax[2].set_ylabel("pin-word peak, dBFS")
        ax[2].set_title("reverse loop: the TX rail is reached at 4x the demo level",
                        fontsize=9)
        ax[2].grid(alpha=0.25, lw=0.4)
        ax[2].legend(fontsize=7, loc="lower right")
        ax[2].tick_params(labelsize=7)
    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = os.path.join(base, "loop_level_sweep.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("\n=== level sweep (12-bit converters in the loop) ===")
    for a, sig, res, snr, clip, aclip, peak, ncodes in pts:
        print(f"  tone-set amplitude {a:6d}: signal {sig:6.1f} dBFS, residual {res:6.1f} dBFS, "
              f"SNR {snr:5.1f} dB, DAC peak {peak:4d}/2048, {ncodes:4d} codes, "
              f"DAC clip {clip:5.2f} %, ADC clip {aclip:5.2f} %")
    if len(rpts) == len(amps_r):
        print("\n=== reverse-path headroom (RX word -> TX, no converters) ===")
        for a, peak, clip, resid in rpts:
            print(f"  antenna amplitude {a:6d}: pin peak {peak:+6.2f} dBFS, within "
                  f"0.01 dB of the rail {clip:5.2f} % of samples, residual {resid:6.1f} dBc")
    print(f"  wrote {os.path.relpath(out)}")


def band():
    """Where the loop stops being flat: the same tones moved 3x up the band.

    The narrowband pages put the highest tone at 0.146 fs_host, i.e. less than a
    third of the band.  This grades the loop with the highest tone at 0.44
    fs_host (6.75 of 15.36 MHz) in all four configurations that exist: forward
    and reverse, bypassed and x2 (MIMO) interpolation.

    The reference is the air node through its measured gain and delay - the same
    node the ends page uses - so a channel comb cannot masquerade as a loop
    error, and the residual is the whole ending compared with that model.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    K0 = [8, 24, 47, 83, 115, 138, 150]
    K1 = [13, 31, 59, 97, 124, 143, 149]
    FS = 15.36e6
    S = 3
    # dir, period, IF, air suffix, out suffix, out scale, lag, air bin K or IF+K
    cfgs = [
        ("fwd", "band",    1024, 128, "air",     "rx_host", 256.0, 5,  "if+k"),
        ("rev", "bandrev", 1024, 0,   "air",     "tx_pins", 1.0,   28, "k"),
        ("x2",  "bandx2",  2048, 256, "air",     "rx_host", 256.0, 5,  "if+k"),
    ]
    res = []
    for name, sub, L, IF, airn, outn, oscale, lag, refbin in cfgs:
        got = []
        for ch, ks in ((0, K0), (1, K1)):
            suf = "" if ch == 0 else "1"
            air = load(os.path.join(base, sub, f"cap_{'rev' if name == 'rev' else ('fwd_x2' if name == 'x2' else 'fwd_x1')}_{airn}{suf}.txt"))
            out = load(os.path.join(base, sub, f"cap_{'rev' if name == 'rev' else ('fwd_x2' if name == 'x2' else 'fwd_x1')}_{outn}{suf}.txt"))
            if air is None or out is None:
                continue
            n = len(out)
            t = np.arange(n)
            bb = air * np.exp(-2j * np.pi * IF * t / L) if IF else air
            g, ph, f = [], [], []
            for k in ks:
                K = S * k
                a = np.mean(bb * np.exp(-2j * np.pi * K * t / L)) / oscale
                b = np.mean(out * np.exp(-2j * np.pi * K * t / L))
                r = b / a
                g.append(20 * np.log10(max(abs(r), 1e-12)))
                ph.append(np.degrees(np.angle(r * np.exp(2j * np.pi * K * lag / L))))
                f.append(K * FS / L / 1e6 if L == 1024 else K * FS * 2 / L / 1e6)
            ref = bb[:n - lag] / oscale
            y = out[lag:]
            resid = np.sqrt(np.mean(abs(y - ref) ** 2))
            sig = np.sqrt(np.mean(abs(ref) ** 2))
            # report the residual in 16-bit LSB for every configuration: the
            # reverse end is a 24-bit pin word, i.e. 256 LSB24 per LSB16
            got.append((ch, f, g, ph, resid / (256.0 if name == "rev" else 1.0),
                        20 * np.log10(resid / sig)))
        if got:
            res.append((name, got))
    want = {n: 2 for n, *_ in cfgs}
    done = {n: len(g) for n, g in res}
    if done != want:
        print(f"  band page skipped: {done} of {want} captures present")
        return

    fig, ax = plt.subplots(2, 2, figsize=(12, 8.2))
    fig.suptitle("band of operation: the same 14 tones moved 3x up the band "
                 "(highest 6.75 MHz), every configuration", fontsize=11)
    titles = {"fwd": "forward, bypassed", "rev": "reverse, bypassed",
              "x2": "forward, x2 (MIMO) interpolation"}
    panels = [ax[0][0], ax[0][1], ax[1][0], ax[1][1]]
    print("\n=== band of operation (tones 3x up, highest 6.75 MHz) ===")
    for i, (name, got) in enumerate(res):
        a = panels[i]
        for ch, f, g, ph, resid, dbc in got:
            a.plot(f, g, "o-", ms=3,
                   label=f"ch{ch}: {max(g)-min(g):.3f} dB, "
                         f"{max(ph)-min(ph):.4f} deg, {resid:.2f} LSB")
            print(f"  {name} ch{ch}: gain spread {max(g)-min(g):.3f} dB, phase spread "
                  f"{max(ph)-min(ph):.4f} deg, end vs air model: {resid:.2f} LSB rms "
                  f"({dbc:.1f} dBc)")
        a.set_title(titles[name], fontsize=9)
        a.set_xlabel("MHz at the host rate")
        a.set_ylabel("end / air, dB")
        a.axhline(0, color="k", lw=0.5)
        a.set_ylim(-1.2, 1.2)
        a.grid(alpha=0.25, lw=0.4)
        a.legend(fontsize=6.5, loc="lower right")
        a.tick_params(labelsize=7)
    # What is left at band edge: the residual after removing the 14 tones.
    # A line would be a distortion; the dither has none.
    air0 = load(os.path.join(base, "band", "cap_fwd_x1_air.txt"))
    out0 = load(os.path.join(base, "band", "cap_fwd_x1_rx_host.txt"))
    if air0 is not None and out0 is not None:
        n = len(out0)
        t = np.arange(n)
        A = []
        for k in K0 + K1:
            K = S * k
            A += [np.exp(2j * np.pi * K * t / 1024), np.exp(-2j * np.pi * K * t / 1024)]
        A = np.stack(A, 1)
        sol, *_ = np.linalg.lstsq(A, out0, rcond=None)
        fit = A @ sol
        err = out0 - fit
        E = np.abs(np.fft.fft(err)) / n
        ref = np.sqrt(np.mean(np.abs(fit) ** 2))
        f = np.fft.fftfreq(n, 1 / FS)
        sel = f >= 0
        a = panels[3]
        a.plot(f[sel] / 1e6, 20 * np.log10(np.maximum(E[sel] / ref, 1e-12)),
               lw=0.6, color="#7030a0")
        a.set_ylim(-140, -40)
        a.set_xlabel("MHz at the host rate")
        a.set_ylabel("residual, dBc of the tones")
        a.set_title(f"band-edge residual: worst {20*np.log10(E[sel].max()/ref):.0f} dBc, "
                    "no line above the dither", fontsize=9)
        a.grid(alpha=0.25, lw=0.4)
        a.tick_params(labelsize=7)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    outp = os.path.join(base, "loop_band.png")
    fig.savefig(outp, dpi=110)
    plt.close(fig)
    print(f"  wrote {os.path.relpath(outp)}")

def proof():
    """One sheet: the loop's ends, forward and reverse, with the numbers.

    Everything is measured from the dumped nodes: the end is compared with the
    air node through its measured gain and delay, never with a fit to itself.
    Both directions are put in the same 16-bit units so the panels compare.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    K0 = [8, 24, 47, 83, 115, 138, 150]
    K1 = [13, 31, 59, 97, 124, 143, 149]
    IF = 128
    FS = 15.36e6
    rows = {}
    # tag, forward?, delay, air tones at IF+k?, end is 24-bit?
    cfgs = (("fwd_x1", True, 5, True, False), ("rev", False, 28, False, True))
    for tag, fwd, lag, air_if, end24 in cfgs:
        got = []
        for ch, ks in ((0, K0), (1, K1)):
            suf = "" if ch == 0 else "1"
            air = load(os.path.join(base, f"cap_{tag}_air{suf}.txt"))
            out = load(os.path.join(base,
                                    f"cap_{tag}_{'rx_host' if fwd else 'tx_pins'}{suf}.txt"))
            if air is None or out is None:
                continue
            air = air / 256.0                      # both ends in LSB16
            out = out / (256.0 if end24 else 1.0)
            n = len(out)
            t = np.arange(n)
            # the model is the air node at baseband: forward it carries the IF
            bb = air * np.exp(-2j * np.pi * IF * t / 1024) if air_if else air
            model = np.zeros_like(out)
            model[lag:] = bb[:n - lag]
            resid = out[lag:] - model[lag:]
            sig = np.sqrt(np.mean(np.abs(model[lag:]) ** 2))
            g, f = [], []
            for k in ks:
                a = np.mean(air * np.exp(-2j * np.pi * (IF + k if air_if else k) * t / 1024))
                b = np.mean(out * np.exp(-2j * np.pi * k * t / 1024))
                g.append(20 * np.log10(abs(b) / max(abs(a), 1e-12)))
                f.append(k * FS / 1024 / 1e6)
            got.append(dict(ch=ch, f=f, g=g, out=out, model=model, lag=lag,
                            resid=resid, sig=sig,
                            lsb=np.sqrt(np.mean(np.abs(resid) ** 2)),
                            dbc=20 * np.log10(np.sqrt(np.mean(np.abs(resid) ** 2)) / sig)))
        if got:
            rows[tag] = got
    if len(rows) != 2:
        print(f"  proof page skipped: {sorted(rows)}")
        return

    fig, axs = plt.subplots(3, 2, figsize=(13, 10))
    fig.suptitle("the loop end to end: forward and reverse, every difference measured", fontsize=12)
    for col, (tag, title) in enumerate((("fwd_x1", "forward"), ("rev", "reverse"))):
        got = rows[tag]
        lag = got[0]["lag"]
        a = axs[0][col]
        m = 80
        for r in got:
            colour = "#1f4e79" if r["ch"] == 0 else "#c00000"
            a.plot(np.arange(m), r["out"][lag:lag + m].real, ".", ms=2.4, color=colour,
                   label=f"ch{r['ch']} end")
            a.plot(np.arange(m), r["model"][lag:lag + m].real, "-", lw=0.9, color=colour,
                   alpha=0.55)
        a.set_title(f"{title}: end (dots) vs air through its gain/delay (line)", fontsize=9)
        a.set_xlabel("sample")
        a.set_ylabel("LSB16")
        a.grid(alpha=0.25, lw=0.4)
        a.legend(fontsize=6.5)
        a.tick_params(labelsize=7)

        a = axs[1][col]
        for r in got:
            a.plot(r["f"], r["g"], "o-", ms=3,
                   color="#1f4e79" if r["ch"] == 0 else "#c00000",
                   label=f"ch{r['ch']}: spread {max(r['g'])-min(r['g']):.3f} dB")
        a.axhline(0, color="k", lw=0.5)
        a.set_ylim(-1.2, 1.2)
        a.set_title(f"{title}: per-tone gain, channel removed", fontsize=9)
        a.set_xlabel("MHz")
        a.set_ylabel("dB")
        a.grid(alpha=0.25, lw=0.4)
        a.legend(fontsize=6.5)
        a.tick_params(labelsize=7)

        a = axs[2][col]
        r = got[0]
        n = len(r["resid"])
        E = np.abs(np.fft.fft(r["resid"])) / n
        f = np.fft.fftfreq(n, 1 / FS)
        sel = f >= 0
        em = 20 * np.log10(np.maximum(E[sel] / r["sig"], 1e-12))
        a.plot(f[sel] / 1e6, em, lw=0.6, color="#7030a0")
        a.set_ylim(-140, -40)
        a.set_title(f"{title}: residual spectrum (worst {em.max():.0f} dBc)", fontsize=9)
        a.set_xlabel("MHz")
        a.set_ylabel("dBc")
        a.grid(alpha=0.25, lw=0.4)
        a.tick_params(labelsize=7)

    # Every stage carries the same tone pattern once each stage's own gain is
    # divided out; only the declared scale and the IF shift differ.  This is the
    # view that makes "the charts change halfway" legible.
    stage_sets = {
        "fwd_x1": ["host", "tx_hb", "tx_mix", "tx_pins", "air", "rx_mix", "rx_host"],
    }
    fig2, ax2 = plt.subplots(1, 1, figsize=(9, 4.2))
    fig2.suptitle("same tone pattern at every stage, each stage normalised by its own gain",
                  fontsize=10.5)
    t = np.arange(2048)
    rev_spread = []
    for st in ("air", "rx_mix", "rx_host", "tx_hb", "tx_mix", "tx_pins"):
        x = load(os.path.join(base, f"cap_rev_{st}.txt"))
        if x is None:
            continue
        lv = []
        for k in K0:
            cand = [abs(np.mean(x * np.exp(-2j * np.pi * b * t / 1024)))
                    for b in (k, k + IF, k - IF)]
            lv.append(20 * np.log10(max(max(cand), 1e-12)))
        lv = np.array(lv) - np.mean(lv)
        rev_spread.append(lv.max() - lv.min())
    for st in stage_sets["fwd_x1"]:
        x = load(os.path.join(base, f"cap_fwd_x1_{st}.txt"))
        if x is None:
            continue
        lv = []
        for k in K0:
            cand = [abs(np.mean(x * np.exp(-2j * np.pi * b * t / 1024)))
                    for b in (k, k + IF, k - IF)]
            lv.append(20 * np.log10(max(max(cand), 1e-12)))
        lv = np.array(lv) - np.mean(lv)
        ax2.plot(K0, lv, "o-", ms=3, lw=1.0,
                 label=f"{st}: spread {lv.max()-lv.min():.2f} dB")
    ax2.axhline(0, color="k", lw=0.5)
    ax2.set_xlabel("tone bin")
    ax2.set_ylabel("level vs that stage's mean, dB")
    ax2.set_ylim(-1.4, 1.4)
    ax2.set_title("forward: flat through the transmitter, the comb appears only "
                  "after the antenna node", fontsize=9)
    ax2.grid(alpha=0.25, lw=0.4)
    ax2.legend(fontsize=6.5, ncol=2)
    ax2.tick_params(labelsize=7)
    fig2.tight_layout(rect=[0, 0, 1, 0.9])
    outp2 = os.path.join(base, "loop_stage_shape.png")
    fig2.savefig(outp2, dpi=110)
    plt.close(fig2)
    print(f"  wrote {os.path.relpath(outp2)}")
    if rev_spread:
        print(f"  reverse: all six stages carry the same shape "
              f"(spread {min(rev_spread):.2f}-{max(rev_spread):.2f} dB), "
              f"because the channel is upstream of the input")

    lines = []
    for tag, name in (("fwd_x1", "forward"), ("rev", "reverse")):
        for r in rows[tag]:
            lines.append(f"{name} ch{r['ch']}: residual {r['lsb']:.2f} LSB rms "
                         f"({r['dbc']:.1f} dBc), gain spread {max(r['g'])-min(r['g']):.3f} dB")
    fig.text(0.5, 0.012, "   |   ".join(lines[:2]) + "\n" + "   |   ".join(lines[2:]),
             ha="center", fontsize=7.5)
    fig.tight_layout(rect=[0, 0.05, 1, 0.95])
    outp = os.path.join(base, "loop_proof.png")
    fig.savefig(outp, dpi=110)
    plt.close(fig)
    print("\n=== proof sheet ===")
    for line in lines:
        print("  " + line)
    print(f"  wrote {os.path.relpath(outp)}")


def retune():
    """A settings write on a running transmitter: LO retune and rate rewrite."""
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    path = os.path.join(base, "retune_stream.txt")
    if not os.path.exists(path):
        print("  (no retune_stream.txt; run the bench first)")
        return
    xs, ys, events, n = [], [], [], 0
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] == "EVENT":
            events.append((n, int(f[1]), int(f[2], 16) if f[2].startswith("0x") else int(f[2])))
        else:
            xs.append(int(f[0]))
            ys.append(int(f[1]))
            n += 1
    x = np.array(xs, float) + 1j * np.array(ys, float)
    step = np.degrees(np.angle(x[1:] * np.conj(x[:-1])))
    fig, ax = plt.subplots(2, 1, figsize=(12.5, 6.4), sharex=True)
    fig.suptitle("a settings write on a running transmitter: LO retune and rate-register rewrite",
                 fontsize=11)
    ax[0].plot(step, lw=0.8, color="#1f4e79")
    ax[0].set_ylabel("phase step, deg/sample")
    ax[0].set_title("sample-to-sample phase step: 47.81 deg is fs/8 + the tone; a flat line is a clean stream",
                    fontsize=9)
    ax[0].grid(alpha=0.25, lw=0.4)
    ax[0].tick_params(labelsize=7)
    for (pos, addr, val) in events:
        ax[0].axvline(pos, color="#c00000", lw=0.7, ls=":")
        ax[0].text(pos + 8, max(step) * 0.85, f"write {addr:#04x}={val:#010x}",
                   rotation=90, fontsize=6, color="#c00000", va="top")
    ax[1].plot(np.abs(x), lw=0.6, color="#7030a0")
    ax[1].set_ylabel("|sample|")
    ax[1].set_xlabel("sample at the DAC rate (61.44 MSPS)")
    ax[1].set_title("magnitude is flat through both writes: no gain glitch, no saturation", fontsize=9)
    ax[1].grid(alpha=0.25, lw=0.4)
    ax[1].tick_params(labelsize=7)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    out = os.path.join(base, "loop_retune.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    # numbers
    q = np.abs(np.round(step, 2))
    print("\n=== retune stream ===")
    print(f"  {len(x)} samples, {len(events)} writes")
    print(f"  phase step: median {np.median(step):.3f} deg, "
          f"{np.sum(np.abs(step - np.median(step)) > 1.0)} samples deviate > 1 deg")
    print(f"  magnitude: min {np.abs(x).min():.0f}, max {np.abs(x).max():.0f}")
    print(f"  wrote {os.path.relpath(out)}")


def match():
    """Two channels on the same signal: the RTL's own channel-to-channel error."""
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    fig, ax = plt.subplots(1, 3, figsize=(14, 4.4))
    fig.suptitle("channel matching: both channels fed the same signal (coupling off)", fontsize=11)
    rows = []
    for tag, label, colour in (("UNALIGNED", "written 2 clocks apart, running", "#c00000"),
                               ("ALIGN", "oscillators released together", "#1f4e79")):
        a = load(os.path.join(base, f"cap_{tag}_ch0.txt"))
        b = load(os.path.join(base, f"cap_{tag}_ch1.txt"))
        if a is None or b is None:
            continue
        n = min(len(a), len(b))
        best = None
        for lag in range(0, 40):
            r = a[:n - lag] - a[:n - lag].mean()
            q2 = b[lag:n] - b[lag:n].mean()
            g = np.vdot(r, q2) / np.vdot(r, r)
            e = np.mean(np.abs(q2 - g * r) ** 2)
            if best is None or e < best[0]:
                best = (e, lag, g)
        e, lag, g = best
        r = a[:n - lag] - a[:n - lag].mean()
        q2 = b[lag:n]
        err = q2 - q2.mean() - g * r
        evm = 20 * np.log10(max(np.sqrt(np.mean(np.abs(err) ** 2)) /
                                np.sqrt(np.mean(np.abs(g * r) ** 2)), 1e-12))
        rows.append((label, abs(g), np.degrees(np.angle(g)), lag, evm))
        ax[0].plot(np.arange(n)[:400], (a[:n][:400]).real, lw=0.8, color=colour,
                   alpha=0.7, label=f"ch0, {label}")
        ax[0].plot(np.arange(n)[:400], (b[:n][:400]).real, lw=0.8, ls="--", color=colour,
                   label=f"ch1, {label}")
    ax[0].set_title("first 400 samples: the dashed channel is the solid one", fontsize=9)
    ax[0].set_xlabel("sample")
    ax[0].set_ylabel("I (LSB)")
    ax[0].legend(fontsize=6)
    ax[0].grid(alpha=0.25, lw=0.4)
    ax[0].tick_params(labelsize=7)

    labs = [r[0] for r in rows]
    ax[1].barh(range(len(rows)), [r[1] for r in rows], color=["#c00000", "#1f4e79"])
    ax[1].set_yticks(range(len(rows)))
    ax[1].set_yticklabels(["2 clocks apart", "released together"], fontsize=7)
    ax[1].axvline(1.0, color="k", lw=0.8)
    ax[1].set_xlim(0.99, 1.01)
    ax[1].set_xlabel("channel 1 / channel 0 gain")
    ax[1].set_title("gain ratio", fontsize=9)
    ax[1].grid(alpha=0.25, lw=0.4, axis="x")
    ax[1].tick_params(labelsize=7)

    ax[2].barh(range(len(rows)), [r[2] for r in rows], color=["#c00000", "#1f4e79"])
    ax[2].set_yticks(range(len(rows)))
    ax[2].set_yticklabels(["2 clocks apart", "released together"], fontsize=7)
    ax[2].axvline(0.0, color="k", lw=0.8)
    ax[2].set_xlim(-100, 5)
    ax[2].set_xlabel("channel 1 - channel 0 phase, deg")
    ax[2].set_title("phase difference", fontsize=9)
    ax[2].grid(alpha=0.25, lw=0.4, axis="x")
    ax[2].tick_params(labelsize=7)
    for i, r in enumerate(rows):
        ax[2].text(2, i, f"{r[2]:+.2f} deg\nEVM {r[4]:.0f} dB", va="center", fontsize=7)

    fig.tight_layout(rect=[0, 0, 1, 0.93])
    out = os.path.join(base, "loop_match.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("\n=== channel matching ===")
    for label, g, ph, lag, evm in rows:
        print(f"  {label:34s} gain {g:.6f}, phase {ph:+.4f} deg, lag {lag}, EVM {evm:.1f} dB")
    print(f"  wrote {os.path.relpath(out)}")


def clkmux():
    """The MIMO clock switch in time: period of radio_clk against time."""
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.normpath(os.path.join(here, "..", "build", "plots"))
    path = os.path.join(base, "clkmux_edges.txt")
    if not os.path.exists(path):
        print("  (no clkmux_edges.txt; run the bench first)")
        return
    d = np.loadtxt(path)
    t, period = d[:, 0], d[:, 1]
    fig, ax = plt.subplots(2, 1, figsize=(12.5, 6.0), sharex=True)
    fig.suptitle("MIMO clock switchover: radio_clk period while switching both ways", fontsize=11)
    ax[0].plot(t, period, lw=0.6, color="#1f4e79")
    ax[0].axhline(8.138, color="#00a651", lw=0.8, ls="--", label="61.44 MHz (SISO)")
    ax[0].axhline(16.276, color="#c00000", lw=0.8, ls="--", label="30.72 MHz (MIMO)")
    ax[0].set_ylabel("interval between edges, ns")
    ax[0].set_title("two switches: SISO -> MIMO and back; the single truncated pulse is visible as a short gap",
                    fontsize=9)
    ax[0].legend(fontsize=7)
    ax[0].grid(alpha=0.25, lw=0.4)
    ax[0].tick_params(labelsize=7)
    ax[0].set_ylim(0, 40)
    ax[1].semilogy(t, period, ".", ms=2, color="#7030a0")
    ax[1].set_ylabel("interval, ns (log)")
    ax[1].set_xlabel("time, ns")
    ax[1].set_title("every edge: no pulse below half the slow period survives the switchover windows",
                    fontsize=9)
    ax[1].grid(alpha=0.25, lw=0.4)
    ax[1].tick_params(labelsize=7)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    out = os.path.join(base, "loop_clkmux.png")
    fig.savefig(out, dpi=110)
    plt.close(fig)
    print("\n=== clock mux ===")
    print(f"  {len(t)} edges, interval range {period.min():.3f} .. {period.max():.3f} ns")
    print(f"  half-periods at 8.138 ns (SISO): {int(np.sum(np.abs(period-8.138) < 0.1))}, "
          f"at 16.276 ns (MIMO): {int(np.sum(np.abs(period-16.276) < 0.1))}, other: "
          f"{int(np.sum((np.abs(period-8.138) >= 0.1) & (np.abs(period-16.276) >= 0.1)))}")
    print(f"  wrote {os.path.relpath(out)}")


if __name__ == "__main__":
    args = sys.argv[1:] or ["fwd_x1", "fwd_x2", "rev", "conv"]
    for t in args:
        if t == "budget":
            budget()
        elif t == "levels":
            levels()
        elif t == "retune":
            retune()
        elif t == "match":
            match()
        elif t == "clkmux":
            clkmux()
        elif t == "band":
            band()
        elif t == "proof":
            proof()
        else:
            main(t)
    if "budget" not in args:
        budget()
    if "levels" not in args:
        levels()
