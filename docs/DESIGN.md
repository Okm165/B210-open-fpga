# v2: our own stack, end to end

Status: design, from four audits (FPGA, FX3 firmware contract, AD9361
bring-up, host streaming) of the working stage tagged `v1-ettus-uhd`.
Nothing below is built yet.

## Goal

2 RX + 2 TX at 2 x 30.72 MS/s and 1 x 61.44 MS/s, full duplex, lossless;
every setting reachable over USB through one declarative configuration; a
protocol, an FPGA design and a host driver that are all ours. The stock FX3
firmware stays.

## What changes and why

| Today (v1) | Flaw found | v2 |
| --- | --- | --- |
| UHD's CHDR packets, two radio cores, per-radio timekeepers | ~10 300 lines of RTL, two clock domains of logic, channel alignment left to the host | one framer for both channels, one 64-bit sample clock, ~3 300 lines |
| FPGA DDC/DUC (CORDIC, CIC, halfbands, 94 DSP48) | the AD9361 already filters and decimates from 61.44 down to 0.52 MS/s with ~19 Hz rate resolution; the DDC at decimation 1 only rescales (x0.9993) and inverts channel 2 | no FPGA DSP; samples are the AD9361's 12-bit codes, bit exact |
| ~0.9 ms of receive buffering, store-and-forward in three stages | the rare residual loss is a USB service gap longer than the device can hold; a 34 ms host queue does not help | 1.25 MiB receive ring in BRAM (~7 ms at 2 x 30.72 MS/s, 12-bit), 256 KiB transmit ring |
| an overflow stops the stream; UHD restarts it, ~22 ms of samples lost | | the stream never stops: a packet that does not fit is dropped and counted, the next carries an OVERFLOW flag, the timestamp gives the exact gap |
| packets end with PKTEND, one USB transfer per ~16 KB packet (~15 000 completions/s); a pad word on 1024-multiples; packets of >= 4092 samples fail | | fixed 16 384-byte packets = one FX3 buffer, committed when full; 256 KB host transfers (~940 completions/s); short packets only at end of burst, padded off 1024-multiples |
| control: one register write per USB round trip; radio registers clocked by the AD9361 clock (unreachable while it is stopped) | AD9361 setup needs thousands of SPI writes | batched operations per control packet (WRITE, READ, SPI, WAIT, POLL, AT_TIME); every register on the always-running bus clock |
| UHD on the host (C++, 3.15) | | small C streaming engine (real-time thread, zero-copy usbfs buffers, ring per stream) + Python client |

## Architecture

```text
 AD9361 -- b200_io (kept) --+-- rx_framer --> [RX ring 1.25 MiB] --> rx_sender --+
                            +-- tx_player <-- [TX ring 256 KiB] <--- tx_parser <--+-- fx3_master -- FX3 (stock)
                            timekeeper (64-bit sample count, PPS)                   |
 bus clock 100 MHz:  ctrl (batched ops) -> registers, SPI (AD9361, ADF4001), GPIO/ATR, test pattern
                     events (overflow, underflow, late, end of burst) -> control-in endpoint
 kept: b200_clk_gen, b200_io, b200_leds, diag_echo
```

Endpoints (fixed by the firmware): EP2 out / EP6 in samples, EP4 out / EP8
in control and events.

### Packet (16-byte header, little-endian)

| Word | Content |
| --- | --- |
| 0 | length (bytes), type (rx, tx, command, response, event), format (sc12, sc16), channel mask, version |
| 1 | sequence (per stream), flags (time valid, start/end of burst, overflow, underflow, late) |
| 2-3 | 64-bit time of the first sample, in samples |

Payload: samples interleaved per sample time (I0 Q0 I1 Q1); sc12 packs two
complex samples in three words. sc12 is lossless (the converters are 12-bit)
and is the format that fits full duplex: 2 x 2 x 30.72 MS/s x 3 bytes =
369 MB/s of the bus's 400 MB/s.

### Configuration surface (one schema)

`host/schema.py` defines every setting once: name, default, range, meaning.
The same definition produces the client's checks, the CLI (`--set name=value`,
`--config file.toml`), the README table and (v2) the FPGA register header.
A configuration is one dict or TOML file; `apply()` checks it whole and
changes only what differs.

```toml
rate = 30.72e6
otw  = "sc12"
test = "none"          # none, tone, prbs, loopback
[rx]
channels = [0, 1]
freq     = 100e6       # one synthesizer for both channels
gain     = [30, 30]
antenna  = ["RX2", "RX2"]
[tx]
channels = [0, 1]
freq     = 100e6
gain     = [0, 0]
```

Python: `B210(config)`, `apply(config)`, `rx(n)`, `tx(waves, secs)`,
`stream()` (blocks carrying data, time, samples lost).

## Order of work, each step proven on the board before the next

1. Python client and schema on the v1 (UHD) backend: the surface users see,
   fixed before the layers under it change.
2. FPGA: `fx3_master` + packets + rings + control, with a test-pattern
   source in place of the AD9361; host C engine. Proof: lossless pattern
   streams at full rate both ways, sequence and timestamp exact.
3. AD9361 bring-up from our host driver (see the open decision); proof: the
   BIST tone, PRBS bit exact on both channels, digital loopback.
4. Python client on the v2 backend; the gate rewritten for v2.
5. Delete v1 (UHD, Ettus RTL, rx_dump, the UHD patches).

## Open decisions

- AD9361 bring-up: who writes it (pending the AD9361 audit).
- Sample domain: run on the AD9361 data clock directly (removes the divided
  radio clock and its hand-over) or keep today's proven radio clock.
