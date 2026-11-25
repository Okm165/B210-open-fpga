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

Clocks (step 1, `b210.v`): one MMCM from the 40 MHz reference, VCO
1200 MHz: bus clock 100 MHz, IFCLK 100 MHz lagging it by 66 steps of
45 / 12 degrees, and a 61.54 MHz test sample clock (1200 / 19.5) with a
strobe every `strobe_div` + 1 cycles in place of the AD9361's data clock.

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
    ad9361_io.v     the AD9361 data port (step 2; benched, not yet in the top)
    protocol.vh     packet constants (PROTOCOL.md 2)
  tests/            tb_<block>.v per block, tb_b210.v end to end, device
                    models (FX3, SPI, AD9361 port), run.sh
```

## Rust crate (`host/b210`)

```text
src/
  lib.rs          the crate
  proto.rs        PROTOCOL.md: headers, S(L), sc12/sc16 packing, operations, results, events
  usb.rs          the FX3's boot and vendor requests (firmware, FPGA load, GPIF reset), the four endpoints, the result/event reader thread
  regs.rs         register addresses and fields (PROTOCOL.md 6)
  config.rs       the TOML schema, its limits, and the ordered operations from one state to another
  ad9361/         the AD9361 driver over a Bus of SPI, WAIT, POLL (mod.rs), UHD's tables (tables.rs), a recording Bus for tests (mock.rs)
  dsp.rs          spectra: window, scaling, Welch averaging, dBFS
  iq.rs           one channel of I/Q on disk (i16 interleaved), per-channel files
  quality.rs      signal quality: level, DC, I/Q balance, SNR, SINAD, SFDR, ENOB, findings
  bin/b210.rs     binary `b210`: load, read, write, monitor, rx-test, loop-test, capture
  bin/b210-plot.rs binary `b210-plot`: a capture's report, spectrum, waterfall, time, histogram, constellation in the terminal
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
   Rust ad9361 driver on the board. Proof: BIST tone, PRBS bit exact on
   both channels, digital loopback, eye scan.
3. Device API, configuration applied through config.rs, CLI rx / tx /
   record; a board check in just.
4. No Python, no v1 left in the tree (v1 is tag v1-ettus-uhd).

## Not built

- tx stream-control registers (tx packets describe themselves).
- AT (opcode 6) and result status 2: reserved in PROTOCOL.md 4.
- Results carrying the tick an operation took effect.
- PPS: time set at the next PPS, the time of the last PPS.
- Antenna switches, PA enables and ATR following tx_active / rx streams
  (held off in step 1).

## Risks

- Full duplex sc12 is 92 % of the 400 MB/s bus.
- Ring size against host service gaps: rx_hwm / tx_hwm (PROTOCOL.md 6)
  measure the margin.
