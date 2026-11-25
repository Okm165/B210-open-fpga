#!/usr/bin/env python3
"""sdr.py - receive, transmit, record and look at spectra with the B210.

  sdr.py config                      print the complete configuration (TOML)
  sdr.py rx   [--n N] [--tone F]     record build/captures/<time>.npy + .toml, plot, peaks
  sdr.py tx   --tone F [--secs S]    transmit F on the first transmit channel, 2F on the second
  sdr.py live [--zoom LO:HI]         spectrum, capture after capture
  sdr.py fft  CAPTURE.npy            spectrum of a recording

Every command takes the configuration as --config FILE.toml and/or
--set NAME=VALUE (repeatable; lists comma-separated), e.g.
  --set rate=7.68e6 --set rx.freq=433.92e6 --set rx.gain=40,40 --set test=loopback
The settings, their ranges and defaults: host/schema.py (`sdr.py config`).

Spectrum: Welch average over the whole capture (Blackman-Harris, 50 %
overlap, --nfft bins); --zoom LO:HI (baseband Hz): scipy's zoom FFT of the
whole windowed capture, resolution rate / N.  Levels in dBFS, 0 dBFS being a
full-scale complex tone; frequencies absolute.  Without a display, plots go
to PNG files (live: rewritten each capture).
"""
import argparse
import datetime
import os
import sys
import tomllib

import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import schema  # noqa: E402
from b210 import B210, ROOT, tones  # noqa: E402

import matplotlib  # noqa: E402
if not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
    matplotlib.use('agg')
import matplotlib.pyplot as plt  # noqa: E402

OUT = os.path.join(ROOT, 'build', 'captures')


# -- configuration -----------------------------------------------------------
def parse_value(text):
    items = [t.strip() for t in text.split(',')]
    conv = []
    for t in items:
        try:
            conv.append(float(t))
        except ValueError:
            conv.append(t)
    return conv if len(conv) > 1 or text.endswith(',') else conv[0]


def configuration(a):
    cfg = tomllib.load(open(a.config, 'rb')) if a.config else {}
    for item in a.set:
        name, _, text = item.partition('=')
        sec, _, key = name.rpartition('.')
        (cfg.setdefault(sec, {}) if sec else cfg)[key] = parse_value(text)
    return schema.normalize(cfg)


def to_toml(cfg):
    fmt = lambda v: (f'"{v}"' if isinstance(v, str)  # noqa: E731
                     else f'{v:g}'.replace('e+0', 'e').replace('e+', 'e') if isinstance(v, float)
                     else '[' + ', '.join(fmt(x) for x in v) + ']' if isinstance(v, list) else str(v))
    lines = [f'{k} = {fmt(v)}' for k, v in cfg.items() if not isinstance(v, dict)]
    for sec, part in cfg.items():
        if isinstance(part, dict):
            lines += ['', f'[{sec}]'] + [f'{k} = {fmt(v)}' for k, v in part.items()]
    return '\n'.join(lines) + '\n'


# -- analysis ------------------------------------------------------------------
def db(p):
    return 10 * np.log10(np.maximum(p, 1e-20))


def spectrum(x, rate, nfft):
    f, p = signal.welch(x, fs=rate, window='blackmanharris', nperseg=nfft, noverlap=nfft // 2,
                        return_onesided=False, scaling='spectrum', detrend=False, axis=-1)
    return np.fft.fftshift(f), db(np.fft.fftshift(p, axes=-1))


def zoom(x, rate, lo, hi):
    w = signal.windows.blackmanharris(x.shape[-1])
    m = min(1 << 16, int(4 * (hi - lo) * x.shape[-1] / rate) + 1)      # 4 points per resolved bin
    z = signal.zoom_fft(x * w, [lo, hi], m=m, fs=rate, endpoint=False, axis=-1)
    return lo + (hi - lo) * np.arange(m) / m, db(np.abs(z / w.sum()) ** 2)


def peaks(f, level, k=5):
    i, _ = signal.find_peaks(level, prominence=20, height=np.median(level) + 20)
    return [(f[j], level[j]) for j in sorted(i, key=lambda j: -level[j])[:k]]


def analyse(x, cfg, rate, nfft, band):
    f, s = spectrum(x, rate, nfft)
    zf, zs = zoom(x, rate, *band) if band else (None, None)
    print(f"{x.shape[1]} samples x {x.shape[0]} ch at {rate / 1e6:.3f} MS/s, centre "
          f"{cfg['rx']['freq'] / 1e6:.3f} MHz, resolution {rate / nfft:.0f} Hz (zoom {rate / x.shape[1]:.1f} Hz)")
    for i, ch in enumerate(cfg['rx']['channels']):
        print(f"  ch{ch}: power {db(np.mean(np.abs(x[i]) ** 2)):6.1f} dBFS, peak {np.abs(x[i]).max():.3f} FS, "
              f"noise floor {np.median(s[i]):6.1f} dBFS/bin")
        for pf, pl in peaks(*((zf, zs[i]) if band else (f, s[i]))):
            print(f"      {(cfg['rx']['freq'] + pf) / 1e6:12.6f} MHz  {pl:6.1f} dBFS")
    return f, s, zf, zs


def draw(fig, cfg, f, s, zf, zs):
    fig.clear()
    axes = fig.subplots(2 if zf is not None else 1, 1, squeeze=False)[:, 0]
    for (ax, fr, lv, title) in ((axes[0], f, s, 'spectrum'), (axes[-1], zf, zs, 'zoom'))[:len(axes)]:
        for ch, row in zip(cfg['rx']['channels'], lv):
            ax.plot((cfg['rx']['freq'] + fr) / 1e6, row, lw=0.6, label=f'ch{ch}')
        ax.set(xlabel='MHz', ylabel='dBFS', title=f"{title}: {cfg['rate'] / 1e6:g} MS/s, gain "
               f"{cfg['rx']['gain']} dB{'' if cfg['test'] == 'none' else ', test ' + cfg['test']}")
        ax.grid(alpha=0.3)
        ax.legend(loc='upper right')
    fig.tight_layout()


# -- commands --------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('cmd', choices=('config', 'rx', 'tx', 'live', 'fft'))
    ap.add_argument('capture', nargs='?')
    ap.add_argument('--config', help='TOML file with any settings')
    ap.add_argument('--set', action='append', default=[], metavar='NAME=VALUE')
    ap.add_argument('--fpga', default=os.path.join(ROOT, 'build', 'fpga', 'usrp_b200.bin'))
    ap.add_argument('--n', type=int, default=1 << 20, help='samples per channel per capture')
    ap.add_argument('--tone', type=float, help='transmit F, 2F on the transmit channels')
    ap.add_argument('--secs', type=float, default=10.0)
    ap.add_argument('--nfft', type=int, default=1 << 14)
    ap.add_argument('--zoom', type=lambda t: tuple(float(v) for v in t.split(':')))
    ap.add_argument('--png', help='plot file')
    a = ap.parse_args()

    if a.cmd == 'fft':
        cfg = schema.normalize(tomllib.load(open(a.capture[:-4] + '.toml', 'rb')))
        fig = plt.figure(figsize=(12, 7))
        draw(fig, cfg, *analyse(np.load(a.capture), cfg, cfg['rate'], a.nfft, a.zoom))
        fig.savefig(a.png or a.capture[:-4] + '.png', dpi=110)
        return
    cfg = configuration(a)
    if a.cmd == 'config':
        sys.stdout.write(to_toml(cfg))
        return
    os.makedirs(OUT, exist_ok=True)
    with B210(cfg, fpga=a.fpga) as sdr:
        waves = (tones([a.tone * (i + 1) for i in range(len(cfg['tx']['channels']))], sdr.rate)
                 if a.tone else None)
        if a.cmd == 'tx':
            if not waves:
                sys.exit('tx needs --tone')
            losses = sdr.tx(waves, a.secs)
            print(f'transmitted {a.secs:g} s, ' + (f'lost: {losses}' if losses else 'nothing lost'))
            return
        fig = plt.figure(figsize=(12, 7))
        if a.cmd == 'rx':
            x = sdr.rx(a.n, tx=waves)
            name = os.path.join(OUT, datetime.datetime.now(datetime.UTC).strftime('%Y%m%dT%H%M%S'))
            np.save(name + '.npy', x)
            open(name + '.toml', 'w').write(to_toml(sdr.config))
            print(f'recorded {name}.npy')
            draw(fig, sdr.config, *analyse(x, sdr.config, sdr.rate, a.nfft, a.zoom))
            fig.savefig(a.png or name + '.png', dpi=110)
            return
        png = a.png or os.path.join(OUT, 'live.png')                     # live
        try:
            while True:
                draw(fig, sdr.config, *analyse(sdr.rx(a.n, tx=waves), sdr.config, sdr.rate, a.nfft, a.zoom))
                if matplotlib.get_backend().lower() == 'agg':
                    fig.savefig(png, dpi=90)
                elif not plt.fignum_exists(fig.number):
                    break
                else:
                    plt.pause(0.01)
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
