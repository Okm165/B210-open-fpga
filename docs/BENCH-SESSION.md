# Bench session runbook — B210 with this FPGA image

Companion to `bring-up-checklist.md` (pass criteria) and `DEPLOY.txt`
(bitstream identity).  This file is the *sequence*: what to run, in what
order, what to expect, and what a given failure exonerates.  Every numeric
expectation below was measured in simulation; a hardware mismatch never
condemns the RTL until layers 1-3 are excluded.

Log format: one line per step, `STEP nn: PASS/FAIL/OBSERVATION <numbers>`,
and every capture file named with the image sha256 prefix `c1cc09dd`.

---

## Layer 0 — board is alive (fail here => do not debug RF)

```
# flash: use the UHD image loader with this file
uhd_image_loader --args="type=b200" --fpga-path=usrp_b210_fpga.bin
uhd_find_devices                 # exercises SPI (tb_spi S1-S7) + control ABI
uhd_usrp_probe                   # expect 2 radios, master_clock_rate 61.44e6
```

| expect | why it matters |
|---|---|
| device enumerated | FX3 load, control packets, and the SPI that configures the codec all work |
| probe prints both radios | ATR + codec configuration reachable |

FAIL here -> scope GPIF_CTL* flags; the RF layers are unreachable.

## Layer 1 — RX, no RF input

```
uhd_rx_cfile -N 1048576 --freq 1e9 --rate 61.44e6 --type sc16 \
  --args master_clock_rate=61.44e6 rx_idle.cfile
```

- both channels, 10 s: console must show no `O`/`D`.
- File stats (python one-liner below): I and Q not constant, not stuck, no
  repeated 12-bit code runs longer than the codec noise floor.

```
python3 - <<'PY'
import numpy as np
d = np.fromfile('rx_idle.cfile', dtype=np.int16).astype(float)
z = d[0::2] + 1j*d[1::2]
print('rms %.1f  max %d  distinct %d  stuck-runs %d'
      % (abs(z).std(), abs(z).max(), len(np.unique(z.view(np.int64))),
         max((len(list(g)) for k,g in __import__('itertools').groupby(z)), default=0)))
PY
```

## Layer 2 — TX into a load, then the cable loop

```
uhd_tx_cfile --freq 1e9 --rate 61.44e6 --type sc16 --args master_clock_rate=61.44e6
# waveform: 7-tone set, total rms <= -8 dBFS, peak <= 32767  (never more!)
```

- Scope TX pins: level ~1 V into the load at the set amplitude; PA enable
  trails run by **81 ns**; no glitch on enable.
- Cable TX->RX with 20-30 dB pad, capture RX:

```
python3 - <<'PY'
import numpy as np
r = np.fromfile('rx_loop.cfile', dtype=np.int16).astype(float)
z = r[0::2] + 1j*r[1::2]
tx = np.load('tx_wave.npy')        # the complex waveform you sent
lag = np.argmax(np.correlate(abs(z), abs(tx), 'full')) - len(tx) + 1
a  = np.vdot(tx, z[lag:lag+len(tx)]) / np.vdot(tx, tx)
res = z[lag:lag+len(tx)] - a*tx
print('gain %.6f (%+.4f dB) phase %+.3f deg  residual %.1f dBc'
      % (abs(a), 20*np.log10(abs(a)), np.degrees(np.angle(a)),
         10*np.log10(np.mean(abs(res)**2)/np.mean(abs(a*tx)**2))))
PY
```

| expect | means |
|---|---|
| gain 1.0000 ± 0.01 after pad | level contract holds |
| residual **no better than −55 dBc** at the reference drive | the 12-bit code round trip; better would mean the loopback is not the path you think |
| residual worse than −55 dBc | the analogue chain — calibrate, never touch the RTL first |

## Layer 3 — both channels, MIMO, both directions

- Two different tone sets (disjoint), both channels, cable loop: per-tone
  gain flat, crosstalk at the other channel's tones ≤ the pad's isolation.
- **Gated start**: write both channels' registers with `run` low, release
  both -> relative phase 0.000°.  Naive start -> exactly −90.000°.
  A *frequency-dependent* offset instead = AD9361 MIMO frame — hardware-only.
- Reverse (source -> RX -> TX): TX pin word must reproduce the source at
  unity gain; the TX path is the mirror of the RX one (sim: −72 dBc).

## Layer 4 — real RF and the rate family

- Tone at 1/10/20 MHz, −8 dBFS rms: image ≤ −61 dBc in band; harmonics are
  the codec's, not the FPGA's.
- Rate sweep 61.44/x for x = 1,2,4,8,16: band rules x2/x4 0.375 fs_host,
  x8 ~0.17, x16 ~0.10 fs_host; TX level must be **rate-independent** (UHD's
  scale register cancels the CIC); the x8/x16 tilt −0.402/−0.788 dB is the
  CIC droop and is expected.
- Throughput: 10 min dual-channel sc16 capture; a 200 µs host stall costs
  nothing; overruns only below ~246 MB/s sustained.

## Failure ladder

```
analogue (cable, pad, antenna)  -> pin mapping (XDC, frontend swap)
   -> control path (SPI, ATR, GPIF)  -> DSP (never first)
```

The FPGA's contract is the checklist's tables.  A mismatch between hardware
and this document is an observation until layers 1-3 are excluded; only then
may the RTL be suspected, and the suspect hop must be named (the sim pages
name every hop).
