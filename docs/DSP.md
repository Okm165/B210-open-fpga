# DSP: what the chains compute and how that is proven

Each of the two radios (`src/rtl/radio_200/radio_legacy.v`) has one receive
chain (`src/rtl/dsp/ddc_chain.v`) and one transmit chain
(`src/rtl/dsp/duc_chain.v`). Both run on `radio_clk`, one sample per clock at
the AD9361's sample rate (the *master clock rate*, up to 61.44 MS/s with one
channel and 30.72 MS/s with two). The host sees `master clock rate / N`,
where N is the decimation or interpolation UHD programs.

The chains are the Ettus USRP3 ones. Four parts are ours, each written to
the same contract as the part it replaces or with a stated improvement:

| Part | Replaces | Why |
| --- | --- | --- |
| `hbdec1.v`, `hbdec2.v` (`hbdec47.v`) | two Xilinx FIR Compiler netlists, prebuilt and not open | the same 47-tap halfband, the same handshake to the clock |
| `src/ip/xilinx_macros.v` `MULT_MACRO` | the Xilinx behavioural macro | a plain signed multiply that Yosys maps to a DSP48E1 |
| guard bit in the `duc_chain.v` CORDIC | nothing; upstream wraps | above an effective amplitude of 1.22 the upstream output changes sign; this one saturates. Below it every bit is the upstream bit |
| `dac_slice.v` | `tx_fe[23:12]` (truncation) | round half to even, then saturate: no -0.5 LSB bias, half the error power, and a full-scale sample can no longer round to -2048 |

## Receive: AD9361 -> host

```text
12-bit ADC code, top of a 24-bit word
  -> front-end mux (sr 3: swap I/Q, invert I, invert Q, real mode)
  -> CORDIC NCO (sr 0: 32-bit phase increment, top 24 bits used)  gain 1.647 x 0.5
  -> CIC decimator, 4 stages, rate R = 1..255 (sr 2)            gain R^4, shifted down by 2^ceil(log2 R^4)
  -> halfband 1 (hbdec1, sr 2 bit 9), halfband 2 (hbdec2, sr 2 bit 8), each /2
  -> round 24 -> 19 bits, clip -> 18 bits
  -> multiply by the 18-bit scale word (sr 1)                    one DSP48E1 per rail
  -> clip 36 -> 33 bits
  -> round_sd 33 -> 16 bits: first-order error-feedback rounding
  -> 16-bit I and Q to the framer
```

UHD 3.15 (`host/lib/usrp/cores/rx_dsp_core_3000.cpp`) splits a decimation N
as follows: if N is even, halfband 1 takes a factor 2; if what is left is even,
halfband 2 takes another; the CIC takes the rest. So 1 is a bypass, 2 is one
halfband, 4 is two, 8 is two plus CIC 2, and 3 (or any odd N) is the CIC
alone, which UHD warns about because nothing then corrects the CIC's droop.

The scale word undoes what the shifts leave of the CORDIC and CIC gain:

    scale = round(2^16 x 2^ceil(log2 R^4) / (1.648 x R^4))

At decimation 1 this is 39767, and a 12-bit code k leaves the chain as
about 16 x 0.9993 x k. That factor is the `PRBS_GAIN` the bit-exact receive
check expects. UHD writes the second radio's front-end mux with I and Q
inverted, so a signal common to both channels comes out 180 degrees apart.

## Transmit: host -> AD9361

```text
16-bit I and Q from the deframer
  -> halfband interpolators (hb47_int x 2, sr 2 bits 8 and 9), each x2
  -> CIC interpolator, 4 stages, rate R (gain R^3, shifted)
  -> CORDIC NCO, one bit wider than upstream, clipped back to 24 bits
  -> multiply by the 18-bit scale word (sr 1)
  -> 24-bit word -> dac_slice -> 12-bit DAC code
```

Interpolation is split the same way as decimation, and the scale word is
`round(2^16 x 2^ceil(log2 R^3) / (1.648 x R^3))` (`tx_dsp_core_3000.cpp`;
both directions divide further by a `peak` stream argument for the 8-bit
wire format). The 12-bit code goes to `b200_io.v`, which drives
it onto the AD9361's transmit port unchanged.

## How correctness is established

Every check below compares against something independent of the thing
being checked, and each has a negative control: the same check, given a
known fault, has to fail.

### 1. Against the original, in simulation (`just test golden`)

- `tests/tb_ddc_golden.v` and `tests/tb_duc_golden.v` run this repository's
  chain and the original Ettus RTL (`tests/ref/ettus_dsp`, module names
  prefixed by `tests/mk_ettus_ref.py`) side by side on the same random
  input and register writes. Every output sample must be identical, at the
  same clock: 16 receive configurations (decimation 1, 2, 3, 4, 6, 8, 12,
  16, 61, 128, 254, 256, 512, so every halfband setting and the CIC from
  1 to its limit; the front-end mux settings UHD uses; tuning on and off)
  and 14 transmit configurations.
  Negative controls: a chain that ignores its rate register, and one given
  the scale word of a chain without the CORDIC's gain, must fail.
- `tests/tb_hbdec.v` checks `hbdec1`/`hbdec2` against a model that shares
  nothing with them: the 47 coefficients of `hb47.coe` written out, a
  history of accepted samples, one 64-bit sum per output, and the handshake
  measured on the Xilinx netlists (an output every second input, fixed
  latency, `data_valid` low for the first 23 outputs after reset).
- `tests/tb_dac_slice.v` checks `dac_slice` on all 2^24 input codes.
- `tests/tb_tx_dc.v` and `tests/tb_rx_saturate.v` check the guard bit and
  the receive clip: rails instead of sign changes.

### 2. The same after synthesis (`just test postsyn`)

The board runs what Yosys makes of the RTL, not the RTL. Yosys 0.69 has a
DSP packing fault (YosysHQ/yosys#6311): a product or sum register with a
reset or enable that is wider than its value loses its sign bits, so
negative values come out as large positive ones. RTL simulation can't see
this. So the golden benches are repeated on the synthesized netlists
of the chains and halfbands (`tests/postsyn.sh`, the build's own flags),
and `tests/check_dsp_packing.py` requires Yosys's own `check` after DSP
mapping to report no dangling register bit in the complete design. A
reproducer (`tests/yosys_dsp_signext.v`) shows the fault on the installed
Yosys, which proves the check can detect it.

### 3. On the board, bit for bit (`scripts/dsp_exact.py`, gate step `dsp`)

The AD9361 can replace its converters with digital sources, so no RF is
involved:

- **receive**: its 16-bit pseudo-random BIST sequence (`UHD_AD936X_BIST=0x09`)
  enters the chain, captured at decimation 1, 2, 3, 4, 8 and 16 on both
  channels;
- **transmit**: in digital loopback (`UHD_AD936X_LOOPBACK=1`) the transmit
  port is returned on the receive port, and the host sends a known block
  over and over, at interpolation 1 and 4.

Icarus Verilog runs the repository's `ddc_chain`/`duc_chain` on the same
input, with the register values UHD 3.15 derives (printed with their UHD
source lines), and every captured sample is compared.

One part of the chain has unbounded memory: `round_sd` carries its rounding
error from sample to sample, and its state at the start of a capture
depends on everything received since reset. No simulation from reset can
reproduce that state. The comparison therefore carries every rounder state
that is consistent with the capture so far. It starts with all of them, and
each sample narrows the set; a sample that no remaining state can produce
is a mismatch. A single wrong count empties the set within a sample or two,
so this is a bit-for-bit comparison, not a statistical one. A mismatch is
then classified: an isolated altered word (computed right, damaged on the
way), a burst, or a systematic difference (a datapath that computes
something else).

`--override NAME=VALUE` gives the model one wrong register value; that
run has to fail.

### 4. On the board, spectrally (`scripts/sample_check.py`, gate step `samples`)

The AD9361's digital test tone (fs/32) on receive, and host tones through
the loopback on transmit (F on channel 0, 2F on channel 1, half of full
scale), at the modes UHD users run: 2 x 30.72 MS/s, 1 x 61.44 MS/s,
decimation and interpolation 4, and the 12- and 8-bit wire formats.

The whole capture is analysed in overlapping power-of-two windows (Blackman,
main lobe +-6 bins), and the worst window counts:

| Metric | Definition |
| --- | --- |
| level | power within the tone's main lobe, dBFS |
| SFDR | tone power / largest single bin outside the tone and DC |
| SINAD | tone power / everything outside the tone, DC included |
| DC | power within +-6 bins of 0 Hz |
| I/Q | amplitude ratio of I and Q |
| phase relation | between the two channels, invariant to a common delay: phi0 - phi1 for equal tones, 2 phi0 - phi1 for F and 2F |

The signals are digital and deterministic, so a healthy image gives the same
numbers every time, within 0.5 dB over every recorded run. The requirements
are those numbers: level -3.66 dBFS within 0.3 dB, DC below -63 dBFS, phase
relation 180 degrees within 2 (one sample of skew between the channels moves
it by 11 degrees or more), and SFDR and SINAD at most 2 dB below the
values `scripts/hw_gate.sh` lists per mode. The vendor image fails the x4
transmit mode (SINAD 62.7 dB against 73.6) because it truncates where
`dac_slice` rounds. That makes it the negative control.

### 5. Bit exact at the full rate (`sample_check.py --prbs`)

At decimation 1 and the 16-bit wire format, every 12-bit code is recovered
from the DDC output (`k = round(x / (16 x gain))`, polarity per channel) and
the AD9361's sequence is checked word by word: W' = {W[14:0], ^W[15:4] ^
^W[2:1]}, with the I/Q consistency the generator guarantees. The gate runs
this 8 times on two channels at 30.72 MS/s (2.1 M samples each) and once
at 61.44 MS/s. It requires zero errors, the samples within half a code of
the PRBS levels, and both channels carrying the same word at the same index.
The last requirement proves the two receive channels are sample aligned.

## Measured on the board (image `0479bb71`)

| Mode | SFDR | SINAD | DC |
| --- | --- | --- | --- |
| receive tone, 2 x 30.72 and 1 x 61.44 MS/s | 73.4 dB | 62.5 dB | -68.7 dBFS |
| receive tone, decimation 4 | 81.2 to 81.7 dB | 64.7 to 64.8 dB | -68.7 dBFS |
| transmit, interpolation 4 | 82.3 / 85.5 dB | 73.6 / 74.1 dB | -97 / -103 dBFS |
| transmit, 2R2T x 30.72 MS/s, 12-bit wire | 69.8 / 70.3 dB | 58.6 / 59.0 dB | -67 / -68 dBFS |
| transmit, 1 x 61.44 MS/s, 8-bit wire | 58.1 dB | 43.9 dB | below -200 dBFS |

The receive tone's SINAD is the AD9361 test tone's own 12-bit quantisation;
decimation 4 gains about 2 dB of it back through the halfbands. The 12- and
8-bit wire formats are limited by their own quantisation. Bit exact: the
pseudo-random sequence through decimations 1, 2, 3, 4, 8 and 16 and the
loopback at x1 and x4 match the RTL on every sample, and 8 x 2 x 2.1 M PRBS
samples arrived with no error and the channels aligned.

## Limits that remain

- Odd decimations and interpolations use the CIC alone; its passband droop
  is not compensated (as upstream, and UHD warns).
- `round_sd`'s state is not reset when a stream starts, as upstream. That
  is harmless, but it is why the board comparison tracks the state instead of
  simulating it.
- The transmit CORDIC differs from upstream only above an effective
  amplitude of 1.22, where upstream wraps. The golden bench stays below it;
  `tests/tb_tx_dc.v` covers the region above.
