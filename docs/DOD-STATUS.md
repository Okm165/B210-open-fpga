# DOD status — 2 RX live from our Kintex-7 design (RX only, no TX)

Board: OpenSourceSDRLab Custom_SDR_B210, serial 31B92DD, XC7K325T,
USB 2500:0020, SuperSpeed (5000M), UHD 4.9.0.1, FX3 fw compat 8.0.

## 1. Hardware operability (measured, not assumed)

| measurement | result | evidence |
|---|---|---|
| device probe | B210, FPGA v16.0, both register loopback tests pass | `uhd_usrp_probe` |
| control path | FPGA answers peeks/pokes on GPIF control sockets 2/3 | loopback test |
| 2 RX @ 30.72 MSPS/ch | 30.73M samples in 1.0 s, 5 overflows, independent channels (corr −0.48) | `build/rx/dod_dual_fullrate/` |
| 1 RX @ 61.44 MSPS | 61.4 MSPS, **0 overflows** = 245.76 MB/s | `build/rx/dod_single_fullrate/` |
| tuning range | 70 / 433.92 / 915 / 2400 MHz all `lo_locked`, <0.1 Hz error | `build/settings/settings_report.json` |
| gain range | 0–76 dB, rms 0.00 → 0.93 LSB sensitivity curve | `build/settings/tuning_gain_bandwidth.png` |
| bandwidth | 0.2–56 MHz sweep measured | same |
| real RF | FM band 88–108 MHz, peaks 43–53 dB over floor at 30.72 MSPS, 0 overflows | `build/rx/env_fm/env_scan_fm.png` |
| LO sweep | 101 LOs 100–900 MHz, all captured | `build/rx/dod_sweep_fullrate/` |
| signal quality | floor/SNR/SFDR/ENOB/DC/IQ-image/spur tables per channel | `build/rx/*/quality_*.json/.png` |
| sensors | temp 38.7 °C, rssi, lo_locked | settings report |
| RX tree | 54 property paths enumerated | settings report |

Hardware limits: 2 RX = 30.72 MSPS/ch, 1 RX = 61.44 MSPS, analog BW ≤ 56 MHz.

## 2. Root cause of our own image being silent

`src/top/b200.v` drove the FX3's PCLK with an ODDR configured
`D1=1'b1, D2=1'b1`. With `DDR_CLK_EDGE="OPPOSITE_EDGE"` that is a
**constant logic high — no clock at all**. Every GPIF experiment ran on a
clockless interface. Found by diffing against the vendor's genuine
Vivado source; fixed to `D1=1, D2=0` (0°), verified in the synthesized
netlist (`ODDR_U: D1=1, D2=0`).

Two false leads of ours, retracted in `docs/ANALYSIS.md`:
- "1 sample per VITA packet / 1.3 MSPS ceiling" — a pyuhd **buffer-shape**
  bug in our capture script; correct shape is `(nchannels, nsamples)`.
  Real rate is full.
- hand-rolled raw peek probe — times out even on the known-good vendor
  image, so it is not a valid instrument.

## 3. Pre-flight equivalence with the vendor image

| item | ours | vendor | verdict |
|---|---|---|---|
| FPGA compat | 16.0 | 16.0 | match |
| signature register | 0xACE0BA5E | 0xACE0BA5E | match |
| GPIF/control RTL | identical (+comments) | — | match |
| radio core | vendor minus `SOURCE_FLOW_CONTROL` (vendor sets 0) | — | equivalent |
| RX framer | vendor + our maxlen clamp / overflow recovery | — | superset |
| XDC pins | identical set (GPS pins commented out in both) | — | match |
| electrical | SLEW SLOW on all P-port pins, IFCLK DRIVE 8 | same | match |

## 4. Tooling delivered

- `scripts/hw_load.py` — standard FX3 protocol loader (0x55/0x02/0x12,
  status 0x83, hash 0x1C)
- `scripts/rx_capture.py` — full-rate continuous capture + FFT/time/
  histogram/constellation PNGs + npy, overflow accounting, tuning sweeps
- `scripts/rx_quality.py` — floor, SNR, SFDR, ENOB, DC, IQ image, spurs,
  cross-channel correlation
- `scripts/usrp_settings.py` — every RX control exercised with measurement
- `scripts/build_verify.sh` — build (with P&R seed retries) → load →
  probe → full-rate captures → quality/settings, unattended
- `docs/HW-TEST-PLAN.md` — ordered bring-up with pass criteria and a
  symptom→cause matrix

## 5. Open item

Our bitstream must finish place-and-route and then pass the probe and
the full-rate captures. Everything needed to judge it is automated.

TX is not used anywhere in this phase. The design retains 2R2T DSP
pipelines; enabling TX is a configuration step after RX is signed off.
