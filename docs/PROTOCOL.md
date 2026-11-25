# Protocol v1 (FPGA <-> Rust driver)

The one definition both sides implement. All words are 32-bit
little-endian, as the FX3 moves them on its 32-bit bus (byte 0 = bits 7:0).

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
- After every FPGA load the driver issues vendor request 0x72 (GPIF reset);
  the firmware does not start its bus state machine otherwise.

## 2. Packet header (16 bytes, every packet)

| Word | Bits | Field |
| --- | --- | --- |
| 0 | 15:0 | `length`: meaningful bytes, header included (16 .. 16384) |
| 0 | 19:16 | `type`: 0 rx, 1 tx, 2 command, 3 result, 4 event |
| 0 | 23:20 | `format`: 0 none, 1 sc16, 2 sc12 |
| 0 | 27:24 | `channels`: bit c set = channel c present |
| 0 | 31:28 | `version`: 1 |
| 1 | 15:0 | `sequence`: per type and direction, +1 per packet, mod 2^16 (tx: checked within a burst; a START_OF_BURST packet may start at any value) |
| 1 | 16 | `HAS_TIME`: words 2-3 are valid |
| 1 | 17 | `START_OF_BURST` |
| 1 | 18 | `END_OF_BURST` |
| 1 | 19 | `OVERFLOW`: rx samples were dropped before this packet |
| 1 | 31:20 | zero |
| 2 | 31:0 | `time` bits 31:0 |
| 3 | 31:0 | `time` bits 63:32 |

`time` counts sample periods (ticks) at the configured rate: the tick of
the packet's first sample time. The number of samples lost before a packet
is `time - (previous time + samples in previous packet)`.

## 3. Samples

A sample time carries one complex sample per present channel, in channel
order: I0, Q0, I1, Q1 (channel 0 first). Values are the AD9361's 12-bit
two's-complement codes c in [-2048, 2047].

- **sc16**: each value a 16-bit word `c << 4` (full scale 32768, the low 4
  bits zero). 4 bytes per complex sample.
- **sc12**: values packed as a little-endian bit stream: value number v
  occupies bits [12 v, 12 v + 12) of the payload, low bit first. 3 bytes per
  complex sample; 8 values = 3 words.

Data packets are exactly 16 384 bytes (payload 16 368 = 2^4 x 3 x 11 x 31
bytes), so the payload is a whole number of sample times in every case:

| Format | Channels | Bytes per sample time | Sample times per packet |
| --- | --- | --- | --- |
| sc16 | 1 | 4 | 4092 |
| sc16 | 2 | 8 | 2046 |
| sc12 | 1 | 3 | 5456 |
| sc12 | 2 | 6 | 2728 |

An rx packet holds n sample times: n = `rx_spp` (clamped to 16 .. the full
count above), fewer only in a stream's last packet. A stream ended by
`stop` closes with a 16-byte packet (header only, END_OF_BURST) whose time
is the tick after the stream's last sample. When the FPGA's rx buffer has
no room for a packet, its n samples are dropped and the next packet
carries OVERFLOW; the gap in time is the number lost.

Bus load: rate x bytes per sample time, both directions summed, must stay
below 400 MB/s (32 bits x 100 MHz). Full duplex 2 x 2 x 30.72 MS/s needs
sc12 (369 MB/s; sc16 would be 492 MB/s).

## 4. Commands and results (EP4, EP8)

A command packet is a header (type 2, its own sequence) followed by up to
126 operations of 8 bytes; it fits one 1024-byte control buffer. The FPGA
executes them in order and returns one result packet (type 3, same
sequence) with one 8-byte result per operation.

Operation: word a = `opcode[31:24] arg[23:16] addr[15:0]`, word b = `data`.

| Opcode | Name | Meaning | Result data |
| --- | --- | --- | --- |
| 1 | WRITE | register `addr` := data | 0 |
| 2 | READ | value of register `addr` | the value |
| 3 | SPI | shift `data[23:0]` out to device `arg` (0 AD9361, 1 ADF4001), MSB first | the 8 bits read back (AD9361) |
| 4 | WAIT | wait `data` microseconds | 0 |
| 5 | POLL | repeat the previous READ or SPI until `(result & mask) == value`, mask = data[31:16], value = data[15:0], at most `arg` ms | the last result |
| 6 | AT | hold the following operations until time T (below) | 0 |

Result: word a = `opcode[31:24] status[23:16] addr[15:0]`, word b = data.
Status: 0 ok, 1 timeout (POLL), 2 late (AT: T already passed; the
operations run at once), 3 unknown opcode (and everything after it is
skipped).

AT carries 32 time bits: T is the time whose bits 31:0 equal `data` and
which lies in [now - 2^31, now + 2^31). At 61.44 MS/s that is +-35 s
around the present, so commands up to 35 s ahead are unambiguous.

## 5. Events (EP8)

An event is the increase of one of the FPGA's counters. Every 100 us the
FPGA compares its counters with what it last reported; if any rose, it
sends one event packet (type 4, HAS_TIME, its own sequence) with one event
per counter that rose, in code order (at most 6 events, 112 bytes):

| Bytes | Field |
| --- | --- |
| 0 | code: 1 OVERFLOW (rx sample times dropped), 2 UNDERFLOW (tx gaps in a burst), 3 LATE (tx bursts after their time), 4 SEQ_ERROR (tx sequence jumps), 5 BURST_ACK (tx bursts played to END_OF_BURST), 6 BAD_PACKET (tx packets malformed or cut short) |
| 1 | channels (0: not channel specific) |
| 2-3 | zero |
| 4-7 | count: the increase since the previous report |
| 8-15 | time: the FPGA time when the packet was built (the header's time) |

Events never hold back data and are never lost: while the host does not
read them, the increases add up until a packet can go.

## 6. Registers (16-bit addresses, 32-bit values, all on the bus clock)

The map as built (fpga/rtl/regs.v); an address not listed reads 0 and
ignores writes. Registers for the AD9361, antenna switches and GPIO come
with the radio step.

| Address | Name | Access | Content |
| --- | --- | --- | --- |
| 0x000 | id | r | 0x42323130 ("B210") |
| 0x001 | version | r | protocol version [31:16], build number [15:0] |
| 0x002 | build | r | first 32 bits of the source commit |
| 0x003 | scratch | rw | free, for bus tests |
| 0x004 | status | r | clocks locked [0], sample clock running [1] |
| 0x010 | time_lo | r | time now [31:0]; reading it latches time_hi |
| 0x011 | time_hi | r | time [63:32] as of the last time_lo read |
| 0x012 / 0x013 | time_set_lo / hi | rw | the time to set |
| 0x014 | time_ctrl | w / r | write 1: set the time at the next sample; read [0]: a set is pending |
| 0x020 | rx_ctrl | rw | write: start [0], stop [1] (strobes), at time [3], format [7:4], channels [9:8]; read: the same, [0] = a stream runs |
| 0x021 | rx_count | rw | sample times in the stream, 0 = until stopped |
| 0x022 / 0x023 | rx_at_lo / hi | rw | start time (with at time) |
| 0x024 | rx_spp | rw | sample times per packet (clamped to 16 .. full) |
| 0x080 + k - 1 | events | r | counter of event code k (section 5), k = 1 .. 6 |
| 0x086 | rx_lost | r | sample times lost crossing to the bus clock (nonzero = a design error) |
| 0x087 | cmd_dropped | r | command packets dropped as malformed |
| 0x0F0 | test | rw | rx source: 0 radio, 1 pattern, 2 tx loopback |
| 0x0F1 | test_div | rw | step 1 only: a sample strobe every test_div + 1 cycles of the 61.44 MHz test clock |

The pattern (test = 1) for the sample time t is I0 = t, Q0 = ~t, I1 = 7 t,
Q1 = 13 t + 5, each modulo 2^12, as 12-bit codes. In loopback (test = 2) rx
carries the tx sample played at the same tick, 0 outside bursts.

tx packets describe themselves (format, channels in the header): there is
no tx configuration register. A stream's configuration must not change
while it runs.
