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
  capture.rs      one channel of I/Q on disk (i16 interleaved), per-channel files, the sidecar
  quality.rs      signal quality: level, DC, I/Q balance, SNR, SINAD, SFDR, ENOB, findings
  bin/b210.rs     binary `b210`: load, state, read, write, monitor, rx-test, loop-test, capture
  bin/b210-plot.rs binary `b210-plot`: a capture's report, spectrum, waterfall, time, histogram, constellation in the terminal, and as PNG images (`--png`)
  bin/b210-radio.rs binary `b210-radio`: the AD9361 from a configuration file (id, apply, peek, reset)
tests/ad9361_golden.rs   the driver against UHD's C++ traces
examples/config.toml     every configuration key
examples/stream.rs       the minimal end-to-end client: bring-up, apply, stream, Check
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
   (2 channels) and 5 s (1 channel at 61.44 MS/s). A 0 dBFS tone exposed a
   bug in the test tone's conjugate channel: -(-2048) is +2048, outside the
   12-bit codes, and the wire wraps it to -2048, so 216,090 values
   mismatched and the capture failed as "stream not clean". value() now
   clamps the conjugate to +2047 (the nearest code); measured after: 0
   dBFS is bit exact (0 bad values) and is then refused for saturation
   with the intended message, while -1 dBFS is unchanged (SNR 73.0 dB,
   ENOB 12.01, 0 bad values). A 3 s radio capture
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
   No clipping (peak -13.1 dBFS), DC -106 dBFS, image rejection 55-62 dB
   (that run had RX IQ tracking off, the plan bug found later: 78-93 dB
   with it on).
   At 2.45 GHz one 0.5 ms broadband burst (Wi-Fi-like) reached -0.8 dBFS
   with no clipping and no overflow; it appeared on channel 0 only and not
   in a 5 s capture, so it is an external emitter, not the data path.
   A band survey with the antenna (all 2-channel captures, LO-shift test
   where a station is named, gain steps 1:1 confirmed on every band):
   - FM band (LO 100.5 MHz, 5 MHz BW): crowded. At 70 dB gain the 12-bit
     rail is exceeded (max |x| = 2048 > 2047, 1.8% of values within 8 LSB of
     the rail) - the band overloads the converter; at 55 dB the peak is
     -3.6 dBFS and at 45 dB -12.8 dBFS, clean. The strongest station is at
     99.4 MHz (carrier -12 dBFS at 70 dB): it moved -0.5 MHz when the LO
     moved +0.5 MHz. The tone-based SNR/SFDR figures are meaningless in a
     crowded band (many stations, so SNR < 0 dB is expected, not a defect).
   - 2.45 GHz ISM: broadband bursts (Wi-Fi/Bluetooth), ch0 rms -43.6 dBFS
     at 60 dB, no clipping, no tone.
   - 1.575 GHz (GPS L1, nominally quiet): input-referred level close to the
     ISM band's, and 17.6 dB of a 20 dB gain cut follows it, so it is ~88%
     external broadband energy, not the converter floor.
   - The receiver's own floor: at 1 x 30.72 MS/s with a 20 MHz analog
     filter, the output of an empty channel is -62 dBFS rms (1.2 codes,
     crest 12 dB) for every gain index from 0 to 40, then follows the
     analog input at about 0.9 dB per step up to 76. Three measurements
     put that floor inside the chip, not at the antenna: it is the same
     at 1.5 GHz and 2.45 GHz (-61.9 vs -61.7 at index 10), it moves 2.8 dB
     when the analog bandwidth goes 2 -> 30 MHz (thermal noise would move
     11.8 dB), and it moves 1.4 dB when the rate goes 30.72 -> 3.84 MS/s.
     It is not the gain table (registers read back 10/20/40/70 at 0x109,
     manual mode 0x0FA = 0xE0, and the table bytes and load sequence equal
     UHD's) and not the rx IQ tracking (0x169 = 0xcf/0x00/0x0f give the
     same floor). Consequence: below ~45 dB the gain index buys headroom,
     not sensitivity, which is why the example asks 60/55 dB. The floor is
     ~10 effective bits through the analog path, against 11.7 through the
     digital one (the BIST tone); a calibrated RF source is needed to say
     whether that is the chip or this board, so it stays an open number,
     not a claim. The data sheet has no ENOB to compare against: ADI
     answers that the AD9361's ADC is sigma-delta and "ENOB will vary
     depending on the configuration of the sigma delta ADC (depending on
     OSR)" (EngineerZone 80646), so the number is a property of this rate
     and filter, measured, not a specification to meet.
   - `b210 capture` refuses a clipped ADC stream: it prints the per-channel
     CLIPPING note (the same text `b210-plot` gives) and exits 1, because a
     saturated capture is not a measurement of the input. Measured: the FM
     config at 70 dB exits 1 (9.7% / 11.4% clipped), at 30 dB exits 0.
     Refusal needs clipping at or above 1e-6 of the I/Q values
     (`quality::CLIP_REFUSE`, about one clipped value per 64 x 16384
     analysis block); below that the note says "isolated" and the capture
     is kept - a soak found one rail code in 1.84 G values, which refused
     the capture and advised a 47 dB gain cut before the rule was split in
     two. The 47 dB came from the crest factor of that one sample, not
     from the signal, so the gain advice is given only in the material
     grade.
   - The refusal is the ADC's alone. A digital source (--source pattern,
     --source tone) spans the code range by construction and is checked
     bit for bit, so its rails are a fact to report, not a saturation: the
     note names the fraction and the longest run and adds the gain advice
     as the rule for an ADC input, and the capture exits 0. Measured: the
     pattern (0.0488% at the rails, run 2) and a 0 dBFS tone (1.92%, run 1)
     both exit 0; before this they exited 1 with "the ADC saturated" - a
     false failure that made two of the four receive states uncapturable.
   - A stream that lost sample times is not analysed: the file is a splice
     of two stretches, so its spectrum is not the spectrum of one record.
     `capture` prints whether the FPGA announced the drop in OVERFLOW
     headers (the host fell behind) or a gap came unannounced (the data
     path lost it), writes the sidecar with the count, and exits 1 before
     the analysis. `b210-plot` prints "SPLICE: its capture lost N sample
     times ..." for such a file, so an archived splice is never read as a
     measurement. Measured: a capture run while the RTL gate compiled lost
     602,888 sample times with OVERFLOW set, then a repeat under no CPU
     load kept 58.27 M with 0 lost.
   - The incremental plan was checked on the chip, not only against the
     mock: apply B --from A and then read every AD9361 register 0x000 ..
     0x2FF, against a fresh apply B read the same way. Registers that
     differ between two identical full applies (temperature, live status
     the driver never writes, per-run calibration results: 15 of them) are
     not evidence; of the rest, the only settings that differed were RX2's
     gain and TIA registers with RX2 disabled, the TX VCO divider with TX
     off, the TX quadrature calibration scratch index (0x0AA), and - the
     one real finding - 0x169: `apply` left RX IQ tracking off (0xC0).
     The chains-on step runs the TX quadrature calibration, which disables
     tracking, and the plan puts chains on after the LOs, where UHD's
     tune() would have re-enabled it. On one station at 30.72 MS/s, 50 dB
     gain: image rejection 49.3 dB with tracking off, 78.9 dB with it on
     (93.2 dB after the fix, same capture settings). The plan now
     re-enables tracking after every chains change with rx on - init leaves
     it off too, so an rx-only config has nothing else to turn it on
     (measured: 78.6 dB after the fix). A driver unit test pins the
     calibration's 0xC0, a device test the plan's 0xCF for a full and for
     an rx-only apply, and the golden traces are unchanged (UHD's own
     set_active_chains also leaves tracking off; only its later tune()
     differs from our order). The same register comparison was run across
     the other transitions (2 x 2 -> 1 x 1 at 61.44 MS/s, and 2 x 2 ->
     rx-only): the remaining differences are the disabled direction's
     gains, TIA and filter values, the TX VCO divider with TX off, the
     calibration scratch 0x0AA, calibration readback (0x0C7 .. 0x0C9,
     0x090 .. 0x09D, 0x0A7/0x0A8), and the LO fractional word by one LSB
     (80 MHz / 2^24 = 4.8 Hz) after a rate change.
   - `b210 capture` analyses its file in bounded memory (`quality::
     analyze_file`: one pass for the sums, one for the DC-removed power and
     peak, one read per spectrum segment), so a long capture no longer costs
     4 bytes per sample time plus the file in RAM. Measured on a 30 s
     2 x 30.72 MS/s sc12 capture (3.7 GB per channel as a Vec<i16>): peak
     RSS 9.9 MB, same 918,449,400 sample times, every header checked. The
     file path and the in-memory path share the moment sums, the level and
     the Welch segment code, and a test requires their reports to be
     identical, not merely close. `b210-plot` reads only the selected
     interval (t0/t1), and `--view report` streams it through
     analyze_file_range: a report on a 233 MB channel peaks at 3.3 MB, and
     its text equals the in-memory report of the same window. The drawing
     views (spectrum, waterfall, time, hist, IQ) hold their interval,
     because they draw its samples.
   - Soak (30.72 MS/s, sc12, both channels): 60 s of the pattern stream is
     1,840,041,456 sample times with 0 lost and every counter 0; 30 s of
     the tx loopback is 921,600,000 samples back at exactly their ticks;
     a 30 s radio capture keeps 918,449,400 sample times per channel with
     0 lost, 0 bad values and 1 value at the code rail in 1.84 G (the
     isolated grade above). The longer run: 300 s of the pattern is
     9,212,807,912 sample times, 0 lost, every counter 0, and 120 s of the
     full-duplex tx loopback is 3,686,400,000 samples back at exactly their
     ticks (OVERFLOW, UNDERFLOW, LATE, SEQ_ERROR, BAD_PACKET and
     rx_cdc_lost all 0, one BURST_ACK). Before and after those ~7 minutes
     the radio floor is unchanged (ch0 -42.9 -> -43.3 dBFS, ch1 -49.7 ->
     -49.8) and RX IQ tracking stays on.
   - The rx gain surface 0 .. 76 stands at every band: ADI's per-band
     "maximum gain" (73 / 71 / 62 dB) is not a clamp on the table index -
     at 2.45 GHz the measured noise floor rose 5.3 dB from index 70 to 76
     (+4.9 from 60 to 65), so the extra rows carry gain. UHD clamps the
     index at 76 only (set_gain), which is what the driver does too.
   - Port asymmetry, resolved: on the FM band both ports receive the same
     99.4 MHz station, ch1 about 8 dB stronger (tone -40.7 vs -49.0 dBFS
     at 30 dB gain, -50.9 vs -59.4 at 20; ch0's falls below the detector
     at 10). The first sweep's ch1 looked gain-independent and clipped at
     14.7% for 45, 55 and 70 dB - that is a station far past full scale at
     all three, not a gain-stage fault; the 0 .. 30 dB sweep is clean and
     follows 1:1. So an earlier reading of "one antenna and the other port
     open" is rejected: both ports are live, they differ by band (ch1 is
     8 dB hotter at 100 MHz, ch0 6.4 dB hotter at 2.45 GHz), which is
     coupling/orientation, not a data-path fault. At 50 dB gain the
     strongest station is 104.1 MHz on ch0 and 99.4 MHz on ch1, each
     moving 1:1 with its LO in the shift test: the two ports carry
     different mixes of real stations.
   The +/-1.31 MHz "pair" first reported as an internal spur was the
   spectrum's own noise maxima: with 64 averaged segments the largest noise
   bin sits 4-5 dB over the median (measured), and the plotter listed the
   six strongest local maxima unconditionally. A peak is now a spur only at
   floor + 10 dB (quality::SPUR_DB, with a gamma-noise test that also pins
   the 6 dB case as noise); the 2.45 GHz captures then report none, while
   the FM stations (about 40 dB over the floor) stay listed.
   The mirror reading had the same shape of flaw one step further: a tone's
   "mirror" was always read from a +-8-bin band at -f, but a tone within 2 x
   8 bins of DC has that band over the DC lobe, so a DC offset was reported
   as a component at the mirror frequency. Reproduced in a test (tone 9.4
   bins from DC, DC offset 300/-200 codes): "MIRROR at -2.260 kHz, -17.5
   dBc" where nothing sits at -f; the power is DC leakage. A mirror is now
   measured only when its main lobe is disjoint from both the tone's and
   DC's, and otherwise the report says so ("mirror not measurable"), with
   no finding. Measured on the board through the loopback tone: 70.8 kHz
   (9.4 bins of 4096 at 30.72 MS/s) reports "not measurable", 1.2342 MHz
   reports "mirror -99.4 dBc". The same split appears on the antenna: with
   the LO at 99.5 MHz and 30 dB gain (2 s, 58.26 M sample times per channel,
   0 lost), channel 1's 99.4 MHz station sits at -100 kHz (13 bins) and the
   report says "mirror not measurable" with no finding, while channel 0's
   strongest component 3.5 MHz out still measures mirror -27.9 dBc and is
   reported MIRROR - the same code, the geometry decides. (At 50 dB the
   whole FM band clipped, peak -0.9/0.0 dBFS, ENOB ~2; the report's SEVERAL
   COMPONENTS finding says those numbers are not the receiver's.)
   The spur's kind is `Mirror` (not `Image`),
   matching the finding's word: an I/Q image and a real signal there are
   indistinguishable in one capture, and the LO-shift test is what decides.
   No internal spur was found when moving through the band: with the LO
   stepped 2.40 .. 2.50 GHz in 10 MHz steps (0.5 s each, 40 dB, 2.45 GHz
   antenna), the floor stays -133.3 .. -134.3 dBFS/Hz (1.0 dB over 100 MHz)
   and the only components above floor + 10 dB appear at 2410 and 2420 MHz,
   each a cluster of lines about 1 MHz wide - modulated traffic, not tones.
   No component recurs at a fixed baseband offset across the steps, which
   is what an LO-independent (clock/DC/image) spur would do; the DC and
   image handling is the mirror paragraph above. The analysis is also checked
   for window artefacts by a test: one tone read at 1024, 2048, 8192 and
   16384 FFT points and three segment offsets gives the same frequency
   (within a bin), level (0.05 dB) and SNR (2 dB). The window and metrics
   follow IEEE 1241-2010 section 8.8.1.2 (and NI's ADC measurement note):
   7-term Blackman-Harris when the tone is not coherently sampled, ENOB =
   (SINAD - 1.76 - tone dBFS) / 6.02, harmonics folded with the same bin
   mapping as the signal. The impulsive threshold (crest > 20 dB) is
   deliberately above the > 15 dB used for acoustic impulsiveness
   (Pekkarinen & Starck), because a modulated RF carrier raises the crest
   without being an impulse. The 2.45 GHz bursts are
   real: in three 10 s captures, ch0 alone shows clusters of 204, 182 and
   57 values >= 1500 codes (ch1, 6.4 dB cooler at this band, none), and a
   5 s capture had exactly one sample time at the rail (frame 26 025 176,
   Q = 2047 among 1413/1399) - a burst edge, not a data-path glitch: no
   lost samples, no bad headers, and the PRBS eye test covers the pins.
   The level also carries the longest clipped run, which separates a burst
   edge from a one-sample excursion: the 10 s window whose only rail value
   is the single sample above reports "(longest run 1 sample time)", while
   a test's five-sample burst reports 5. The run is counted per sample time
   (either I or Q at a rail).
   Such a window is now named for what it is: a 43.4 dB crest factor (noise
   is about 10-12 dB) with no clipping raises "IMPULSIVE: bursts or
   transients dominate the peak, while the rms and the floor describe the
   background between them" instead of leaving "NO TONE" and a near-full-
   scale peak unexplained. A test pins both sides: noise alone has no
   finding, four samples at 2000 codes in noise do.
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
   so that is not an error detector.
   The rx eye, measured by our own scan (`b210-radio scan`: the BIST PRBS
   at every chip clock/data delay, 0.2 s a point): the passing window at
   clock delay 0 is data 4 .. 15 in both modes, so UHD's shipped 0xF sat one
   0.24 ns step from the failing edge. The shipped value is now the window's
   midpoint (ADI AN-1441's practice): 0x006 = 0x9, 1.44 ns to the near edge
   and 1.68 ns to the far one; 1,216,224,240 bits of PRBS at the new point,
   0 mismatches; the BIST tone unchanged (SNR 67.9 dB). The golden test
   records it as the second allowed difference from UHD. The scan's point
   count is a property of its dwell, not a constant: re-run four times at
   0.02 s a point (2.5 M and 1.2 M PRBS bits a point) it gives 146, 148,
   146, 149 of 256 at 2 x 30.72 and 152, 155, 154 at 1 x 61.44; every flip is at
   clock 2/4/9/11/12/14, the window's edges, where a point's error rate is
   around one per point's bit count, so it passes or fails by chance. The
   stable result is the window (clock 0, data 4 .. 15) and 0x09 in it; the
   tool now prints the bits a point, so a count is read with its dwell.
   Mixed channel counts work: 2 rx + 1 tx at 30.72 MS/s applies with the
   port in 2R2T (0x005 = 30720), the 2-channel pattern stream is clean, a
   1-channel tx burst loops back exact (153.6 M samples), and a 2-channel
   radio capture runs with the transmitter on. The single channel of a
   direction is channel 0, so ch1 alone is rejected (a one-channel port
   carries channel 0; before the check it applied and streamed channel 0
   under the name ch1). The eye is measured by the driver's own scan, the
   entry above.
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

## Mutation campaign

`scripts/mutate.sh` (378 mutants: an operator swapped, a bit operation
changed, a shift reversed, a constant flipped, one place at a time; comments
skipped) runs the benches that read the mutated file. Measured on this tree:
**366 of 378 killed (96.8 %)**, 0 build errors. The 12 survivors, each read
and classified:

- 8 in `ad9361_io.v`: the IDELAYE2's control inputs (DATAIN, C, CE, INC, LD,
  LDPIPEEN, CINVCTRL, REGRST) inverted. With `IDELAY_TYPE("FIXED")` and
  `DELAY_SRC("IDATAIN")` the primitive uses none of them, and the bench's
  IDELAYE2 model models only IDATAIN -> DATAOUT, so the change cannot show.
  REGRST is not modelled at all; that is a limit of the model, noted.
- `rx_framer.v` `if (state == START) acc <= 0` inverted: `acc` is assigned
  again later in the same always block whenever `in_body` (state == BODY),
  which overrides it there; in the other states the value is unused.
- `spi_master.v` the bit shifted into the SPI word after the last bit of a
  24-bit frame: it would reach the output 22 shifts later, past the frame.
- `tx_deframer.v` the EOB-only entry's `!s_valid || !s_full` made `&&`:
  when a previous entry is consumed in the same cycle, the entry is emitted
  one cycle later - latency only.
- `command.v` `hw != 0 || w_room` made `hw == 0 || w_room`: after the first
  header word the room was already reserved for the whole result, so the
  change can only delay a header word while the host is not draining, never
  reorder or corrupt it.

## Risks

- Full duplex sc12 is 92 % of the 400 MB/s bus.
- Ring size against host service gaps: rx_hwm / tx_hwm (PROTOCOL.md 6)
  measure the margin.
