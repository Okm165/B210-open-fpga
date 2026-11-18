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
 GPIF @ bus_clk (100 MHz constraint, 105.42 MHz met) -> FX3 -> USB 3.0
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
| TX DSP windows, CORDIC isolated | 5 x 1024, 4095 x 2 | linear, image 1.3 %, rotator 123.2 dB |
| TX rotator, corner at full scale, rotating | 4096 samples | saturates at the rail, 0 wraps, worst step 15 015 of 8 388 608 |
| TX rotator, small signal, rotating | 4096 samples | latency 22 clocks measured, worst error 3 LSB of full scale |
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
sample at the full 61.44 MSPS. The transmit path does contain halfband
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
| shipped bitstream | - | b200.bin sha256 5ac2552d..., idcode 0x3651093, from seed 5, margin policy enforced |
| packet length | any request up to 4092 | clamped to 2048 samples (half the sample FIFO) |
| USB stall, single | - | 200 us absorbed with zero loss and full catch-up |
| USB stall, sustained | - | 25 % duty absorbed; the interface ceiling is 400 MB/s against 246 MB/s of payload |
| USB stall, over-long | - | 350 us overflows; bounded loss, link returns to 0.616 words/clk by itself |
| bus_clk / radio_clk | 100 / 61.44 MHz | 116.95 (x1.169) / 92.49 MHz (x1.505) |

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
   level-verification campaign). DSP 110 of 840, BRAM36 72 of 445, so it fits.
5. A host stall deeper than ~200 us overruns the FIFOs; the framer then loses a
   bounded number of samples and recovers by itself (measured: 350 us stall,
   240 980 of 242 136 words delivered, last 100 000 clocks back at 0.616
   words/clk). The loss is not reported to the host by design (decided):
   the VITA sequence number counts packets, so a sample gap is invisible.
6. The TX interpolator strobe phase depends on when each channel's rate
   register is written, so the two transmit channels can start a few clocks
   apart. Whether the TX timestamp path absorbs this is a bring-up measurement,
   not a simulated result; it does not affect the receive path.
