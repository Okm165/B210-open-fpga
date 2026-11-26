# Design

Two products, nothing else: the **FPGA image** and the **Rust driver**. The
FPGA moves samples bit exact and executes control operations; the driver
owns everything with logic (AD9361 setup, configuration, streams). Thin
binaries on the driver stream, check, capture and analyse. The wire
between them is docs/PROTOCOL.md.

Scope (definition of done): 2 RX + 2 TX at 2 x 30.72 MS/s and 1 x 61.44 MS/s,
full duplex, lossless; every setting over USB through one configuration;
clocks with measured margin; LEDs; stock FX3 firmware unchanged; no UHD,
no Ettus RTL, no Python.

## Decisions

| Question | Decision |
| --- | --- |
| Protocol | ours: packets, control operations, register map (PROTOCOL.md) |
| FPGA DSP | none; the AD9361 filters and decimates (0.22 to 61.44 MS/s) |
| Wire formats | sc12 (lossless; required for full duplex) and sc16 (code x 16) |
| Host | one Rust crate; no Python |
| Configuration | one declarative TOML, applied whole, only differences written |
| AD9361 driver | UHD 3.15's GPL-3 sequence (ad9361_device.cpp), rewritten minimal in Rust for the B210 alone; proven write for write against traces of UHD's own C++ (tests/ad9361_golden.rs) |
| Sample clock | the AD9361 data clock alone (61.44 MHz in both modes) with a sample strobe in 2-channel mode, as ADI's Pluto and Ettus' e310_io; each sample time crosses to the bus clock in a 16-entry FIFO with its 64-bit time; framing, rings and stream control run at 100 MHz; the bus side counts data-clock edges to see it alive |
| Rings | packet FIFOs of whole packets: rx 2^17 words (512 KiB), tx 2^16 words (256 KiB) |
| Events | counter increases, sent as event packets at most every 100 us; never lost, never blocking data |
| USB crate | nusb (pure Rust usbfs, many transfers in flight, zero-copy buffers) |

## FPGA

```text
 host <-USB-> FX3 <-GPIF-> fx3_pads, fx3_master
   thread 0 tx      -> tx ring  -> tx_deframer -> cdc_fifo -> sample_domain -> DAC
   thread 1 rx      <- rx ring  <- rx_framer   <- cdc_fifo <- sample_domain <- ADC
   thread 2 command -> cmd fifo -> command -> regs, spi_master (AD9361, ADF4001)
   thread 3 result  <- packet_mux <- result fifo (command), event fifo (events)
```

- **fx3_master**: master of the FX3 slave-FIFO bus, one FX3 buffer (one
  packet) per visit, round robin over the four threads.
- **rx_framer**: sample times into rx packets, both channels
  sample-interleaved; drops a packet that does not fit the ring, counts it,
  flags the next; stream start (now or timed), count, stop.
- **tx_deframer**: tx packets into sample times (the inverse of
  rx_framer); checks every header, the sequence within a burst.
- **sample_domain**: everything on the sample clock: the 64-bit time
  counter, the rx source (radio, pattern, tx loopback), tx bursts played at
  their time or at once; 0 to the DAC when idle and in an underflow gap.
- **command**: executes a command packet's operations (WRITE, READ, SPI,
  WAIT, POLL), one result per operation.
- **regs**: the register map, all on the always-running bus clock.
- **events**: counter increases into event packets.

Clocks (`b210.v`): one MMCM from the 40 MHz reference, VCO 1200 MHz:
bus clock 100 MHz, IFCLK 100 MHz lagging it by 66 steps of 45 / 12
degrees, and 200 MHz for the IDELAYCTRL (its reset held past lock,
DS182 >= 52 ns). The sample clock is the AD9361's own DATA_CLK (61.44 MHz
in both modes: 2 x 30.72 or 1 x 61.44 MS/s), taken through one BUFG; the
sample domain runs on it, one sample every period (1R1T) or every other
period (2R2T, the strobe). The bus clock counts DATA_CLK edges to see it
alive and measures the rate; the sample domain is held in reset until
DATA_CLK runs.

Sources:

```text
fpga/
  b210.xdc          pins and clocks
  rtl/
    b210.v          top: clocks, resets, wiring, LEDs
    fx3_pads.v      FX3 pad registers in the I/O blocks
    fx3_master.v    FX3 slave-FIFO bus master, one buffer per visit
    packet_fifo.v   FIFO of whole packets: rings, command, result, event FIFOs
    packet_mux.v    results and events onto one IN thread
    tx_deframer.v   tx packets -> sample times
    rx_framer.v     sample times -> rx packets
    cdc_fifo.v      sample times across bus clock <-> sample clock
    gray_sync.v     Gray-coded counters to the bus clock
    sample_domain.v the sample clock side: time, rx source, tx bursts
    command.v       executes command packets
    regs.v          the register map
    spi_master.v    AD9361 and ADF4001 SPI
    events.v        event packets from counters
    ad9361_io.v     the AD9361 data port: DATA_CLK through one BUFG, the
                    sample strobe, rx/tx words, frames, FB_CLK (RX_IDELAY taps)
    protocol.vh     packet constants (PROTOCOL.md 2)
  tests/            tb_<block>.v per block, tb_b210.v end to end, device
                    models (FX3, SPI, AD9361 port), run.sh
```

## Rust crate (`host/b210`)

```text
src/
  lib.rs          the crate
  proto.rs        PROTOCOL.md: headers, S(L) and the packet splitter, sc12/sc16 packing, operations, results, events, the bus limit
  usb.rs          the FX3's boot and vendor requests (firmware, FPGA load, GPIF reset), the four endpoints, commands one at a time (result and events from EP8), drain, real-time priority
  regs.rs         register addresses and fields (PROTOCOL.md 6), typed reads (time, counters, health)
  stream.rs       the rx loop, the checker of every packet, tx bursts
  config.rs       the TOML schema, its limits, and the ordered operations from one state to another
  device.rs       the AD9361 on the board: its Bus over the FPGA's operations, the RESETB bring-up, a configuration applied
  ad9361/         the AD9361 driver over a Bus of SPI, WAIT, POLL, and the chip's limits (mod.rs), UHD's tables (tables.rs), a recording Bus for tests (mock.rs)
  dsp.rs          spectra: window, scaling, Welch averaging, dBFS; the coherent test tone
  iq.rs           one channel of I/Q on disk (i16 interleaved), per-channel files
  quality.rs      signal quality: level, DC, I/Q balance, SNR, SINAD, SFDR, ENOB, findings
  bin/b210.rs     binary `b210`: load, state, read, write, monitor, rx-test, loop-test, capture
  bin/b210-plot.rs binary `b210-plot`: a capture's report, spectrum, waterfall, time, histogram, constellation in the terminal
  bin/b210-radio.rs binary `b210-radio`: the AD9361 from a configuration file (id, apply, peek, reset)
tests/ad9361_golden.rs   the driver against UHD's C++ traces
examples/config.toml     every configuration key
```

## Code standard (Rust and Verilog alike)

- Each module's header says what it computes, in mathematics with units:
  the formula, its domain, the invariant it keeps.
- No unexplained constant: every number is derived in a comment or named
  from a datasheet section (UG-570/UG-671 page, FX3 firmware line) or a
  board measurement with its conditions.
- Every stated property has a test that would fail without it, and a
  negative control where a check could pass vacuously.
- One name per concept across FPGA, protocol, Rust and docs (rx/tx,
  start/stop, time in ticks, lost in samples).
- Nothing kept "for later": unused types, options and code paths go.
- Documentation lives in the code (module headers, comments), PROTOCOL.md
  and this file; nothing else.

## Order of work (each step proven on the board)

1. FPGA bus master, packets, rings, control, with the test-pattern source;
   Rust usb + proto. Proof: lossless pattern both ways at full rate,
   sequence and time exact (`b210 rx-test`, `b210 loop-test`). Done on the
   board.
2. AD9361 data path: ad9361_io in the top on the AD9361's data clock, the
   Rust ad9361 driver on the board. Done on the board (build 9,
   `d346cc5`; re-run on build 10, `f30268d`, after the tx rule below):
   config applied from the TOML with every poll ok; pattern
   lossless at 2 x 30.72 MS/s (sc12 and sc16) and 1 x 61.44 MS/s; full
   duplex loopback 307.2 M samples back at exactly their ticks in 10 s
   (2 channels) and 5 s (1 channel at 61.44 MS/s); a 3 s radio capture
   kept 89.0 M sample times per channel with nothing lost. Clocks
   104.24 / 104.11 MHz, both crossings 2.14 and 1.78 ns against the
   8.00 ns bound. First real RF (2.45 GHz, 40 / 35 dB gain, no antenna):
   rms -59.2 / -61.6 dBFS, floor -134 dBFS/Hz, DC -151 dBFS, no tone;
   the two ambient carriers repeat at their absolute frequencies and moved
   when the LO moved 100 kHz, so they are external; with no coherent input
   the I/Q balance figure is the signal's, not the receiver's (quality.rs).
   With an antenna: a station at 100.0 MHz (found at -0.5 MHz from a
   100.5 MHz LO, still at 100.0 from a 100.6 MHz LO: external by the LO-shift
   test) rose 65 dB for 70 dB of rx gain, so the gain control is 1:1; the
   chip's own output floor is about -134 dBFS/Hz, which is why at 2.45 GHz
   nothing moves below ~45 dB gain and the example config now asks 60/55 dB.
   No clipping (peak -13.1 dBFS), DC -106 dBFS, image rejection 55-62 dB.
   At 2.45 GHz one 0.5 ms broadband burst (Wi-Fi-like) reached -0.8 dBFS
   with no clipping and no overflow; it appeared on channel 0 only and not
   in a 5 s capture, so it is an external emitter, not the data path.
   The +/-1.31 MHz "pair" first reported as an internal spur was the
   spectrum's own noise maxima: with 64 averaged segments the largest noise
   bin sits 4-5 dB over the median (measured), and the plotter listed the
   six strongest local maxima unconditionally. A peak is now a spur only at
   floor + 10 dB (quality::SPUR_DB, with a gamma-noise test that also pins
   the 6 dB case as noise); the 2.45 GHz captures then report none, while
   the FM stations (about 40 dB over the floor) stay listed.
   The AD9361's own BIST tone (fs/32, -6 dBFS at the chip's rx port, so the
   chip drives the pins the way RF does) now proves the pin capture at both
   rates: 0.9600 MHz at -6.02 dBFS, SNR 67.9 dB, ENOB 11.70 on both
   channels at 2 x 30.72 MS/s (2R2T), and 1.9200 MHz at the same level and
   SNR at 1 x 61.44 MS/s (1R1T); the 12-bit limit at -6.02 dBFS is 68.0 dB,
   so the capture is bit exact. `b210-radio test CONFIG tone|prbs|loopback|
   none` selects it.
   The PRBS mode is checked bit by bit in the host (src/prbs.rs): the chip's
   16-bit generator (taps {2,3,5..16}, ADI's BIST FAQ; Berlekamp-Massey on a
   capture gives complexity 16 with the same taps) puts one bit per word and
   per data line in bit 0, so each line's stream must obey
   s[n] = s[n-2]^...^s[n-16]. Measured on the board: 110,320,320 bits at
   2 x 30.72 MS/s sc16 and 110,276,672 at 1 x 61.44 MS/s sc12, 0 mismatches,
   50.0% ones on both. A single-channel read of the 2R2T stream also passes:
   decimating a maximal-length sequence by 2 is the same sequence shifted,
   so that is not an error detector. The eye scan remains a v1 measurement.
   Build 10 also carries the tx rule that a packet with samples but
   neither START_OF_BURST nor an open burst is malformed (PROTOCOL.md 3.3):
   playing it left the sample side in a burst the deframer could not end.
3. Device API, configuration applied through config.rs, CLI rx / tx /
   record; a board check in just.
4. No Python, no v1 left in the tree (v1 is tag v1-ettus-uhd).

## Not built

- tx stream-control registers (tx packets describe themselves).
- AT (opcode 6) and result status 2: reserved in PROTOCOL.md 4.
- Results carrying the tick an operation took effect.
- PPS: time set at the next PPS, the time of the last PPS.
- Antenna switches follow a stream (ATR): they are driven to UHD's off
  state 1010_0101 and the PA enables stay low; switching per state is not
  built (no configuration key until it is).

## Risks

- Full duplex sc12 is 92 % of the 400 MB/s bus.
- Ring size against host service gaps: rx_hwm / tx_hwm (PROTOCOL.md 6)
  measure the margin.
