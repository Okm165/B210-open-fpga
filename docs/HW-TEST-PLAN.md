# Hardware bring-up & measurement plan (B210 Kintex-7, serial 31B92DD)

Every step has a single observable result over **USB + terminal only**.
RX only — no TX is issued anywhere in this plan.

## 0. Image provenance (do this first, always)

| which | what | why |
|---|---|---|
| vendor known-good | `OpenSourceSDRLab/B210-Kintex-7` release v1.0 | control sample: proves the unit and host stack |
| ours | `build/deploy/usrp_b210_fpga.bin` from `make build` | the project under test |

Install as `/usr/share/uhd/images/usrp_b210_fpga.bin` (or set
`UHD_IMAGES_DIR`). Keep the vendor file as `usrp_b210_fpga.bin.vendor`
and our build separately; never overwrite without a copy.

## 1. Load the bitstream (our loader, standard FX3 protocol)

    python3 scripts/hw_load.py build/deploy/usrp_b210_fpga.bin

Pass: state RUNNING(4), "FPGA CONFIGURED". Fail states:
- `5 UNCONFIGURED` = DONE never asserted → wrong device/bitstream or no
  config clock. (This is what a Spartan-6 stock image does here.)
- `1 FPGA_READY` stuck = PROGRAM_B/INIT_B handshake broken.

## 2. Control path — the heartbeat

    uhd_usrp_probe --args="type=b200,serial=31B92DD,fpga=$PWD/build/deploy/usrp_b210_fpga.bin"

Pass: `Mboard: B210`, `FPGA Version: <n>`, **both**
`Register loopback test passed`.
Failure signature `wait_for_ack` timeout = the FPGA is not answering on
the GPIF control sockets. Check, in this order:
1. is IFCLK actually toggling? (an ODDR with D1=D2=const emits DC — the
   exact bug we shipped; verify `.D2(1'b0)` in `src/top/b200.v`)
2. is the FPGA MMCM locked (`clocks_ready`)?
3. is the GPIO reset line from the FX3 (CTL9) releasing the design?

## 3. Codec & clocking

Pass criteria:
- master clock rate sets to 16 MHz automatically at open, and 30.72/61.44
  on request, with "Actually got clock rate ..." matching
- `lo_locked = true` at 70/433.92/915/2400 MHz
- sensors readable: `temp`, `rssi`, `lo_locked`

## 4. Streaming — both channels, full rate

    python3 scripts/rx_capture.py --rate 30.72e6 --chans 2 --secs 1 \
        --freq 100e6 --gain 30 --out build/rx/ours_dual
    python3 scripts/rx_capture.py --rate 61.44e6 --chans 1 --secs 0.5 \
        --freq 100e6 --gain 30 --tag rx_1ch_61M --out build/rx/ours_single

Pass:
- 2 ch: full 30.72 MSPS per channel (61.44 MSPS aggregate), 0 overflows
- 1 ch: 61.44 MSPS, 0 overflows → 61.44e6 × 4 B = **245.76 MB/s**
- both channels have many distinct codes and are not identical

**Hardware limits (measured, not assumed):**
- 2 RX: 30.72 MSPS/channel (tick-rate limit)
- 1 RX: 61.44 MSPS
- analog filter bandwidth ≤ 56 MHz

## 5. Signal quality

    python3 scripts/rx_quality.py --dir build/rx/ours_dual --tag <tag>

Reports per channel: noise floor (dBFS), SNR, SFDR, ENOB, DC offset,
IQ image rejection, top spurs with frequency, and cross-channel
correlation. Pass: DC ~0 at min gain, no stuck words (longest run < 64),
channels independent (corr != 1), spur table stable across captures.

## 6. Tuning & settings matrix

    python3 scripts/usrp_settings.py --chans 2 --out build/settings

Exercises and measures: rate, frequency (range + error), gain (0–76 dB
sweep → sensitivity curve), analog bandwidth sweep, antenna port,
DC/IQ correction (auto/manual/off), clock source, time source, sensors,
and enumerates all 54 RX tree paths.

## 7. Failure matrix (what each symptom means)

| symptom | meaning | first check |
|---|---|---|
| probe times out at `wait_for_ack` | FPGA silent on GPIF control | IFCLK actually toggling (ODDR D1/D2), MMCM lock, GPIO reset |
| state 5 UNCONFIGURED | FPGA never asserted DONE | image for the wrong device, config SPI, part ID |
| `recv()` returns 1 sample/call, ~1.3 MSPS | **host buffer shape**: pyuhd needs `(nchannels, nsamples)` | fix the capture buffer, not the hardware |
| overflow storm `OOOO` | host not draining; frame size/count, RT priority, IRQ affinity | `num_recv_frames=512`, `recv_frame_size` multiple of 8 and NOT of 1024 |
| data all zeros at gain 40 | no RF input / frontend disabled | antenna port, gain, LO lock |
| FX3 log `! CyU3PPibInit` after a reconfig | ALREADY_STARTED (benign; fw never calls PibDeInit) | ignore unless PIB never starts |
| counters show nothing useful | `GET_COUNTERS` **auto-resets on every read** | read twice, second read = activity since first |

## 8. Measurement checklist for "ready for deployment"

- [ ] our bitstream loads and reaches RUNNING
- [ ] probe: FPGA Version + both loopback tests pass
- [ ] 2 RX @ 30.72 MSPS: 0 overflows, independent channels
- [ ] 1 RX @ 61.44 MSPS: 0 overflows (245.76 MB/s)
- [ ] quality report: DC, spurs, IQ image, cross-correlation recorded
- [ ] settings report: gain/bandwidth/LO/clock/time all exercised
- [ ] PNGs archived per capture (spectrum, time domain, histogram,
      constellation, quality/spur plot)
- [ ] TX left disabled (no stream, no burst) for this phase
