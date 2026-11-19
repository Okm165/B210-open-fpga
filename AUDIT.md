# Receive-path audit: measured claims

Every number in this file was produced by a test in `tests/` or by synthesis /
place-and-route output committed under `build/fpga/reports/`. Nothing here is
an estimate. The point of the document is that each claim names its evidence, so
a later change that breaks one of them fails a named test rather than a
conversation.

Scope: the AD9361 pin interface, the receive DSP, packetisation and the GPIF /
USB transport, plus the transmit pin interface. Not in scope: FX3 firmware,
UHD driver internals, RF performance of the AD9361 itself.

## Data flow

```
 AD9361 RX   I in first half of DATA_CLK, Q in second (bus moves t_DDRX after edges)
   |  2 x 12-bit @ 61.44 MHz = 184.32 MB/s of information
   v
 b200_io     IDDR SAME_EDGE x12 + frame          tb_adc_pins
   |  24-bit words, container 245.76 MB/s
   v
 ddc_chain   accumulator -> LUT NCO -> exact mixer -> half-even+saturate
   |         -> single dithered quantiser 24->16; 16x gain, 1 sample/clk
   |                                              tb_ddc_chain, tb_ddc_lossless,
   |                                              tb_dds_lut, tb_rx_static
   v
 new_rx_framer  header + timestamp, 2 samples/beat      tb_rx_stream
   v
 CDC 61.44 -> 100 MHz, 1 word per radio clock           tb_axi_fifo_2clk_cdc
   v
 axi_packet_gate (whole-packet store-and-forward)       tb_axi_packet_gate
   v
 gpif2_slave_fifo32: 64->32 + CDC + gate + FIFO         tb_usb_rate, tb_e2e_rx
   v
 GPIF @ bus_clk (100 MHz constraint, 104.49 MHz routed) -> FX3 -> USB 3.0
                                                         tb_e2e_rx x8 configs
 AD9361 TX  <- b200_io ODDR SAME_EDGE: I rising half, Q falling half
                                                         tb_tx_pins
```

## Measured data

| stimulus | size | evidence |
|---|---|---|
| single tone at -6 dBFS (run "base") | 48 840 samples | peak 16 000 = 16 x 1000, 0.81 LSB16 rms error, gain 0.99997 |
| full-scale tone, LO = 0 (run "fs") | 51 980 words | peak exactly 32 752 = 16 x 2047 (+-2 asserted), rail hits 0 |
| full-scale tone, LO = fs/8 (run "fslo") | 51 980 words | captured peak 32 742 (phase grid), rail hits 0 |
| blocker 1000 counts + tone 2 counts (run "two") | 48 840 samples | weak tone preserved to -0.002 dB, IMD = stimulus's own |
| 100 us USB stalls, repeated (run "stall") | 584 packets | 0 dropped samples, 0 framer full events |
| tone -6 dBFS + noise -24 dBc (run "noisy") | 51 980 words | crest 18 416 = 16 x 1151, rail hits 0, no drops |
| two tones at 1023 counts each (max legal drive) | 130 159 words | peak 32 736 = 16 x 2046, rail hits 0 |
| blocker + 2-count tone, 1 060 057 words | 2^19-sample analysis | weak tone -54.0 dBc preserved, IMD/HD identical to the stimulus's own (0.0-0.2 dB) |
| dead-register hammering | 60 100 samples | 0 mismatches, LO still functional |
| RX pins, I=n / Q=n+2048 | 4291 strobes | pair from one sample period |
| TX pins, counter / counter+2048 | 4000 periods | Q - I = 2048 exactly |
| pseudorandom 12-bit IQ | 200 000 clocks | bit-exact against the integer model |
| tone with live LO | 2^20 samples | image -137.5 dBc |
| three-tone composite | 2^20 samples | no FPGA-added spurs |
| level sweep -100..0 dBFS | 10 levels | SNR = level + 94 dB, no wrap |
| independent full-scale I/Q | 8 phases | saturates, never wraps |
| tagged stream | 30 004 samples | 0 gaps, repeats or reorders |
| TX halfband, defect (hb47_int) | 4 tones, fs_in/32..fs_in/4 | image -23.6 dBc in band, -10.1 dBc at fs/4 |
| TX halfband, fixed (hb47_poly) | same 4 tones | worst spur -88.6 / -86.9 / -81.9 / -86.9 dBc; image -95..-105 dBc |
| TX halfband impulse response | 47 taps, isolated | centre 65536, +-1 41508, +-3 -13273 ...; H(0) 2.0000, H(fs/2) -92.8 dB |
| TX halfband regression | 26th make-test group | taps on odd offsets, phase alignment, image gain and DC pinned |
| TX x2 polyphase phase | impulse symmetry + coherent image at total 2 (single halfband, the MIMO TX rate) | centre tap did not carry the filtered path's delay: image was -1.7 dBc, passband drooped -2.24 dB. One centre register fixes it: images <= -80 dBc, impulse response symmetric at x1/x2/x4/x8 |
| TX pin quantiser | `tb_dac_slice`, all 2^24 codes | round-half-even + saturate; saturation added after rounding was found to wrap the top 2047 codes to 0x800 |
| TX DC gain vs rate | `tb_tx_dc` table in .context/dsp-audit.md | 1.00000 at every power-of-two rate; -1.48 dB at total 6/12, -0.21 dB at 20 (CIC contract) |
| TX scale contract | `tb_tx_dc` section 2, 6 scales x 7 inputs | out24 = in16 x scale >> 7, saturates at overdrive, monotonic, no wrap; full-scale deficit 0.00027 dB (cos(0)=32767/32768) |
| RX static transfer | all 4096 ADC codes, LO at DC | gain 15.9993/16, worst error 1.141 LSB16 (dither), no bias, no rail hit, control-bit map measured |
| Dead code | every module name in scripts/sources.txt scanned against every .v file | `source_flow_control_legacy`, `add_then_mac`, `round_reg` removed; 3 unused parameters removed; 78 sources |
| TX bypass flatness | impulse response at the pin word, FFT vs analytic taps (0.03 dB agreement) | compensator was shaping the max-rate mode (+2.8 dB at 0.2 fs_out); now bypassed at CIC rate 1, measured 0.00 dB across the band |
| FX3 async boundary | `tb_gpif_cdc`, fifo 100 MHz / gpif 101 MHz, 3 ns phase, backpressure | 320/320 words, tlast every packet on the low half, 0 errors |
| TX sample pairing | `tb_tx_pairing`: even 8, odd 7, burst 6+5, self-checking tag | every host sample reaches the DUC once in order; no duplicate/drop/swap, odd pad never leaks |
| Timed TX | `tb_tx_timed`: future tick 40, and a past tick | fires exactly at tick 40; past tick reports TIME_ERROR (8) with a one-clock ack and `run` stays 0 |
| whole-loop rendering | `tb_capture` + `scripts/plot-loop.py` (`make plots`): 28-tone complex multitone, 2 channels, every stage dumped, forward at 61.44 and at x2, and reverse | residual vs the tones -70.9 / -71.3 / -72.3 dB = 1.08 / 1.08 / 0.91 LSB (the RX dither); every tone within 1.14 dB of the injected level; the -30 dB coupling arrives at -30.0 dB on all 14 tones; 12-bit word peaks at 489/2048 with 0 % clipping; one -100 dBFS NCO spur at the digital IF, 34 dB below a 12-bit LSB |
| TX complex corner | `tb_tx_dc`: (32767, 32767) at the LO, compared with a reference that applies the same 18-bit and 24-bit clips | **0 of 448 samples differ** (1500 LSB24); clipped square trajectory, no sign inversion; a sub-rail corner rotates linearly (5792384..5792437 vs 5792618) - overload clips, never wraps |\n| settings writes on a live TX | `tb_tx_retune`: LO retune and rate-register rewrite while streaming, phase-step measured | 0 deviations with no write (worst 0.006 deg); a retune costs **exactly one sample**, independent of step size (47.81 deg for a 32x range of steps), then exact; a rate write **holds 9 samples and drops one sample to zero** even with an unchanged value - rate writes stay config-time, the LO can be retuned live |\n| MIMO clock switch | `tb_clkmux`: `BUFGCTRL` between rx_clk (61.44) and rx_clk/2 (30.72), switched while running, both directions | 61.44 -> 30.72 -> 61.44 MHz; 2-FF synchroniser latency; **0 short pulses after the switchover window**; the only artefact is the truncated final half-cycle inside the window - which is why MIMO switching stays config-time |\n| channel matching | `tb_capture -DMATCH` / `-DALIGN`: both channels on the same signal, coupling off | written two clocks apart the channels differ by **-90.000 deg** at 1.000002 gain (the gap x fs/8, a driver sequence artefact); started together they are **bit-identical** (gain 1.000000, phase 0.0000 deg, residual 0.00 LSB) - the RTL has no channel mismatch |
| converter utilisation | `tb_capture -DCONV -DAMPDEF`: tone-set level swept, 12-bit converters in the loop | residual flat at **-71 dBFS** over the whole range while SNR rises 46.3 -> 59.5 dB; DAC uses 336..721 codes, **0 % clipped** at every level |
| converter-limited loop | `tb_capture -DCONV`: the same 28-tone signal through a modelled 12-bit DAC and 12-bit ADC | residual 9.16 LSB16 = -52.3 dBc = **-71.1 dBFS**, flat and white; the exact-interface loop is -70.9 dBc = -89.6 dBFS, so the digital datapath has **18.6 dB of headroom the converters own** |
| loop ends, both channels | `tb_capture` + `scripts/plot-diff.py`: every hop fitted with its own model (mixer shift removed), both channels graded against their own input words | forward ch0/ch1 **-70.9/-70.9 dB** (1.08 LSB rms); reverse **-72.2/-72.3 dB**; hop table: widening and pin scaling **exact**, TX mixer -91 dBc, RX quantiser -73 dBc; per-tone spread at the forward end identical in both channels (1.40/1.36 dB, the channel comb) |\n| mid-air attribution | `tb_capture` + `scripts/plot-channel.py`: antenna node rebuilt from the pin words with the integer channel, every hop fitted as one gain | air = pins - pins[n-3]/8 + pins1[n]/32 to **0 LSB24** (3 unprimed rows); the +-1 dB band tilt = the echo comb, measured = analytic **0.0000 dB** at all 28 tones; air->host 0.003906 @ -0.001 deg, 0.91/0.92 LSB both channels; reverse air->pins 0.85 LSB; ends vs channel **0.0007 dB / 0.00 deg** with latency TX 4 + RX 23 clocks |\n| loop's one coherent line | `tb_capture` + `scripts/plot-channel.py`: the residual at the forward end after removing the channel | white dither at **-96 dBc and below**, plus one line at the LO of **-80.6 dBc** = the RX `[24:7]` truncation bias (86.8 LSB24 = -81.0 dBc, match to 0.8 dB); with 12-bit converters the bias is **0.00 LSB24** and the line sits at -88.4 dBc, under the converter residual |\n| channel isolation | other channel's tone set in each channel's output, before and after the loop | digital isolation **-84/-89 dBc**; at the loop end -30.6/-30.5 dBc forward (the model's coupling) and -30.1/-30.2 dBc reverse, i.e. **0.0 dB added**; in the reverse loop the input carries exactly what the output carries |\n| converter utilisation | `tb_capture -DCONV` code occupancy and levels | peak -12.8 dBFS, 655/4096 codes (16 %), 0 rail hits; level sweep keeps the residual flat at -71 dBFS while SNR rises 46.3 -> 59.5 dB |\n| whole-radio air loop | `tb_airloop`: 2 channels -> delay+multipath(-18 dB, 3 samples)+AWGN+coupling(-30 dB) -> 2 RX | tracks the analytic model to 0.013 %; EVM -77.6 dB (dither) and rises with injected noise; coupled tone passes at 250.00/250.00 |
| two-tone IMD3 | `tb_imd3`: f1=fs/16, f2=9fs/128 through the TX->RX loopback, 6 levels to peak 31000 (rail 32768) | output 2f1-f2 / 2f2-f1 = -87 to -113 dBc, improving with level; gain flat to 0.0005 dB, no compression before the rail; below a 12-bit converter's own IMD |
| two-channel loopback | `tb_loopback2`: TX->RX and RX->TX, 2 channels at once, LO 0 and fs/8 | gain 1.00000 (-0.0005 dB, the 2x cos(0) convention), mirror <= -98 dB, EVM -78..-79 dB (the RX dither floor), crosstalk <= -102 dB |
| RX overload | `tb_rx_saturate`: full-scale I=Q with a rotating LO | peak +32767, trough -32768, 30-sample rail plateau: clips, never wraps |
| TX underrun | `tb_tx_underrun`: starved from reset with stale data on the bus | run low for 200 idle cycles (0 clocks high): pin mux stays on tx_idle, no stale sample can reach the DAC |
| RX stall tolerance | e2e run with one 200 us stall vs no stall, 400 000 clocks | identically 242 136 words: zero loss; 350 us overruns and recovers; guard for 30 us equal-total added |
| CDC integrity | `tb_axi_fifo_2clk_cdc` at 5 clock relationships (phase 0..3.3 ns, 10:1 ratio, radio faster than bus) | 512/512 words in order in both directions in every case |
| MIMO capture | `tb_adc_mimo`, alternating framed bus, 10k DSP cycles | two independent consecutive half-rate channels, A advances by 2 per cycle, parity stable; AD9361 frame protocol still a hardware item |
| TX passband + images | `tb_tx_passband`, coherent single-bin detector at signal and image bins, validated at bypass | bypass flat within 0.01 dB; total 2 and 4 flat within 0.01 dB over the host band, total 16 -0.13 dB; image rejection worst -80 dBc across the band |
| full build | - | hello.bin, idcode 0x3651093 |

## Operator error budget

Referred to one 16-bit output LSB (3.05e-5):

| operator | error | how it is known |
|---|---|---|
| pin capture (RX) / drive (TX) | 0 / 0 | pair invariants above |
| phase accumulator | 0 | bit-exact replay |
| LUT NCO | 2^-16 = -96.3 dBc | 16-bit table values; interpolation 20 dB lower |
| complex multiply | 0 | 0 of 199 998 mismatches |
| half-even + saturating narrow | ~2^-25 | replay and range test |
| dither + quantiser 24->16 | 94.2 dB SNR measured (94.8 dB derived) | level sweep, Schuchman check corr(err,sig) = -0.001 |
| dither idle behaviour (static input) | mean 16.2474 vs exact 16.25, rms 0.578 LSB, 4 codes | tb_dither_dc; strongest line -141 dBFS = 67 dB below the ADC floor |
| framer, CDC, gate, GPIF | 0 | tag contiguity, 2.008 words per beat |

Composition: 73.96 dB total against 74.00 dB for an ideal 12-bit converter, so
the digital path costs 0.04 dB. The converter, not the pipeline, is the limit.

Rate change and "lossy" operators: the receive path contains none. There is no
decimator, no halfband, no CIC and no filter between the ADC pins and the USB
words, so nothing can droop, alias or be discarded - the host receives every
sample at the full 61.44 MSPS. The band-limiting the receive path relies on is
therefore the AD9361's own digital filters, configured by the driver and outside
this repository; at 30.72 MSPS per channel (MIMO) the chip halves its own rate
and this RTL is unchanged. The transmit path does contain halfband
interpolators, but interpolation is not a lossy operation: it inserts samples
the DAC needs at a higher rate and removes nothing; its filters run at the
transmit rate and cannot affect the received data.

Transmit rotator: the DUC uses the same quarter-wave LUT oscillator and the
same exact 18x18 complex mixer as the receive path, with round-half-even
narrowing and saturation at 18 bits. Both directions therefore share one
oscillator, one mixer and one gain convention, and neither contains a CORDIC.

The CORDIC it replaced had algorithmic gain 1.647 and implementation gain 0.5
(0.8234 net), so its output level depended on the algorithm rather than on the
signal, and a rotated corner vector reached 1.22x full scale - the condition
the DUC header documented. Its guard-bit slice wrapped there (a sign
inversion): measured, 0 wraps with saturation against 8 steps of up to
16 769 546 counts with the slice, and 25 of 1024 output samples differing with
rail-to-rail flips in the DUC.

Gain consequence, measured on the TX chain (DC, scale register at 0x1FFFF,
16-bit input to 24-bit output): 1.77733 counts per input count, symmetric for
both polarities (1 777 329 for +1000, -1 777 842 for -1000). The CORDIC path
measured 1.46338 for the same settings, so the swap raises TX gain by 1.2145 =
1/0.8234 exactly as the removed constant predicts. **The driver multiplies its
TX scale by 0.8234 to keep a previous output level**; full-scale 16-bit input
reaches full-scale 24-bit output at scale 0x8000.

Clipping: the chain applies a 16x gain, so an output component reaches the
16-bit rail only when the complex envelope exceeds 2048 counts, i.e. above the
ADC's own full scale. A circular full-scale signal never clips at any LO; the
rail-corner state (I = Q = 2047) saturates and never wraps.

Measured clipping statistics over 1 M samples, separating what the ADC clips
from what the pipeline alone would clip:

| stimulus | ADC clips | pipeline-only clips |
|---|---|---|
| single tone at full scale | 0.00 % | 0.00 % |
| tone -6 dBFS + noise -20 dBc | 0.00 % | 0.00 % |
| noise, 3-sigma at the rails | 0.54 % | 0.57 % |
| tone at full scale + noise -20 dBc | 23.48 % | 28.36 % |

So at any operating point that keeps the composite envelope inside full scale
the pipeline clips nothing. Clipping appears only where the converter is already
clipping the same signal. The 1/sqrt(2) alternative would remove it at the cost
of 3 dB of host-visible level everywhere.

## Two channels

The B210 runs two radio instances. `tests/tb_pair.v` proves the property rather
than assuming it: two receive chains programmed to the same LO are byte
identical for 3 360 samples - dither included - while a third receive chain
runs at a different LO beside them (so one channel cannot perturb another), a
full-scale 24-bit quadrature input produces zero rail hits, and the two
transmit chains produce the same sample sequence from the same input. The test
fails if the reference chain is pointed at the wrong register address.

## Throughput

| level | required | measured |
|---|---|---|
| ADC 12-bit DDR | 184.32 MB/s | 184.32 |
| pin -> fabric | 245.76 MB/s | 1 pair/clk |
| CDC alone / 64->32 alone | 245.76 | 404 / 402 MB/s |
| packet gate | 245.76 | 252 MB/s at demand |
| full path, 66-sample packets (stress) | 245.76 | 260.4 MB/s, 0 words lost |
| full path, 2046-sample packets (UHD default) | 245.76 | 246.2 MB/s = 100.2 % of payload |
| two channels (MIMO capture) | 245.76 | 2 x 30.72 MSPS sc16; the AD9361 bus is 61.44 MSPS total, so this is the converter limit, not the link |
| shipped bitstream | - | usrp_b210_fpga.bin sha256 `bcf0a6fc17be573e23d1d44a8e5867d4ce122f93340e0ea4500814484ec8d5bb`, idcode 0x3651093, seed 3, RTL last changed at 6706c10 (the x2 halfband centre-tap phase fix; earlier 8eb2502 rounding/saturation/comp-bypass); `scripts/bitstream-provenance.txt` records image + source digest `8ad1cbb` + rtl-commit, and `make image-check` verifies all three against this tree; post-route bus_clk 105.26 MHz (x1.053) / radio_clk 98.58 MHz (x1.604), 5 % policy met; util LUT 51 814 (12 %) / FF 15 610 (3 %) / DSP 158 (18 %) / RAMB36 72 (16 %) |
| packet length | any request up to 4092 | clamped to 2048 samples (half the sample FIFO) |
| USB stall, single | - | 200 us absorbed with zero loss and full catch-up |
| USB stall, sustained | - | 25 % duty absorbed; the interface ceiling is 400 MB/s against 246 MB/s of payload |
| USB stall, over-long | - | 350 us overflows; bounded loss, link returns to 0.616 words/clk by itself |
| bus_clk / radio_clk | 100 / 61.44 MHz | 105.26 (x1.053) / 98.58 MHz (x1.604), post-route, seed 3 |

Timing note (rebuilt after the x2 polyphase fix): the shipping policy is 5 %
margin on every clock.  Seed 3 clears it on every clock without the exception
flag: bus_clk 105.26 MHz (x1.053), radio_clk 98.58 MHz (x1.604), rx_clk
1136.36 MHz.  The centre-tap register did not cost timing; radio_clk improved
from 94.77 to 98.58 MHz.  bus_clk is the tight one at 1.053 - still inside the
1.05 gate.  The residual critical path is the pre-existing
`gpif2_error_checker` comparator chain (seed sensitivity, not DSP logic);
pipelining it is the first margin item, not a gate.

## Invariants that guard the claims

Each one fails loudly if a future change breaks it:

- `tb_adc_pins`   every I/Q pair belongs to one sample period (mutation-tested)
- `tb_tx_pins`    Q(rise) - I(fall) = 2048 for every clock period
- `tb_rx_static`  no dead-register write changes a sample
- `tb_e2e_rx`     rate, packet completeness, unity gain (exactly 16x when the
                  LO is zero), rail hits = 0, zero `full` events; eight
                  configurations: base, fs, fslo, two, noisy, stall, oversize
                  (packet length clamped to 2048), overrun (350 us stall must
                  recover)
- `tb_rx_stream`  tag contiguity through the framer
- `tb_dds_lut`    sin(t) = cos(t - 90 degrees) bit-exactly
- `tb_usb_rate`   words per beat = 2.000 and delivered rate >= requirement
- `tb_dither_dc`  static input: no DC bias, triangular +-1 LSB, four idle codes
- `tb_rx_saturate`  a complex envelope above full scale clips (peak +32767,
                  trough -32768), never wraps
- `tb_tx_timed`   a future-scheduled packet fires at exactly its tick; a past
                  tick raises TIME_ERROR without starting the DAC
- `tb_imd3`      two-tone products at -87..-101 dBc and not growing with level
- `tb_airloop`   two channels through delay+multipath+noise+coupling: tracks
                  the model, EVM at the dither floor, coupling linear
- `tb_loopback2`  two channels, both directions, at once: unity gain, no
                  conjugate, no I/Q leakage, no crosstalk, EVM at the dither
                  floor (LO=0 and a non-zero LO that must cancel)
- `tb_tx_pairing` every host sample reaches the DUC once, in order, across
                  even, odd-length and burst packets (self-checking tag)
- `tb_tx_underrun` starving the host never presents a stale sample (`run` low)
- `tb_gpif_cdc`   FX3 interface at 100/101 MHz with 3 ns phase: 320/320 words,
                  packet boundaries intact
- `tb_cordic_overflow`  TX rotator saturates at the rail instead of wrapping;
                  the old slice makes it jump 16 769 546 counts (two wraps per
                  revolution) and the test fails

## Known limits and open items

1. FX3 slave-FIFO flag timing is modelled, not specified: the read/write
   arbitration of the real device could raise the sustained rate above the
   measured 245-260 MB/s but cannot lower the requirement below it.
2. The UHD transmit scale convention is outside this repository. The TX mixer
   is unity gain, so the driver's scale needs 0.8234x its previous value for
   the same output level; full-scale 16-bit input reaches full-scale 24-bit
   output at scale 0x8000.
3. A square-root-of-two output scale would remove corner-state saturation at no
   system-SNR cost but would lower the host-visible level by 3 dB. Not applied.
4. No on-board FFT is implemented (decided: the link already carries the full
   rate losslessly, and a spectra path would need a new host format and its own
   level-verification campaign). DSP 158 of 840, BRAM36 72 of 445, so it fits.
5. A host stall deeper than ~200 us overruns the FIFOs; the framer then loses a
   bounded number of samples and recovers by itself (measured: 350 us stall,
   240 980 of 242 136 words delivered, last 100 000 clocks back at 0.616
   words/clk). The loss is not reported to the host by design (decided):
   the VITA sequence number counts packets, so a sample gap is invisible.
6. The TX interpolator strobe phase depends on when each channel's rate
   register is written, so the two transmit channels can start a few clocks
   apart. Whether the TX timestamp path absorbs this is a bring-up measurement,
   not a simulated result; it does not affect the receive path.
