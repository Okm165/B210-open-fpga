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
                                                         tb_e2e_rx x4 configs
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

Clipping: the chain applies a 16x gain, so an output component reaches the
16-bit rail only when the complex envelope exceeds 2048 counts, i.e. above the
ADC's own full scale. A circular full-scale signal never clips at any LO; the
rail-corner state (I = Q = 2047) saturates and never wraps.

## Throughput

| level | required | measured |
|---|---|---|
| ADC 12-bit DDR | 184.32 MB/s | 184.32 |
| pin -> fabric | 245.76 MB/s | 1 pair/clk |
| CDC alone / 64->32 alone | 245.76 | 404 / 402 MB/s |
| packet gate | 245.76 | 252 MB/s at demand |
| full path | 245.76 | 259.9 MB/s, 0 words lost |
| USB stall tolerance | - | 100 us absorbed, overflow 100-150 us |
| bus_clk / radio_clk | 100 / 61.44 MHz | 105.42 / 96.17 MHz |

## Invariants that guard the claims

Each one fails loudly if a future change breaks it:

- `tb_adc_pins`   every I/Q pair belongs to one sample period (mutation-tested)
- `tb_tx_pins`    Q(rise) - I(fall) = 2048 for every clock period
- `tb_rx_static`  no dead-register write changes a sample
- `tb_e2e_rx`     rate, packet completeness, unity gain (exactly 16x when the
                  LO is zero), rail hits = 0, zero `full` events; five
                  configurations: base, fs, fslo, two, stall
- `tb_rx_stream`  tag contiguity through the framer
- `tb_dds_lut`    sin(t) = cos(t - 90 degrees) bit-exactly
- `tb_usb_rate`   words per beat = 2.000 and delivered rate >= requirement
- `tb_dither_dc`  static input: no DC bias, triangular +-1 LSB, four idle codes

## Known limits and open items

1. FX3 slave-FIFO flag timing is modelled, not specified: the read/write
   arbitration of the real device could raise the sustained rate above the
   measured 245-260 MB/s but cannot lower the requirement below it.
2. The UHD transmit scale convention is outside this repository; the DUC clips
   above roughly -13 dBFS input at scale 0x1FFFF.
3. A square-root-of-two output scale would remove corner-state saturation at no
   system-SNR cost but would lower the host-visible level by 3 dB. Not applied.
4. No on-board FFT is implemented; the link carries the full rate losslessly.
