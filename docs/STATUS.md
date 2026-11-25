# Status

Only what has been measured on the board (serial 31B92DD) or verified in the
sources. Numbers come from the instruments in `scripts/`. The vendor image
(`/usr/share/uhd/images/usrp_b210_fpga.bin`) is the reference device under
test, never something we ship.

## Target

Our own build of the full 2 RX + 2 TX design, accepted against the vendor
image on the same board and host by `scripts/hw_gate.sh`:

- stock UHD initialises both radio cores and streams from our image;
- FX3 bus at 100 MHz, as the vendor design, with a measured timing window;
- AD9361 interface eye at UHD's fixed operating point with real margin;
- stock UHD behaviour of the DSP chain, bit-exact against the RTL on the board;
- streaming without loss at 2 RX x 30.72, 2 TX x 30.72, 1 RX x 61.44 MS/s and
  full-duplex 2R2T x 30.72 MS/s (12-bit wire format; with the 16-bit format
  that point is 491 MB/s and exceeds the 400 MB/s of the FX3's 32-bit bus).

## Measured on our image

Build of 24 Nov (stock DSP chain, receive input delay, registered FIFO
output; before the receive hand-over and the bus I/O registers below).

| Item | Our image | Vendor image |
| --- | --- | --- |
| Routed timing, bus clock (required 100 MHz) | 120.6 MHz | not reported by its tools here |
| Routed timing, radio clock (required 61.44 MHz) | 72.7 MHz | |
| Stock UHD 4.9 init | image loaded, register loopback on both radio cores, codec loopback | same |
| Receive eye margin at UHD's operating point (AD9361 delay steps of 0.24 ns) | 12 | 2 to 3 |
| Transmit eye margin | 14 | 14 |
| Receive test tone, 2 x 30.72 and 1 x 61.44 MS/s | -3.7 dBFS, SFDR 73.4 dB, SINAD 62.5 dB | identical |
| Receive test tone through the x4 decimation | SFDR 81.7 / 81.2 dB | 81.4 / 81.2 dB |
| Transmit tone through the AD9361 loopback, x4 | SFDR 83.8 / 82.4 dB, SINAD 73.6 / 73.0 dB | 84.4 / 81.0 dB, SINAD 62.8 / 62.6 dB |
| Transmit tone, 2R2T x 30.72 MS/s, 12-bit wire format | SFDR 70.1 / 70.5 dB, SINAD 58.9 / 58.6 dB | 71.4 / 71.4 dB, SINAD 56.5 / 53.4 dB |
| 2 RX x 30.72 MS/s for 10 s, quiet host | 614.4 M samples, none lost | same |

The transmit SINAD is better than the vendor's because the last transmit
stage rounds to the 12-bit DAC word where the original truncates (a DC term
of -67 dBFS in the vendor image).

Not yet measured on a quiet host: the other three throughput points. The
host is shared; while other jobs load it, the vendor image itself loses
samples and the gate reports "inconclusive".

## What the reference image gets wrong

Found with the bit-exact instruments while validating them on the vendor
image; each is something our design has to get right, and is checked by the
gate.

| Finding | Evidence | In our design |
| --- | --- | --- |
| The two receive channels come up skewed by one sample against each other in some sessions | pseudo-random sequence: channel alignment 0 or -1 from session to session (2 of 7); test tone: channel phase 180.0 or -168.75 degrees (3 of 5); one sample is 11.25 degrees there | a pair register in `b200_io.v` makes the pairing independent of the phase the clock divider comes up in; `tests/tb_io_handover.v` |
| Isolated bit errors in received samples: bit 6 of the Q word reads 0 for one word, about 1 in 500 000 words | `scripts/dsp_exact.py` on six receive rates and two loopback captures: 49 altered words, all with this fingerprint, arithmetic exact everywhere else | to be shown absent: the bit-exact checks of the gate require zero |
| The 2R2T receive data crosses from the capture clock to the divided radio clock on an edge no tool constrains | the vendor constraints declare the two clocks exclusive | samples are handed over on the opposite clock edge; the build bounds the path |

Otherwise the vendor image computes exactly what our RTL computes: every
sample of the pseudo-random sequence through decimation 1, 2, 3, 4, 8 and 16
and of known transmit data through the loopback at x1 and x4 is bit-identical
to the RTL simulation, apart from the bit errors above and the DAC rounding.

## FX3 bus timing

The FX3 times every bus signal against the clock the FPGA forwards (IFCLK).
The Ettus and vendor designs forward it at 0 degrees, with the boundary
registers in the I/O blocks and no I/O timing constraints.

- The open place-and-route engine never puts an ordinary flip-flop in an I/O
  block. `gpif2_slave_fifo32.v` therefore instantiates the boundary
  registers as I/O-block registers (34 input, 38 output, 32 tristate); the
  rewritten module is cycle-for-cycle identical to the original at every pad
  and every FIFO interface over 2 x 2 000 000 randomized bus cycles
  (`tests/tb_gpif_iob_equiv.v`). The pad timing is now the same in every
  build.
- IFCLK has its own MMCM output (`IFCLK_STEPS` in `b200_clk_gen.v`, 104 ps
  per step). `scripts/bus_window.py` patches that lag into a routed
  bitstream and runs a bit-exact loopback of both bus directions
  (`src/top/diag_echo.v`, `fx3_raw_load.py --echo`: 8 MB of random packets
  on the data endpoints, 512 packets on the control endpoints).
- Measured window with the I/O-block registers: the bus is intact for a lag
  of 37 to 94 steps (3.85 to 9.79 ns), 5.9 ns wide, and fails outside, first
  on GPIF_D[6]. At 0 steps, the setting of the reference designs, nothing
  comes back. The design uses 66 steps: IFCLK leaves 3.1 ns before the bus
  clock edge, 3.0 ns from either end of the window.
- For comparison, the same loopback with fabric flip-flops (one routing
  run): intact from about 3.5 to 10.9 ns, the 0 degree point 0.94 ns from
  the end of the window.
- The vendor image's bit errors (previous section) are on bit 6 of the bus
  word, the line that fails first at the late end of our window: it runs at
  the edge our measurement moves away from.

The gate repeats the proof on the image under test: copies with IFCLK 2.1 ns
earlier and later must still pass the control, receive and transmit checks.

## Defects found in the open toolchain and how each is fixed here

All were found by comparing against the vendor bitstream or by an atomic
design on the board, and proven before being fixed at the source.

| # | Where | Effect | Fix in this repository |
| --- | --- | --- | --- |
| 1 | nextpnr FASM writer | every routed tristate in an HP bank inverted (`OLOGIC ZINV_T1` never written for `RIOI` tiles) | `container/patches/nextpnr-rioi-zinv-t1.patch` |
| 2 | prjxray `fasm2frames` | every ODDR in an HP bank bypassed (`OBUF_HP_BANK_GLUE` forces the OLOGIC bypass); the FX3 never got a clock | disabled in `scripts/assemble.sh`; fixed upstream in openXC7/prjxray `658b304`, which `container/prjxray.Dockerfile` pins |
| 3 | nextpnr metadata | no placeable BUFR on Kintex-7 (site type missing) | copied from the Artix-7 metadata in `scripts/toolchain.sh` |
| 4 | prjxray-db kintex7 | BUFR unroutable in HP banks: the 24 always-on pseudo pips of the `HCLK_IOI` BUFR datapath are missing | `container/patches/prjxray-db-kintex7-hclk-ioi-bufr-ppips.patch` |
| 5 | nextpnr FASM writer | a BUFR output routed to a BUFG carries no clock (`CLK_HROW_CK_BUFRCLK_*_ACTIVE` and `HCLK_CMT_CK_BUFRCLK*_USED` never written); the radio clock stops in 2R2T mode | `container/patches/nextpnr-bufrclk-enable.patch` |
| 6 | yosys 0.69 DSP packing (YosysHQ/yosys#6311, open) | a product or sum register with reset or enable that is wider than its value loses its sign bits: negative values come out as large positive ones on hardware while RTL simulation is correct | registers sized to their values in `src/rtl/dsp/hbdec47.v`; `tests/check_dsp_packing.py` and the post-synthesis benches in `make test` detect it |

Checked and found correct on the board: a DSP48E1 with one input register
stage (`AREG = BREG = 1`), for which nextpnr writes none of the three
database settings; a signed 18 x 18 multiply compared over all 36 product
bits matches a plain-logic multiplier cycle for cycle.

## Mistakes of ours that were corrected

- A fabric divide-by-2 flop on the raw pad clock replaced the vendor's BUFR.
  Yosys then inserted a global buffer on that net and the capture clock went
  through two cascaded BUFGs, arriving 1.8 ns late: the whole "CODEC loopback
  test failed" problem. The vendor structure is restored and the two
  radio-clock BUFGs are pinned to adjacent sites in `b210.xdc`.
- The build never defined `TARGET_B210`, so every image had one radio. The
  conditionals are gone; the design is always the two-radio B210.
- The receive DSP chain of earlier rounds had no decimation, tuned in the
  wrong direction and, on hardware, turned every negative mixer product
  into a positive one (defect 6). The chains are the stock Ettus ones again,
  bit- and cycle-identical to the original RTL in simulation, before and
  after synthesis.
- The receive framer had been given a packet-length clamp and a "drain" mode
  on the strength of a testbench whose host model did not behave like UHD.
  With stock UHD the control state machine stops the stream on overflow and
  UHD restarts it. The framer is the stock one again.
- The FX3 data FIFOs were half the depth of the vendor design's (2^13 words
  against 2^14). Restored.
- The raw control instrument wrote the sequence number into the length field
  of its packets; half of its reads timed out and that was read as a property
  of the FPGA.
- The input delay calibration (IDELAYCTRL) was released from reset at the
  instant its reference clock locked and its ready flag was ignored. It is
  now reset after the reference is stable, and the radio stays in reset
  until it reports ready.
- A first version of the bus loopback test called the bus broken because
  packets of a multiple of 1024 bytes came back one word longer. That word
  is the stock bus logic's own padding, which keeps such a packet from
  getting stuck in the FX3.
- The acceptance checks themselves: the tone analysis looked at half of each
  capture, its rail test could not see -32768, nothing compared the two
  channels, the eye scan ran at 50 MHz, and several simulation benches could
  print PASS without having checked anything. All found by an independent
  review and fixed.

## Facts worth keeping

- AD9361 on this board: CMOS, dual port, full duplex, DDR. UHD writes fixed
  interface delays (`0x006 = 0x0F`, `0x007 = 0x0F`: data delayed 15 steps,
  clocks undelayed) and never tunes them. One step measures 0.24 ns here
  (0.3 ns typical in the register map).
- HP bank 34 has no ZHOLD input delay, so a BUFG-clocked IDDR is
  uncompensated. The data transition band is 10 steps (2.4 ns) wide and the
  clean eye 24 steps at 61.44 MHz, which matches the data sheet arithmetic
  (8.14 ns half period, 45 to 55 % duty cycle, 1.5 ns clock-to-data spread).
  A fixed `IDELAYE2` of 20 taps (78 ps each, calibrated against 200 MHz)
  puts UHD's operating point 12 steps from the band on either side.
- UHD programs the second radio's DDC with I and Q inverted (`IbQb`), so the
  two channels of a common test signal are 180 degrees apart by design.
- The stock bus logic appends one word to any packet whose length is a
  multiple of 1024 bytes; UHD's default frame size (8176 bytes) avoids it.
- FX3 threads: 0 = host->FPGA data (EP2 OUT), 1 = FPGA->host data (EP6 IN),
  2 = control out (EP4 OUT), 3 = control in (EP8 IN). The FPGA supplies PCLK.
- A capture's sample at index 9 is not part of the AD9361's pseudo-random
  pattern on this board: measured with nothing skipped, three sessions on our
  image and two on the vendor image all show exactly one sequence error there
  and none anywhere else in 2.1 M samples. It is the test setup's own
  transient (the pattern generator is enabled around the stream start), not
  the FPGA; the sample checks therefore skip 64 samples, not 4096, and check
  the rest of the capture.
- The delay calibration cannot end up away from the delay taps: the
  place-and-route engine puts one `IDELAYCTRL` in every I/O bank that holds
  a delay element and ANDs their ready outputs (`pack_idelayctrl` in the
  engine's `pack.cc`), which is what `IODELAY_GROUP` asks of the vendor tool.
  The calibration is continuous (UG471), so the 78 ps tap does not drift
  with temperature; the operating point itself is fixed.
- UHD skips loading when the image hash matches the one the FX3 remembers.
  `fx3_raw_load.py` reboots the FX3 and stores no hash, so the next UHD
  session loads the image itself.
- The vendor's Vivado project targets `xc7k325tffg676-2`. The open timing
  model reports the same numbers for every speed grade and does not model
  clock skew between related clocks; the crossings it cannot constrain are
  bounded by `set_max_delay` lines in `b210.xdc` that `scripts/build.sh`
  enforces on the routed result.

## Known limitations

- A sample-rate or channel-count change while a stream is running is
  untested.  UHD allows it and reprograms the AD9361, which stops and
  restarts the data clock; the design has no reset for that event.  It is
  outside what the gate covers (every mode sets the rate before streaming),
  and the pseudo-random check cannot judge it directly, because changing the
  decimation changes how fast the pattern advances per delivered sample.
- What the transmitter's pins do when the FIFO runs dry in the middle of a
  packet is unmeasured: the logic substitutes the idle word and raises an
  underrun (counted by the throughput step), but no measurement here
  captures the pins at that moment.
- The dual-clock FIFO (`src/rtl/fifo/axi_fifo_2clk_sim.v`) has FIFOSIZE-bit
  pointers, so it cannot notice a full pointer wrap when one side outruns the
  other by 2^SIZE or more words between clock edges: such an instance stalls
  permanently.  The instances in the radio run at a clock ratio of 3.3, so it
  cannot trigger there.  (Its flags now compare Gray codes rather than
  converted binary pointers, which took the longest bus-domain path from
  10.8 ns to a comparator; the capacity is unchanged: 2^SIZE words in the
  memory plus two in the output register stage, measured by
  `tests/tb_axi_fifo_2clk_cdc.v`.)
- The stock receive framer stops with an overrun error when UHD is allowed
  to ask for 4092 samples per packet (12-bit wire format with a receive
  frame of 8200 bytes or more, or `spp=4092`): the whole-packet FIFO then
  holds the packet with no room for the next.  This is the stock Ettus
  behaviour; the default UHD configuration never reaches it.  Measured with
  a testbench acting as UHD (`tests/tb_e2e_rx.v`); the cleanest fix would be
  UHD-side, not in the FPGA.
- Streaming at 245 MB/s is limited by the host, not the FPGA: UHD's default
  USB buffer pool keeps only 0.5 ms in flight (16 x 8176 bytes), and the
  whole chain about 1.3 ms, so any longer host stall loses samples - on the
  vendor image as well.  `scripts/hw_gate.sh` therefore runs every
  throughput measurement, the vendor control runs included, with
  `num_recv_frames=512,recv_frame_size=16360,num_send_frames=256
  ,send_frame_size=16360` (12-bit mode: 12264-byte frames, whose 4088
  samples per packet stay below the framer's clean limit), which queues
  8.4 MB of receive and 4.2 MB of transmit data - 34 ms and 17 ms at
  245 MB/s - inside the 16 MB usbfs limit and without root.

## Reproducibility gaps

- `container/base.Dockerfile` installs a Java runtime and pypy3 that no tool
  in the flow uses (they were for a place-and-route engine built in the
  container, which is now built on the host by `scripts/toolchain.sh`).
  Removing them means rebuilding the base image, which would change the
  recorded environment, so it is left for a deliberate rebuild.  The images
  in use were built from the current pinned definitions.
- `scripts/toolchain.sh` rebuilds the place-and-route engine, the device
  database and the measuring UHD from pinned sources; the engine and
  database hashes repeat and a design rebuilt with them is byte-identical.
  The container (`b210-open-fpga:0.2.0`) is built from pinned sources and
  produces byte-identical bitstreams.
