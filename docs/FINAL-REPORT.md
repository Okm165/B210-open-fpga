# Final report: the datapath, measured

This is the operator page.  Every number below is measured in simulation by a
bench or a plot page named beside it; nothing here is estimated from a model
unless it says so.  The gate that guarantees all of it still holds is
`make release-check` (105 benches, image identity, clean tree).

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

## 6. Measurement traps that were found the hard way

Recorded so they are not repeated (detail in `dsp-audit`):

* Grade a hop against the node that actually entered it, never against the
  clean generator; the air node carries the transmit interpolator's shape, so
  loop residuals cancel it by construction.
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

    make release-check   # signoff: 105 benches, image identity, clean tree
    make deploy          # build/deploy: image + provenance + checklist

Image `build/fpga/bitstream/usrp_b210_fpga.bin`, sha256
`bcf0a6fc17be573e23d1d44a8e5867d4ce122f93340e0ea4500814484ec8d5bb`,
IDCODE 0x3651093, reproduced byte-for-byte from a clean build.  Bring-up
procedure and pass criteria: `build/deploy/bring-up-checklist.md` (sections 0
and 8 are the pre-flight and the measured level/rate rules).

What simulation cannot settle, and the hardware session must: AD9361 MIMO
frame protocol and channel skew (scope), analogue IQ imbalance, PA
compression, FX3 flag timing, Doppler.  Everything else above is closed.
