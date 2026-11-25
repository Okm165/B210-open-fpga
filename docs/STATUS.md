# Status

What is measured to be true today, on board 31B92DD, for image `29a571d9`
(25 Nov 2026, source `c137792`: the full 2 RX + 2 TX design with the LED
module). Evidence: `build/fpga/usrp_b200.txt` (build record) and
`build/hw-gate-20261125T100342Z/` (acceptance run). How the DSP figures are
obtained: `docs/DSP.md`.

## Chip: clocks, timing, space

| Item | Value |
| --- | --- |
| Bus clock (FX3 bus, USB side) | 103.7 MHz achieved, 100 MHz required |
| Radio clock (DSP, all 94 multipliers timed) | 76.3 MHz achieved, 61.44 MHz required |
| AD9361 capture clock | 534 MHz achieved, 61.44 MHz required |
| Clock-domain crossings (bounds 5 / 6 / 8 / 8 ns) | 1.75 / 3.84 / 3.84 / 3.91 ns |
| Hold violations reported by the engine | none |
| Logic | 73 367 LUTs (35 %), 31 773 flip-flops (7 %), 94 DSP48E1 (11 %), 88 RAMB36 (19 %) |

## Board interfaces

| Interface | Measured |
| --- | --- |
| FX3 bus (100 MHz) | intact for a forwarded-clock lag of 37 to 94 MMCM steps (3.85 to 9.79 ns, 5.9 ns window); the design uses 66, 3.0 ns from either end; the gate checks this image at 66 +- 20 steps |
| AD9361 receive eye at 61.44 MHz | 11 delay steps (2.6 ns) to the nearest data transition at UHD's operating point |
| AD9361 transmit eye | 14 steps (3.4 ns) |
| Control path over USB, no UHD | FPGA registers written and read back, AD9361 product ID 0x0a over the FPGA's SPI master, 64 control transactions |

## Signals (gate step `samples` and `dsp`)

| Mode | SFDR | SINAD | DC |
| --- | --- | --- | --- |
| receive test tone, 2 x 30.72 and 1 x 61.44 MS/s | 73.4 dB | 62.5 dB | -68.7 dBFS |
| receive test tone, decimation 4 | 81.7 dB | 64.8 dB | -68.7 dBFS |
| transmit, interpolation 4 | 82.6 / 85.8 dB | 73.6 / 73.9 dB | -104 / -97 dBFS |
| transmit, 2R2T x 30.72 MS/s, 12-bit wire format | 69.8 / 70.3 dB | 58.6 / 59.0 dB | -68 / -67 dBFS |
| transmit, 1 x 61.44 MS/s, 8-bit wire format | 58.1 dB | 43.9 dB | below -200 dBFS |

- The two receive channels are sample-aligned: the AD9361 pseudo-random
  sequence arrived on both with zero errors and at the same index in 8 of 8
  sessions (2.1 M samples each), and with zero errors at 61.44 MS/s.
- The DSP on the board equals the RTL simulation on every sample at
  decimation 1, 2, 3, 4, 8, 16 and transmit loopback x1, x4.

## Throughput

Streaming is lossless at 2 RX x 30.72, 2 TX x 30.72, 1 RX x 61.44 and 2R2T
x 30.72 MS/s (12-bit; with 16 bits that point is 491 MB/s, above the FX3's
400 MB/s bus) on a quiet host. The FPGA is not the limit: what is lost is
lost on the host side, at the same rate on the vendor image.

Measured at 2 RX x 30.72 MS/s (245 MB/s):

- UHD's receive queue depth decides most of it. With 32 frames (2.1 ms of
  data) 7 of 15 runs lost samples, with 128 (8.5 ms) 1, with 512 (34 ms) 1.
  All commands here use 512 receive and 256 transmit frames of 16 360 bytes
  (UHD's default is 16 x 8 176, 0.5 ms).
- The rare remaining event (about one per 150 s of streaming) costs 22 ms of
  samples: the stock design stops a stream at an overflow and UHD restarts
  it.
- Not the cause: deferred USB completion work (the USB CPU's softirq thread
  ran 1 to 5 ms per 10 s run), memory (no reclaim or compaction stall in any
  run), sample conversion (about 1 s of CPU per 10 s, float or 16-bit), USB
  sharing (the board is alone on its root hub), and where the streaming
  process runs (pinning it to the interrupt's CPU makes it worse).

## Board indicators

`src/top/b200_leds.v`, simulated in eleven situations; on the board not yet
seen by eye. RF port LEDs: green receiving, amber transmitting (both
shimmering at the sample rate), red 0.2 s on lost samples. CLK green with the
AD9361 clock running (blink per PPS), red with FPGA clocks unlocked. USR green
flash per control packet, red for 2 s after any loss. STATUS blue heartbeat.

## Known limitations

- The timing model has no clock-tree skew, and paths between clocks it
  treats as unrelated are not checked for hold; the I/O capture paths where
  hold matters are measured on the board instead (rows above).
- The MMCM is written with `COMPENSATION = INTERNAL` where the source asks
  for `ZHOLD` (the engine writes one bit pattern for both); the measured bus
  window already contains the effect.
- The bitstream has no configuration CRC (Project X-Ray writes none).
- A rate or channel-count change while a stream runs is untested.
- What the transmit pins carry while the FIFO underruns mid-packet is
  unmeasured (the logic substitutes the idle word and reports the underrun).
- The dual-clock FIFO cannot notice a pointer wrap if one side outruns the
  other by 2^SIZE words between edges; its instances run at a clock ratio
  of 3.3, where that cannot happen.
- The stock receive framer stops with an overrun when UHD asks for 4092 or
  more samples per packet; every command here uses 4088 to 4090.

## Facts this design relies on

- UHD writes fixed AD9361 interface delays (`0x006 = 0x0F`, `0x007 = 0x0F`)
  and never tunes them; one step is 0.24 ns on this board. A fixed 20-tap
  input delay (78 ps each) centres the receive capture.
- UHD programs the second receive DDC with I and Q inverted: a common signal
  comes out 180 degrees apart on the two channels.
- The stock bus logic appends one word to a packet whose length is a
  multiple of 1024 bytes; the frame sizes used here avoid that.
- FX3 threads: 0 host->FPGA data (EP2), 1 FPGA->host data (EP6), 2 control
  out (EP4), 3 control in (EP8); the FPGA supplies the bus clock.
- Sample 9 of every capture is not part of the AD9361 pseudo-random pattern
  (its generator starts around the stream start); the checks skip 64.
- UHD skips loading an image whose hash the FX3 remembers;
  `fx3_raw_load.py` reboots the FX3, so the next UHD session loads again.

## Reproducibility

Every tool (Yosys and Project X-Ray in `b210-open-fpga:0.3.0`,
nextpnr-himbaechel, the chip database, UHD 3.15) is built from pinned
sources by `just setup`; the patches are in `container/patches`, each
described at the head of `scripts/toolchain.sh`. The FX3 firmware is Ettus's
stock file, sha256-checked. A rebuild with the same tools is byte-identical.
