# Protocol v1 (FPGA <-> Rust driver)

The one definition both sides implement, as built in `fpga/rtl/` (the RTL
is the truth; this file states it). All words are 32-bit little-endian, as
the FX3 moves them on its 32-bit bus (byte 0 = bits 7:0).

## 1. Transport (fixed by the stock FX3 firmware)

| Endpoint | FX3 thread | Direction | Carries |
| --- | --- | --- | --- |
| EP2 OUT | 0 | host -> FPGA | tx data packets |
| EP6 IN | 1 | FPGA -> host | rx data packets |
| EP4 OUT | 2 | host -> FPGA | command packets |
| EP8 IN | 3 | FPGA -> host | result and event packets |

Constraints of the firmware's DMA channels (2 buffers per channel: data
16 384 bytes, control 1024 bytes at SuperSpeed):

- A transfer is a multiple of 4 bytes.
- A buffer ends when full or at a short USB packet. A transfer shorter than
  its buffer whose size is a multiple of 1024 bytes ends in no short packet,
  so it would merge with the next. Rule: with B the endpoint's buffer size
  (16 384 data, 1024 control) and L the header's length field (meaningful
  bytes), a packet is transferred as S(L) bytes:

      S(L) = B                          if L = B
      S(L) = 4 * ceil(L / 4) + 4 * k    otherwise, k = 1 if 4 * ceil(L / 4) is a
                                        multiple of 1024, else 0

  The pad is zero and ignored. A full command, result or event packet is
  16 + 126 x 8 = 16 + 63 x 16 = 1024 bytes = B.
- One FX3 buffer is one packet, both directions.
- After every FPGA load the driver issues vendor request 0x72 (GPIF reset);
  the firmware does not start its bus state machine otherwise.

## 2. Packet header (16 bytes, every packet)

| Word | Bits | Field |
| --- | --- | --- |
| 0 | 15:0 | `length`: meaningful bytes, header included (16 .. 16384) |
| 0 | 19:16 | `type`: 0 rx, 1 tx, 2 command, 3 result, 4 event |
| 0 | 23:20 | `format`: 0 none, 1 sc16, 2 sc12 |
| 0 | 25:24 | `channels`: bit c set = channel c present |
| 0 | 27:26 | zero |
| 0 | 31:28 | `version`: 1 |
| 1 | 15:0 | `sequence`: +1 per packet, mod 2^16 (per type, below) |
| 1 | 16 | `HAS_TIME`: words 2-3 are valid |
| 1 | 17 | `START_OF_BURST` |
| 1 | 18 | `END_OF_BURST` |
| 1 | 19 | `OVERFLOW`: rx samples were dropped before this packet (ignored on tx) |
| 1 | 31:20 | zero |
| 2 | 31:0 | `time` bits 31:0 |
| 3 | 31:0 | `time` bits 63:32 |

`time` counts sample periods (ticks) at the configured rate: the tick of
the packet's first sample time. The number of samples lost before an rx
packet is `time - (previous time + samples in previous packet)`.

Sequence numbers, per type:

- rx: 0 at each stream's first packet, +1 per packet sent (a dropped
  packet takes none).
- tx: checked within a burst only (3.3).
- command: chosen by the host. A result carries its command's sequence, so
  result sequences skip where a command was dropped (4).
- event: the FPGA's own count, +1 per event packet.

## 3. Samples

A sample time carries one complex sample per present channel, in channel
order: I0, Q0, I1, Q1 (channel 0 first). Values are the AD9361's 12-bit
two's-complement codes c in [-2048, 2047].

- **sc16**: each value a 16-bit word `c << 4` (full scale 32768, the low 4
  bits zero; on tx they are ignored). 4 bytes per complex sample.
- **sc12**: values packed as a little-endian bit stream: value number v
  occupies bits [12 v, 12 v + 12) of the payload, low bit first. 3 bytes per
  complex sample; 8 values = 3 words.

A full data packet is 16 384 bytes (payload 16 368 = 2^4 x 3 x 11 x 31
bytes), so its payload is a whole number of sample times in every case:

| Format | Channels | Bytes per sample time | Sample times per full packet |
| --- | --- | --- | --- |
| sc16 | 1 | 4 | 4092 |
| sc16 | 2 | 8 | 2046 |
| sc12 | 1 | 3 | 5456 |
| sc12 | 2 | 6 | 2728 |

Bus load: rate x bytes per sample time, both directions summed, must stay
below 400 MB/s (32 bits x 100 MHz). Full duplex 2 x 2 x 30.72 MS/s needs
sc12 (369 MB/s; sc16 would be 492 MB/s).

### 3.1 rx packets

An rx packet holds n sample times, n = `rx_spp` clamped to 16 .. the full
count above, fewer only in a counted stream's last packet; L = 16 + n x
bytes per sample time. Every rx packet has HAS_TIME. The first packet sent
carries START_OF_BURST, the last END_OF_BURST.

When the FPGA's rx ring has no room for a packet (it holds 2^17 - 4096
words or more), its n samples are dropped, counted in event 1, and the
next packet sent carries OVERFLOW; the gap in time is the number lost.

### 3.2 rx stream end

A header-only packet below is 16 bytes, with HAS_TIME and the time just
after the stream's last sample (dropped samples included).

| How the stream ends | What the host receives last |
| --- | --- |
| stop while waiting for the start time (no sample at or after it yet) | nothing: no packet at all |
| stop at the start, before any packet was sent | one header-only packet with START_OF_BURST + END_OF_BURST (+ OVERFLOW if a packet was dropped); its time is undefined (the previous stream's end, 0 after configuration) |
| stop mid-stream | the packet in progress completes, then a header-only END_OF_BURST |
| stop while a packet is being dropped | a header-only END_OF_BURST with OVERFLOW |
| count reached | the last data packet carries END_OF_BURST |
| count used up by a dropped packet | a header-only END_OF_BURST with OVERFLOW (START_OF_BURST too if nothing was sent) |

### 3.3 tx bursts

A tx packet describes itself (format, channels in its header): there is
no tx configuration register. Rules, as built:

- **Malformed** (version, type, format, channels, reserved bits, or L not
  16 + a whole number of sample times, L <= 16384; also a header-only
  START_OF_BURST without END_OF_BURST, L = 16; also samples with neither
  START_OF_BURST nor an open burst to continue): not played, counted once
  in BAD_PACKET; neither the sequence expectation nor the burst state
  moves. (Header-only START_OF_BURST + END_OF_BURST is legal: an empty
  burst. A header-only packet without flags is legal and plays nothing.)
- **Cut short** (the buffer ends before its last sample time): the sample
  times whose words all arrived play, the packet consumes its sequence, it
  carries no END_OF_BURST, and it counts once in BAD_PACKET. If a burst is
  open (the packet opened it or continues it, with END_OF_BURST or not),
  the burst ends after those samples with no BURST_ACK, and the next
  packet's sequence is not compared. Outside a burst nothing else happens.
- **Sequence**: checked only within a burst. START_OF_BURST restarts the
  expectation at its own sequence (any value); each later packet up to the
  END_OF_BURST must be the previous + 1, else SEQ_ERROR rises (the packet
  still plays). Outside a burst nothing is compared.
- **Time**: HAS_TIME is honoured only with START_OF_BURST; on any other
  packet words 2-3 are ignored. A timed START_OF_BURST plays its first
  sample at the tick equal to its time; if that tick has passed, the burst
  is LATE and its samples are discarded up to its END_OF_BURST or the next
  START_OF_BURST (which then starts). Any other packet plays at once.
- **New burst**: any START_OF_BURST arriving during a burst (timed or not)
  starts a new burst. The old burst ends at its previous sample with no
  BURST_ACK (it never sent its END_OF_BURST); the new burst starts with a
  clean record, so an underflow of the old burst does not cost it its
  BURST_ACK. Timed with its time ahead, it waits for its time (DAC 0,
  burst not active meanwhile); with its time passed, it is LATE as above.
  A header-only START_OF_BURST + END_OF_BURST during a burst is an empty
  new burst: the old one ends without BURST_ACK and nothing plays.
- **BURST_ACK** counts a burst that played to its END_OF_BURST without an
  underflow gap (a one-sample burst included). A header-only END_OF_BURST
  (L = 16) ends the burst at the previous sample; outside a burst it
  counts nothing.
- Internally (not on the wire; the packet format is unchanged), the tx
  deframer tells the sample-clock side that a burst ended without its
  END_OF_BURST (cut short, or an empty burst during a burst) by an abort
  entry, {present 0, START_OF_BURST, END_OF_BURST}, which no other case
  produces; it ends the burst at once with DAC 0 and no BURST_ACK.
- **UNDERFLOW**: a tick inside a burst with no sample ready. Counted once
  per gap; during the gap the DAC gets 0 and the burst is not active
  (antenna switches, LED); the rest of the burst plays when samples come,
  shifted by the gap, and gets no BURST_ACK. The host must treat UNDERFLOW
  as a broken burst and start a new one. A burst that never sends its
  END_OF_BURST ends in an UNDERFLOW.
- Outside bursts the DAC gets 0.

## 4. Commands and results (EP4, EP8)

A command packet is a header (type 2, its own sequence; format, channels,
flags and time ignored) followed by up to 126 operations of 8 bytes; it
fits one 1024-byte control buffer. The FPGA executes them in order and
returns one result packet with one 8-byte result per operation: type 3,
format 0, channels 0, the command's length and sequence, no flags, time 0.

A command whose version or type is wrong, or whose length is not 16 + 8 n
with n <= 126, is dropped without a result and counted in `cmd_dropped`
(0x087). A command that ends before its length gets status 3 for each
missing operation (opcode and addr 0 where word a is missing); words after
its length are ignored.

Operation: word a = `opcode[31:24] arg[23:16] addr[15:0]`, word b = `data`.

| Opcode | Name | Meaning | Result data |
| --- | --- | --- | --- |
| 1 | WRITE | register `addr` := data | 0 |
| 2 | READ | value of register `addr` | the value |
| 3 | SPI | one 24-bit frame `data[23:0]`, MSB first, to device `arg`: 0 AD9361, 1 ADF4001 (another `arg`: status 3) | the last 8 bits read (AD9361; 0 for the ADF4001) |
| 4 | WAIT | wait `data` microseconds | 0 |
| 5 | POLL | repeat the last READ or SPI executed until `(value[15:0] & mask) == match`, mask = data[31:16], match = data[15:0], for at most `arg` ms (0: one try) | the last value |
| 6 | AT | reserved, not implemented (answered as an unknown opcode) | |

POLL repeats the last READ or SPI the FPGA executed, in this packet or an
earlier one; after a reset that is a READ of address 0.

Result: word a = `opcode[31:24] status[23:16] addr[15:0]`, word b = data.
Status: 0 ok, 1 timeout (POLL), 2 reserved, not implemented, 3 unknown
opcode (and every later operation of the packet is skipped, answered with
status 3).

## 5. Events (EP8)

An event is the increase of one of the FPGA's counters. When a counter has
risen and at least 100 us (10 000 bus cycles) have passed since the
previous event packet, the FPGA sends one event packet (type 4, format 0,
channels 0, HAS_TIME, its own sequence; time = the FPGA time when it was
built) with one 16-byte event per counter that rose, in code order (at
most 6 events, 112 bytes):

| Bytes | Field |
| --- | --- |
| 0 | code (below) |
| 1 | channels: 0 (no event is channel specific in this build) |
| 2-3 | zero |
| 4-7 | count: the increase since the previous report, mod 2^32 |
| 8-15 | time: the same as the header's |

| Code | Name | Counts |
| --- | --- | --- |
| 1 | OVERFLOW | rx sample times dropped for lack of ring room + `rx_cdc_lost` (0x086) |
| 2 | UNDERFLOW | tx gaps inside a burst |
| 3 | LATE | tx bursts whose START_OF_BURST came after its time |
| 4 | SEQ_ERROR | tx sequence jumps within a burst |
| 5 | BURST_ACK | tx bursts played to END_OF_BURST without a gap |
| 6 | BAD_PACKET | tx packets malformed or cut short |

Events never hold back data and are never lost: while the host does not
read them, the increases add up until a packet can go. The counters run
from configuration (a reset does not clear them) and are readable at
0x080 .. 0x085.

## 6. Registers (16-bit addresses, 32-bit values, all on the bus clock)

The map as built (`fpga/rtl/regs.v`); an address not listed reads 0 and
ignores writes, and writes to read-only registers are ignored. A reset
returns every writable register to the value given.

| Address | Name | Access | Content |
| --- | --- | --- | --- |
| 0x000 | id | r | 0x42323130 ("B210") |
| 0x001 | version | r | protocol version [31:16] (1), build number [15:0] |
| 0x002 | build | r | first 32 bits of the source commit |
| 0x003 | scratch | rw | free, for bus tests |
| 0x004 | status | r | clocks locked [0]; sample clock running [1] (the AD9361's DATA_CLK toggled within the last 10.24 us); input delays calibrated [2] (IDELAYCTRL ready); sample path out of reset [3]: streams and bursts can run (DATA_CLK has run for 10.2 us with RESETB high and the delays calibrated; a stream ended by losing the clock has closed) |
| 0x005 | sample_rate | r | [16:0] sample strobes in the last 1 ms = the sample rate in kS/s (wrong for the 1 ms window in which the time is set) |
| 0x010 | time_lo | r | time now [31:0]; reading it latches time_hi |
| 0x011 | time_hi | r | time [63:32] as of the last time_lo read |
| 0x012 / 0x013 | time_set_lo / hi | rw | the time to set (0) |
| 0x014 | time_ctrl | w / r | write [0] = 1: set the time at the next sample (ignored while a set is pending); read [0]: a set is pending |
| 0x020 | rx_ctrl | rw | write: start [0], stop [1] (strobes), timed [3], format [7:4], channels [9:8] (sc16, channel 0); read: [9:3] as written, [0] = a stream runs. A start with format not 1 or 2, or channels 0, is ignored; a start while a stream runs is ignored |
| 0x021 | rx_count | rw | sample times in the stream, 0 = until stopped (0) |
| 0x022 / 0x023 | rx_at_lo / hi | rw | start time (with timed) (0) |
| 0x024 | rx_spp | rw | [12:0] sample times per packet: a write above 8191 saturates to 8191; the stream clamps it to 16 .. the full count of section 3 (4096) |
| 0x030 | radio | rw | AD9361 RESETB [0]: 0 holds the AD9361 in reset, 1 releases it (0); 2R2T [1]: 0 the FPGA reads and drives one channel (1R1T: a sample time per DATA_CLK period, channel 1 reads 0), 1 two (2R2T: a sample time per two periods, channels alternate); the AD9361's own data port needs no change (its 0x010 stays 0xC8 for both, the frame it toggles marks channel 0), and the bit follows the channels a direction carries: set with the chains, only while no stream or burst runs (0) |
| 0x031 | bands | rw | band-select switches, straight to the pins: rx_bandsel_a [0], rx_bandsel_b [1], rx_bandsel_c [2], tx_bandsel_a [3], tx_bandsel_b [4] (0) |
| 0x080 + k - 1 | events | r | counter of event code k (section 5), k = 1 .. 6 |
| 0x086 | rx_cdc_lost | r | sample times lost crossing to the bus clock (nonzero = a design error); also counted in event 1 OVERFLOW |
| 0x087 | cmd_dropped | r | command packets dropped as malformed |
| 0x088 | rx_used | r | [17:0] words (4 bytes) now in the rx ring, 0 .. 2^17 (512 KiB) |
| 0x089 | rx_hwm | rw | [17:0] most words ever in the rx ring; a write (any value) clears it (0) |
| 0x08A | tx_used | r | [16:0] words now in the tx ring, 0 .. 2^16 (256 KiB) |
| 0x08B | tx_hwm | rw | [16:0] as rx_hwm, for the tx ring (0) |
| 0x0F0 | rx_source | rw | [1:0] 0 radio, 1 pattern, 2 tx loopback (0) |

rx_ctrl's format, channels, spp, timed and start time are latched at the
start: a running stream keeps them to its END_OF_BURST (the stop write
itself rewrites rx_ctrl's configuration bits). rx_count is latched too.

The pattern (rx_source = 1) for the sample time t is I0 = t, Q0 = ~t, I1 = 7 t,
Q1 = 13 t + 5, each modulo 2^12, as 12-bit codes. In loopback (rx_source = 2) rx
carries the tx sample played at the same tick, 0 outside bursts and in gaps.
