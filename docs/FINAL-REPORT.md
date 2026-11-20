# Final report: the datapath, measured

This is the operator page.  Every number below is measured in simulation by a
bench or a plot page named beside it; nothing here is estimated from a model
unless it says so.  The gate that guarantees all of it still holds is
`make release-check` (120 benches, image identity, clean tree).

## 1. What the design does

Two AD9361 channels, one 61.44 MHz clock, one datapath per direction:

| direction | chain | rate |
|---|---|---|
| receive | pins (12b) -> I/Q map -> NCO mix -> `>>>8` + round-half-even -> 16b -> TPDF-dithered quantiser | **61.44 MSPS, no decimation** |
| transmit | 16b -> x4 widen -> 2x 47-tap halfband (bypassable) -> CIC N=4 (rate 1..255) -> inverse-sinc comp -> NCO mix -> 18b saturate -> 24b pin word -> 12-bit `dac_slice` (round-half-even + saturate) | **61.44 MSPS**, host = 61.44/2^k |

Receive is deliberately at the full converter rate: the ADC's sample rate and
all 12 bits are preserved, so RX is at the converter limit and the fabric is
not the constraint.  Rate agility lives on the transmit side only, which is
what makes the two directions asymmetric by design.

## 2. The loop, both directions, both channels

A virtual wire connects TX pins through a modelled channel (two paths plus
1/32 cross-coupling) into RX, so one capture contains the whole radio.  The
stimulus is 7 tones per channel with disjoint sets.

| end-to-end | residual | note |
|---|---|---|
| forward, ch0 / ch1 | **-70.9 dBc**, 1.08 LSB16 | against the air node |
| reverse, ch0 / ch1 | **-72.2 / -72.3 dBc**, 0.92 LSB16 | against the antenna |
| forward with 12-bit DAC+ADC | -71.1 / -71.2 dBFS | converter-modelled |
| reverse with 12-bit DAC+ADC | -71.2 dBFS | converter-modelled |

Per-hop ledger (forward ch0; reverse is the mirror): host->interp **exact**
(x4), interp->mixer -91 dBc, mixer->pin **exact** (x64), RX->host -73 dBc.
Nothing adds more than -85 dBc except the quantiser, which is the designed
floor.  `plots/loop_ends_diff.png`, `plots/loop_proof.png`.

## 3. Every in-band difference, attributed

| term | size | cause |
|---|---|---|
| x1 (bypass) | **0.000 dB** flat to Nyquist, 256.000 absolute | none |
| x2 / x4 | **-0.256 dB** at 0.439 fs_host, flat to 0.404 | 47-tap halfband shoulder |
| adjacent emission, all interpolated rates | **-30.5 dBc** at 0.439 fs_host, -70 dBc at 0.337 | the same shoulder |
| x8 / x16 | **-0.402 / -0.788 dB** tilt from DC | CIC sinc^4, only partly compensated |
| 12-bit DAC+ADC in band | flat **-52 dBc**, <= 0.005 dB shape | converter quantisation |
| mid-air change (forward only) | the modelled channel | the channel, not the datapath |
| intermodulation, 50 tones | **none found** | datapath is linear |
| everything else digital | bit-exact or -71 dBc dither | - |

The one page that is input-referred (so it cannot hide behind the air node) is
`plots/loop_inband.png`: forward = channel x halfband x 1/256 to 0.001 dB,
reverse = exactly 1.000.  The rate family is `plots/loop_rates.png`, where the
dashed model is built from the RTL's own taps (47 halfband + CIC sinc^4 + the
15 compensator coefficients) and matches all five curves to 0.001 dB.

Root cause of the x8/x16 tilt: the CIC droop is a function of the host-rate
fraction, while the compensator is a fixed FIR at the DAC rate, i.e. of
*absolute* frequency.  At x16 the signal sits four times lower in absolute
terms and the compensator has only +0.11 dB to give against -0.64 dB of droop.
The tilt is exactly drive-independent, so it is a filter, not rounding.

## 3b. TX level and the rate range, against the driver that will set it

Two rate questions were settled by checking the RTL against UHD's own code
(`tx_dsp_core_3000.cpp`), not against assumption:

* **The level is rate-independent at every rate UHD can request.**  The CIC
  shifter leaves `R^3/2^ceil_log2(R^3)` (0.843 at CIC rate 3, 0.669 at 7) -
  which this repository's earlier notes called a "calibration error".  It is
  not: UHD writes exactly the reciprocal (`2^ceil_log2(R^3)/R^3`) into the TX
  scale register (SR_TX_DSP+4), so shifter x scale = 1.000000 at every rate.
  The RTL's suggestion of a Q15 reciprocal table was hardware for a problem
  the driver already solves; the comment now says so.
* **The CIC rate never exceeds its 37-bit accumulator's limit of 128.**  UHD's
  TX rate menu (512 down to 1) is stepped 4, then 2 above 128 - stripping
  exactly the two halfbands in front of the CIC - so the slowest TX rate,
  61.44 MHz/512 = 120 kSPS, has a CIC rate of exactly 128.  Odd interpolation
  rates above 128 are not in UHD's menu; a custom driver writing one would
  overflow the accumulator.

Both properties are held by `scripts/check_rates.py`, run in the test gate
(`RATES: PASS - 256 UHD TX rates, CIC rate <= 128, ... level off by 1.1e-16`).

## 4. Converters, headroom, and how hard to drive

The chain maps host full scale onto the DAC rail **one-to-one**, measured:
32767 x4 = 131068 of 131071 (18b), x64 = 8 388 352 of 8 388 608 (24b),
>>12 = 2048 of 2048 codes (12b).  So the DAC is addressed to its last code and
no gain is lost in the scaling; all "headroom" is the signal's own crest factor.

| drive (14-tone set) | signal | residual | SNR | DAC peak | host clip |
|---|---|---|---|---|---|
| 3500 | -24.8 dBFS | -71.1 dBFS | 46.3 dB | 235/2048 | 0 % |
| 16000 | -11.6 dBFS | -71.1 dBFS | 59.5 dB | 1073/2048 | 0 % |
| 24000 | -8.0 dBFS | -71.0 dBFS | 63.0 dB | 1609/2048 | 0 % |
| 28000 | -6.9 dBFS | **-21.2 dBFS** | 14.3 dB | 1877/2048 | **0.29 %** |

The first word to run out is the **16-bit host word**, not the DAC: the
residual collapses 50 dB there while the DAC clip counter still reads zero
(`plots/loop_level_sweep.png`).  Never hand the datapath more than +-32767.

## 5. Both channels together (MIMO)

With both channels driven by the same signal at the band edge (tones to
6.75 MHz), a **gated start** gives **bit-identical** ends in both x1 and x2 -
every tone 0.0000 dB / 0.000 deg, so a beam points the same way at every
frequency.  A naive start (registers written while running) gives a constant
**-90.000 deg** at every rate, because the two write gaps are one fs/8
increment; the data path itself has no skew.  Channel isolation at the loop
end equals the modelled -30.1 dB coupling with **no added crosstalk on either
channel**.  `plots/loop_inband_match.png`, `plots/loop_ends_diff.png`.

## 5a. The frontend-control path (the one with no DSP in it)

TX_ENABLE, the band-select lines and the LEDs are driven by `gpio_atr` /
`gpio_atr_io` off UHD's SR_ATR+0..5 registers.  It has no DSP, so it had no
bench - which is exactly the kind of block that quietly ruins a first session.
`tests/tb_atr.v` now holds the contract: after reset the lines are **driven**
(DDR = all ones) and hold IDLE with TX_ENABLE low; idle/rx/tx/full-duplex
select their own registers with **run_* to pin = 5 clocks (81 ns)** and no
runt; ATR-disable forces IDLE; DDR = 0 releases the pins.  On the bench,
TX_ENABLE therefore trails `run_tx` by 81 ns, i.e. the PA is off for the
first and last ~5 samples of a burst.

## 5b. The one self-test the hardware can run alone

`radio_legacy` has `rx_fe = loopback ? tx : rx`, a mux that feeds the transmit
register back into the receive chain with no converters and no air.  It is the
first thing a bench session can run, and it is *not* the chain-level wire of
`tb_loopback2`: it sits after `dac_slice` and after the 12-bit `tx[31:16]`
placement, so what comes back is the DAC code, not the 24-bit datastream.

Measured in the loop bench's new `-DLOOPBACK` mode, both channels, 14 tones
(`plots/loop_digloop.png`):

| | ch0 | ch1 |
|---|---|---|
| gain | 0.999906 (-0.0008 dB) | 0.999882 (-0.0010 dB) |
| phase | constant | constant |
| residual | **-55.10 dBc**, 4.65 LSB16 | **-55.13 dBc**, 4.63 LSB16 |
| one 12-bit code round trip | 4.62 LSB16 | 4.62 LSB16 |

So the loopback is exactly as good as one 12-bit code round trip and no
better: the error distribution is bounded by +/-half a code with no in-band
structure.  Two things for the bench: the phase is the TX/RX NCO phase
relationship and is arbitrary on hardware (grade magnitude and flatness, not
phase), and a loopback capture that shows better than -55 dBc at this drive
is not possible - that is the slice, not the radio.

That mux, however, **cannot be switched on from stock UHD**: UHD's B200
register map starts at `SR_SPI = 8`, its driver writes only `SR_TEST = 21` (a
control-bus pattern test) and runs the AD9361's codec self-test, and the B200
exposes no user-register write.  Address 6 needs a custom host tool or a
driver patch.  The reachable self-test is therefore an attenuated TX->RX SMA
cable, which adds both converters and the analogue path.  Its simulated
expectation (`plots/loop_digloop.png` prints it) is *identical* to the mux -
-55.10 / -55.13 dBc - because after `dac_slice` the word already sits on the
12-bit grid, so an ideal ADC's quantiser is idempotent.  Anything worse on
hardware is the analogue chain, not the FPGA.

## 6. Measurement traps that were found the hard way

Recorded so they are not repeated (detail in `dsp-audit`):

* Grade a hop against the node that actually entered it, never against the
  clean generator; the air node carries the transmit interpolator's shape, so
  loop residuals cancel it by construction.
* **A gate target that is never called runs no benches.**  `test` chained to
  `test-data` and stopped; `test-data2` - the two-channel loopback, the
  whole-radio air loop, IMD3, TX linear phase, the packet gate, the clock
  mux, the retune - was orphaned, so "105 PASS" did not include it, and its
  last line invoked *itself*, which made a direct run recurse forever.  The
  chain is fixed (test-data -> test-data2) and the gate now reports 120.
* A page must be drawn from the capture its own target produced.  `make plots`
  runs the converter capture and draws it; `make plots-levels` then re-runs
  that same capture at each sweep point and leaves the last one in the build
  directory.  Running the plot script by hand after a sweep therefore redraws
  the converter page from the last sweep point - which happened once in this
  session and was caught by comparing against the archive.
* A testbench *model* of an RTL block is an assumption.  The transmit
  converter was modelled for several rounds; comparing it with the synthesised
  slice found 32 of 2048 samples differing by one code, all at exact half-LSB
  ties (the model rounds away from zero, the RTL to even).  The loop now
  instantiates `dac_slice`, so the pin word is `dac_slice << 12` exactly.  The
  ADC stays a model by necessity - the AD9361 is out of tree.
* A **periodic** stimulus or dither has a periodic quantisation error, which
  lands on DFT bins instead of spreading: a single-bin spur audit on it stops
  at about -55 dBc.  The discriminator is the **drive level** - a product of
  the signal scales, a fixed absolute level does not.
* With a +/-k stimulus the interpolation image lands on the negative-sign
  tone; use a one-sided stimulus to see it.
* Take the bin index from the capture length, not from the host period
  (a wrong period made the x2 MIMO match look frequency-dependent).
* The CIC model argument is `sin(pi*R*u)/(R*sin(pi*u))`; the reciprocal form
  claims "flat" exactly where the hardware droops.

## 7. Deploy

    make release-check   # signoff: 120 benches, image identity, clean tree
    make deploy          # build/deploy: image + provenance + checklist

Image `build/fpga/bitstream/usrp_b210_fpga.bin`, sha256
`bcf0a6fc17be573e23d1d44a8e5867d4ce122f93340e0ea4500814484ec8d5bb`,
IDCODE 0x3651093, reproduced byte-for-byte from a clean build.  Bring-up
procedure and pass criteria: `build/deploy/bring-up-checklist.md` (sections 0
and 8 are the pre-flight and the measured level/rate rules).

What simulation cannot settle, and the hardware session must: AD9361 MIMO
frame protocol and channel skew (scope), analogue IQ imbalance, PA
compression, FX3 flag timing, Doppler.  Everything else above is closed.
