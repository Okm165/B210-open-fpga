# v2 design

Two products, nothing else: the **FPGA image** and the **Rust driver**. The
FPGA moves samples bit exact and executes control operations; the driver
owns everything with logic (AD9361 setup, configuration, streams). A thin
CLI on the driver receives, transmits, records and shows spectra.

Scope (definition of done): 2 RX + 2 TX at 2 x 30.72 MS/s and 1 x 61.44 MS/s,
full duplex, lossless; every setting over USB through one configuration;
clocks with measured margin; LEDs; stock FX3 firmware unchanged; no UHD,
no Ettus RTL, no Python.

## Decided

| Question | Decision |
| --- | --- |
| Protocol | ours: packets, control operations, register map |
| FPGA DSP | none; the AD9361 filters and decimates (0.52 to 61.44 MS/s) |
| Wire formats | sc12 (lossless; required for full duplex) and sc16 (code x 16) |
| Host | one Rust workspace; no Python |
| Configuration | one declarative TOML, applied whole, only differences written |
| AD9361 driver | UHD's GPL-3 sequence (the one that runs this board in v1), rewritten minimal in Rust; proven write for write against v1's SPI log on the board, then BIST tone, PRBS, loopback |
| Sample clock | the AD9361 data clock alone (61.44 MHz in both modes) with a sample strobe in 2-channel mode, as ADI's Pluto and Ettus' 7-series e310_io; each sample time crosses to the bus clock in a 16-entry FIFO with its 64-bit time (a 32-bit ring port at 61.44 MHz could not also carry packet headers at sc16 top rate); framing, rings and stream control run at 100 MHz; the bus side counts data-clock edges to see it alive |
| USB crate | nusb (pure Rust usbfs, many transfers in flight, zero-copy buffers) |

## FPGA: what it does

```text
 AD9361 -- io (kept) --+-- rx_framer ----> [rx ring] --> usb_tx --+
                       +-- tx_deframer <-- [tx ring] <-- usb_rx --+-- fx3 bus master -- FX3
                       sample_domain (64-bit sample counter, PPS) |
 bus clock: command (operation list) -> registers, spi_master (AD9361, ADF4001), gpio/atr
            events -> control endpoint
 kept from v1: clk_gen, io, leds, diag_echo
```

- **rx_framer**: both channels into one packet, sample-interleaved; drops
  a packet that does not fit the ring, counts it, flags the next.
- **tx_deframer**: takes tx packets apart into sample times (the inverse of
  rx_framer).
- **sample_domain**: everything on the sample clock: the time counter, the
  rx source, and tx bursts played from their time (or now); zero output
  when idle, after a burst and on underflow; antenna switches follow.
- **command**: executes a list of operations per control packet: WRITE, READ,
  SPI, WAIT, POLL, AT_TIME; one result per operation (status, value,
  tick it took effect).
- **Registers** (all on the always-running bus clock): ID, version, build
  hash, scratch; status (locks, AD9361 clock present); time; rx and tx
  stream control; gpio/atr; counters (packets, drops, underflows, late,
  ring high-water marks).

Sources (step 1):

```text
fpga/
  b210.xdc          pins and clocks
  rtl/
    b210.v          top: clocks, resets, wiring, LEDs
    fx3_pads.v      FX3 pad registers
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
    ad9361_io.v     the AD9361 data port
    protocol.vh     packet constants (PROTOCOL.md 2)
  tests/            tb_<block>.v per block, device models, run.sh
```

### Packet (16-byte header, 32-bit little-endian words)

| Word | Content |
| --- | --- |
| 0 | length (bytes), type (rx, tx, command, result, event), format, channel mask |
| 1 | sequence, flags: HAS_TIME, START_OF_BURST, END_OF_BURST, OVERFLOW |
| 2-3 | time of the first sample, in sample ticks |

Data packets are exactly 16 384 bytes (one FX3 buffer) unless the driver
asks for fewer samples per packet (latency at low rates) or at the end of
a burst, when a short packet ends with
PKTEND, padded off multiples of 1024 bytes. sc12: four complex samples in
three 32-bit words (bit order fixed in the protocol file).

### Stream rules

- rx: start now or at a time; N samples (last packet END_OF_BURST) or
  continuous; stop now or at a time. Continuous never stops on overflow.
- tx: a burst starts at its time or now and ends with END_OF_BURST. Events:
  LATE (burst dropped), UNDERFLOW, SEQ_ERROR, BURST_ACK, each with its tick.
- time: set now or at next PPS, read last PPS; rate changes only with
  streams stopped.

## Rust workspace

```text
host/
  b210/        library: the driver
    usb.rs        FX3 load, FPGA load, endpoints, async transfers, real-time thread
    proto.rs      packet header, sc12/sc16 packing, control operations
    ad9361.rs     bring-up, rates, tuning, gains, calibrations, test modes
    config.rs     the schema: settings, ranges, defaults, diff
    device.rs     Device: open, apply, rx, tx, rx_stream, tx_stream, time
  b210-cli/    binary `b210`: config, rx, tx, live, fft, record (SigMF)
```

API (names identical in library and CLI):

```text
Device::open(&cfg)?    dev.apply(&cfg)?    dev.config()
dev.rx(n, at)? -> (samples, meta)          dev.tx(&samples, at)?
rx = dev.rx_stream()?  rx.start(at, count)  rx.read(n)? -> (samples, meta)  rx.stop(at)
tx = dev.tx_stream()?  tx.write(&samples, at, end_of_burst)?  tx.events()
meta: time (ticks), lost (samples), flags
```

Configuration (every setting, once):

```toml
rate = 30.72e6
otw  = "sc12"
test = "none"          # none, tone, prbs, loopback
[rx]
channels  = [0, 1]
freq      = 100e6      # one synthesizer for both channels
bandwidth = 20e6
gain      = [30, 30]
antenna   = ["RX2", "RX2"]
[tx]
channels  = [0, 1]
freq      = 100e6
bandwidth = 20e6
gain      = [0, 0]
```

Recordings: SigMF (`.sigmf-data` ci16_le interleaved per channel,
`.sigmf-meta` with a capture segment at every gap and every change).

## Code standard (Rust and Verilog alike)

- Each module's header says what it computes, in mathematics with units:
  the formula, its domain, the invariant it keeps (e.g. ring capacity
  C bytes holds C / (rate x channels x bytes per sample) seconds).
- No unexplained constant: every number is derived in a comment or named
  from a datasheet section (UG-570/UG-671 page, FX3 firmware line).
- Every stated property has a test that would fail without it, and a
  negative control where a check could pass vacuously.
- One name per concept across FPGA, protocol, Rust and docs (rx/tx,
  start/stop, time in ticks, lost in samples).
- Nothing kept "for later": unused types, options and code paths go.

## Order of work (each step proven on the board)

1. FPGA bus master, packets, rings, control, with a test-pattern source;
   Rust usb + proto. Proof: lossless pattern both ways at full rate,
   sequence and time exact.
2. Rust ad9361. Proof: its SPI writes equal UHD's on this board; BIST
   tone, PRBS bit exact on both channels, loopback, eye scan.
3. Device, config, CLI (rx, tx, live, zoom FFT, SigMF); v2 gate in just.
4. Delete v1: UHD, Ettus RTL, rx_dump, UHD patches, all Python.

## Risks

- Full duplex sc12 is 92 % of the 400 MB/s bus: measured in step 1.
- Ring size against BRAM (up to 384 of 445 RAMB36): sized from measured
  USB service gaps.
- Committing full FX3 buffers without PKTEND: checked first with diag_echo.
