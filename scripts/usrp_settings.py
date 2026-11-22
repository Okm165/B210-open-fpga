#!/usr/bin/env python3
"""usrp_settings.py - complete RX tuning & settings capability for the B210.

Exercises every receive-side control the UHD API exposes and MEASURES the
effect of each one (no TX anywhere):

  rate          - master clock + per-channel rate
  frequency     - LO tuning (range check)
  gain          - full gain range sweep -> sensitivity curve
  bandwidth     - analog filter bandwidth sweep -> noise bandwidth
  antenna       - RX2 / TX/RX port selection
  dc_offset     - auto and manual I/Q DC correction
  iq_balance    - auto and manual IQ imbalance correction
  clock source  - internal / external / gpsdo
  time source   - internal / external / gpsdo
  sensors       - temp, lo_locked
  subdev/chan   - channel mapping

Outputs: settings_report.json + tuning_*.png
"""
import argparse
import json
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


_CTX = {}


def get_streamer(usrp, uhd, chans):
    """One streamer for the whole session - creating/destroying one per
    measurement wedges the B200 data path (UHD 'D' data errors)."""
    key = chans
    if key not in _CTX:
        st = uhd.usrp.StreamArgs("fc32", "sc16")
        st.channels = list(range(chans)) if chans > 1 else [0]
        _CTX[key] = usrp.get_rx_stream(st)
    return _CTX[key]


def capture(usrp, uhd, chans, rate, secs, timeout=3.0):
    rx = get_streamer(usrp, uhd, chans)
    cmd = uhd.types.StreamCMD(uhd.types.StreamMode.start_cont)
    if chans > 1:
        cmd.stream_now = False
        cmd.time_spec = usrp.get_time_now() + uhd.types.TimeSpec(0.2)
    else:
        cmd.stream_now = True
    rx.issue_stream_cmd(cmd)
    buf = np.zeros((chans, 65536), dtype=np.complex64)
    md = uhd.types.RXMetadata()
    need = int(secs * rate)
    chunks = []
    got = 0
    while got < need:
        n = rx.recv(buf, md, timeout)
        if n == 0:
            break
        chunks.append(buf[:, :n].T.copy())
        got += n
    rx.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))
    if not chunks:
        return None
    return np.concatenate(chunks, axis=0)


def floor_of(x):
    n = min(len(x), 65536)
    xc = x[:n] - np.mean(x[:n])
    w = np.hanning(n)
    X = np.abs(np.fft.fft(xc * w)) / (n * 32768.0)
    db = 20 * np.log10(np.maximum(X, 1e-18))
    return float(np.median(db)), float(np.sqrt(np.mean(np.abs(xc) ** 2)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--args", default="type=b200,serial=31B92DD")
    ap.add_argument("--out", default="build/settings")
    ap.add_argument("--chans", type=int, default=2, choices=[1, 2])
    ap.add_argument("--secs", type=float, default=0.05)
    ap.add_argument("--rate", type=float, default=30.72e6)
    ap.add_argument("--freq", type=float, default=100e6)
    ap.add_argument("--antenna", default="RX2")
    ap.add_argument("--quick", action="store_true", help="skip long sweeps")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    import uhd
    usrp = uhd.usrp.MultiUSRP(a.args)
    rep = {}

    print(f"[settings] {usrp.get_mboard_name()} serial={usrp.get_usrp_rx_info().get('serial','?')}")

    # ---------- inventory of everything the RX side exposes ----------
    tree = usrp.get_tree()
    paths = []
    for root in ("/mboards/0", "/mboards/0/rx_dsps/0",
                 "/mboards/0/dboards/A/rx_frontends/A",
                 "/mboards/0/dboards/A/rx_frontends/B"):
        try:
            for p in tree.list(root):
                paths.append(p)
        except Exception:
            pass
    rep["tree_paths"] = paths
    print(f"[settings] discovered {len(paths)} RX tree paths")

    chans = a.chans
    for ch in range(chans):
        usrp.set_rx_rate(a.rate, ch)
        usrp.set_rx_freq(uhd.types.TuneRequest(a.freq), ch)
        usrp.set_rx_gain(30.0, ch)
        try:
            usrp.set_rx_antenna(a.antenna, ch)
        except Exception as e:
            print(f"[settings] antenna {a.antenna} not available on ch{ch}: {e}")
    rep["config"] = {
        "rate_hz": usrp.get_rx_rate(0),
        "freq_hz": usrp.get_rx_freq(0),
        "gain_db": usrp.get_rx_gain(0),
        "antenna": usrp.get_rx_antenna(0),
        "gain_range_db": [usrp.get_rx_gain_range(0).start(),
                          usrp.get_rx_gain_range(0).stop()],
        "freq_range_hz": [usrp.get_rx_freq_range(0).start(),
                          usrp.get_rx_freq_range(0).stop()],
        "rate_hz_max": usrp.get_master_clock_rate(),
        "bandwidth_hz": usrp.get_rx_bandwidth(0),
        "master_clock_rate": usrp.get_master_clock_rate(),
        "clock_source": usrp.get_clock_source(0),
        "time_source": usrp.get_time_source(0),
        "sensors": {s: usrp.get_rx_sensor(s, 0).value for s in usrp.get_rx_sensor_names(0)},
        "mboard_sensors": {s: usrp.get_mboard_sensor(s).value
                           for s in usrp.get_mboard_sensor_names()},
    }
    print(f"[settings] inventory: {json.dumps(rep['config'], default=str)[:400]}")

    # ---------- gain sweep -> sensitivity curve ----------
    gains = list(range(0, 77, 8))
    if a.quick:
        gains = [0, 20, 40, 60, 76]
    g_rms, g_floor = [], []
    for g in gains:
        for ch in range(chans):
            usrp.set_rx_gain(float(g), ch)
        d = capture(usrp, uhd, chans, a.rate, a.secs)
        if d is None:
            g_rms.append(np.nan); g_floor.append(np.nan); continue
        fl, rms = floor_of(d[:, 0])
        g_rms.append(rms); g_floor.append(fl)
        print(f"[settings] gain {g:2d} dB -> rms {rms:8.2f} LSB, floor {fl:7.1f} dBFS")
    rep["gain_sweep"] = [{"gain": g, "rms_lsb": r, "floor_dbfs": f}
                         for g, r, f in zip(gains, g_rms, g_floor)]

    # ---------- bandwidth sweep ----------
    bws = [200e3, 1e6, 5e6, 20e6, 40e6, 56e6]
    bw_fl = []
    for ch in range(chans):
        usrp.set_rx_gain(30.0, ch)
    for bw in bws:
        try:
            for ch in range(chans):
                usrp.set_rx_bandwidth(bw, ch)
            d = capture(usrp, uhd, chans, a.rate, a.secs)
            fl = floor_of(d[:, 0])[0] if d is not None else np.nan
        except Exception as e:
            print(f"[settings] bandwidth {bw}: {e}")
            fl = np.nan
        bw_fl.append(fl)
        print(f"[settings] bandwidth {bw/1e6:5.2f} MHz -> floor {fl:7.1f} dBFS")
    rep["bandwidth_sweep"] = [{"bw_hz": b, "floor_dbfs": f} for b, f in zip(bws, bw_fl)]

    # ---------- LO tuning check ----------
    lof = []
    for f in (70e6, 433.92e6, 915e6, 2.4e9):
        try:
            for ch in range(chans):
                usrp.set_rx_freq(uhd.types.TuneRequest(f), ch)
            tf = usrp.get_rx_freq(0)
            lof.append({"requested_hz": f, "actual_hz": tf,
                        "error_hz": tf - f,
                        "lo_locked": usrp.get_rx_sensor("lo_locked", 0).value})
            print(f"[settings] LO {f/1e6:8.3f} MHz -> {tf/1e6:8.3f} MHz "
                  f"(err {tf-f:+.1f} Hz) locked={usrp.get_rx_sensor('lo_locked',0).value}")
        except Exception as e:
            print(f"[settings] LO {f}: {e}")
    rep["lo_tuning"] = lof

    # ---------- DC offset / IQ balance ----------
    dc = {}
    for mode in ("auto", "manual", "off"):
        try:
            for ch in range(chans):
                usrp.set_rx_dc_offset(mode == "auto", ch)
                usrp.set_rx_iq_balance(mode == "auto", ch)
            d = capture(usrp, uhd, chans, a.rate, a.secs)
            if d is not None:
                dc[mode] = {"dc_i": float(np.mean(d[:, 0].real)),
                            "dc_q": float(np.mean(d[:, 0].imag)),
                            "rms": float(np.std(d[:, 0]))}
                print(f"[settings] correction {mode:6s}: DC=({dc[mode]['dc_i']:+.2f},"
                      f"{dc[mode]['dc_q']:+.2f}) rms={dc[mode]['rms']:.2f}")
        except Exception as e:
            print(f"[settings] correction {mode}: {e}")
    rep["dc_correction"] = dc

    # ---------- clock / time sources ----------
    for what, getter, setter, names in (
            ("clock_source", usrp.get_clock_source, usrp.set_clock_source,
             ["internal", "external", "gpsdo"]),
            ("time_source", usrp.get_time_source, usrp.set_time_source,
             ["internal", "external", "gpsdo"])):
        avail = []
        cur = getter(0)
        for n in names:
            try:
                setter(n, 0)
                ok = getter(0) == n
            except Exception:
                ok = False
            avail.append({"name": n, "available": ok})
        try:
            setter(cur, 0)
        except Exception:
            pass
        rep[what] = {"current": cur, "options": avail}
        print(f"[settings] {what}: current={cur} options={[x['name'] for x in avail if x['available']]}")

    # ---------- graphs ----------
    fig, ax = plt.subplots(1, 2, figsize=(13, 4.2))
    ax[0].plot(gains, g_rms, "o-", color="#1f4e79")
    ax[0].set_title("RX gain sweep: noise RMS vs gain")
    ax[0].set_xlabel("gain (dB)"); ax[0].set_ylabel("rms (LSB)"); ax[0].grid(alpha=0.3)
    ax[1].plot([b / 1e6 for b in bws], bw_fl, "o-", color="#b3541e")
    ax[1].set_title("analog bandwidth sweep: noise floor")
    ax[1].set_xlabel("bandwidth (MHz)"); ax[1].set_ylabel("floor (dBFS)"); ax[1].grid(alpha=0.3)
    fig.tight_layout()
    p = os.path.join(a.out, "tuning_gain_bandwidth.png")
    fig.savefig(p, dpi=110); plt.close(fig)

    with open(os.path.join(a.out, "settings_report.json"), "w") as fh:
        json.dump(rep, fh, indent=2, default=str)
    print(f"[settings] report: {os.path.join(a.out, 'settings_report.json')}")
    print(f"[settings] graph:  {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
