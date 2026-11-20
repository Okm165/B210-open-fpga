# Research notes: B210 hardware and control protocol, source-verified

Compiled 2026-11-20 from upstream sources and vendor/community documents to
ground this project's debugging. Every claim carries its source; anything
not verifiable is marked UNVERIFIED. These are the facts the investigation
leans on — not opinions.

---

## A. Clocking and the FX3 interface

**A1. The 40 MHz reference is a free-running VCTCXO on the genuine B210.**
Part 525L20DA40M0000 ("X100") drives a FIN1001 buffer (U105) whose outputs
are `codec_main_clk_p/n` to the FPGA and `xo_to_pll` to the ADF4001.
Schematic clock page, with the note "PLL bringup: 1. VCTCXO starts up
2. FX3 brings up transceiver ... 3. FX3 programs FPGA 4. FPGA writes to PLL".
Sources: https://files.ettus.com/schematics/b200/b210.pdf ;
https://dtsheet.com/doc/2311279/download-b200_sch.pdf

**A2. Upstream marks the input as always-on.**
`input codec_main_clk_p, ... //always on 40MHz clock`
Source: https://github.com/EttusResearch/uhd/blob/master/fpga/usrp3/top/b200/b200.v

**A3. IFCLK (FX3 PCLK) is an FPGA output.**
`output IFCLK, // pclk` driven by
`S6CLK2PIN S6CLK2PIN_gpif (.I(gpif_clk), .O(IFCLK));` from the MMCM's
100 MHz output. The schematic notes the pin "can be configured to supply or
accept a clock". Sources: same b200.v; B200 fx3.sch.
Firmware sets its PIB clock from `CY_U3P_SYS_CLK`
(`b200_gpif_init()`, https://github.com/EttusResearch/uhd/blob/master/firmware/fx3/b200/firmware/b200_main.c)
— how that squares with FPGA-driven IFCLK is **UNVERIFIED**; the GPIF
handshake is what actually matters.

**A4. Measured on OUR board (2026-11-20): the clock chain is ALIVE.**
LED diagnostic v2 (raw 40 MHz -> blink LED on a known-wired pin): green and
blue LEDs blink => 40 MHz present at the FPGA pins; RX1 LED steady =>
MMCM locks. The clock-absent hypothesis is **refuted** by measurement.

## B. FX3 states and load protocol

**B1. `GET_STATUS` (0x83) returns the firmware's global state byte; states:
0 UNDEFINED, 1 FPGA_READY, 2 CONFIGURING_FPGA, 3 BUSY, 4 RUNNING,
5 UNCONFIGURED, 6 ERROR.** State 5 is entered when the bitstream never
starts, INIT_B never rises, or after re-enumeration. Source:
https://github.com/EttusResearch/uhd/blob/master/firmware/fx3/b200/firmware/b200_main.c ;
https://github.com/EttusResearch/uhd/blob/master/firmware/fx3/b200/firmware/b200_const.h

**B2. RUNNING is UHD's success condition** —
`} while (fx3_state != FX3_STATE_RUNNING);` then `usrp_set_fpga_hash(hash);`
Source: https://github.com/EttusResearch/uhd/blob/master/host/lib/usrp/b200/b200_iface.cpp

**B3. Load sequence:** 0x55 FPGA_CONFIG -> wait READY(1); LOOP read;
0x02 FPGA_START -> wait CONFIGURING(2); 0x12 FPGA_DATA 512-byte chunks;
poll -> RUNNING(4); 0x1C SET_FPGA_HASH. (Same file as B2.)
Measured caveat: the firmware's GET_FPGA_HASH (0x1D) does not simply return
the host-written value (ours reads back a value matching neither the boost
hash we wrote nor CRC32/Adler of the file) — the firmware maintains its own
accounting. UNVERIFIED which algorithm; it does not affect operation.

**B4. The stock b210 FPGA image is a Spartan-6 bitstream.** UHD always
offers it; on a Kintex it never asserts DONE and the FX3 lands in state 5.
Community confirmation for clones:
https://wucke13.de/posts/blacksdr-b210mini-sdr/

## C. Control packet path (host -> FPGA)

**C1. Transport:** USB bulk endpoints via `usb_zero_copy`:
`B200_USB_CTRL_RECV_INTERFACE/ENDPOINT` (b200_impl.hpp:72-78);
`_ctrl_transport` passed to `b200_radio_ctrl_core::make(..., SID 0x40)`
(b200_impl.cpp, ctor). On the FX3 these map to
`CTRL_COMM_PPORT_SOCKET` / `CTRL_RESP_PPORT_SOCKET` DMA channels; on the
FPGA `gpif2_slave_fifo32` threads `ADDR_CTRL_TX=2'b10`,
`ADDR_CTRL_RX=2'b11` feed `radio_ctrl_proc` ->
settings bus. Sources:
https://github.com/EttusResearch/uhd/blob/master/host/lib/usrp/b200/b200_impl.hpp ;
.../host/lib/usrp/b200/b200_impl.cpp ;
.../fpga/usrp3/lib/gpif2/gpif2_slave_fifo32.v ;
.../fpga/usrp3/lib/control_200/radio_ctrl_proc.v

**C2. Packet:** CHDR context, 2 payload words (addr, data), packet_count =
sequence, SID; response must be a header + 2 payload words, SID flipped,
matching packet_count (`wait_for_ack` asserts all of that). Source:
.../host/lib/usrp/b200/b200_radio_ctrl_core.cpp ; FPGA response built in
radio_ctrl_proc.v (`16'd24` length word).

**C3. Failure signature:** a dead settings bus produces
`AssertionError: accum_timeout < _timeout` thrown at
`b200_radio_ctrl_core.cpp:227` (`UHD_ASSERT_THROW(accum_timeout < _timeout)`,
5 ms poll loop, `_timeout` = 2 s default) — exactly what our probes show.
Community instance: https://forums.ni.com/t5/USRP-Software-Radio/Trying-to-get-B200mini-i-working-on-Ubuntu-20-04/td-p/4356099

**C4. First FPGA transaction on open is `peek64(0)`** in
`check_fpga_compat()` — a readback of the compat/signature register
(expected signature 0xACE0BA5E); it happens before radio setup and before
codec init. Nothing else is attempted until it succeeds. Source:
b200_impl.cpp (`check_fpga_compat`), b200_radio_ctrl_core.cpp (`peek32`,
`SR_READBACK = 32`).

**C5. CHDR length enforcement:** `gpif2_error_checker` parses
`hdr_bytes = i_tdata[15:0] + 3`, `hdr_lines32 = hdr_bytes[15:2]`, drops
packets with an absurd length (0 or > FIFO size) or with TLAST not on the
predicted EOF line, then resynchronises on the next header. Source:
.../fpga/usrp3/lib/gpif2/gpif2_error_checker.v
(`STATE_WAIT` = "drop until idle").

## D. Known failure modes on custom / clone B210 boards

**D1. First failure is the bitstream family** (stock Spartan-6 image on a
7-series board) — cite A4/B4 above and
https://wucke13.de/posts/blacksdr-b210mini-sdr/

**D2. On Kintex ports, the GPIF interface timing is the weak point:**
"Not constrained: each build works or fails at random depending on
placement; data sampled mid-transition."
https://github.com/kingjamez/B210_XC7K325T_Improvements
Our own XDC documents the same exposure: nextpnr-himbibaer cannot express
set_input_delay/set_output_delay, and the hand budget gives the FX3->FPGA
flag inputs (GPIF_CTL) only **0-1 ns** margin (src/constraints/b210.xdc,
F24).

**D3. Reference-clock problems on clones are documented** ("a defective
VCTCXO ... changing this to a proper VCTCXO, it locked"):
https://www.satellitescommunity.de/forum/index.php?thread/3516-testing-my-new-libresdr-b220-ettus-usrp-b210-clone/
Our board: clock confirmed alive by measurement (A4).

## E. Rates and bandwidth (Ettus sources)

**E1. AD9361 CMOS mode: one 12-bit DDR bus, 61.44 MSPS total; MIMO halves
per-channel rate.** "the master_clock_rate is used to transfer data across
two 12bit buses using DDR clocking ... capped at 61.44MHz ... When you are
operating in a MIMO mode the 2 channels are interleaved over the same bus,
hence the maximum sample rate is halved."
https://usrp-users.ettus.narkive.com/0z6WvMw3/master-clock-rate-max-using-b210-2-channels
Product page: "up to 56 MHz instantaneous bandwidth (61.44 MS/s quadrature),
full duplex MIMO":
https://kb.ettus.com/B200/B210/B200mini/B205mini/B206mini

**E2. Host bandwidth:** USB 3.0 on B2x0 ~350-400 MB/s practical; sc16 at
61.44 MSPS = 245.76 MB/s. Ettus workshop slides ("~350 MB/sec practical")
https://kb.ettus.com/images/4/47/Workshop_GnuRadio_Slides_20190507.pdf ;
our own measured envelope in build/hw-probe/throughput_envelope.png.

---

## F. What these notes changed in our debugging

1. The 40 MHz / MMCM-lock hypothesis is **dead** (measured, A4).
2. The remaining suspects, in order: (i) `GPIF_CTL9` holding the real
   design's MMCM in reset (diag v3 tests this), (ii) GPIF source-synchronous
   input timing (the documented 0-1 ns flag margin, D2), (iii) a control
   path logic defect in our port — but (iii) is the least likely now that
   `tb_ctrl_fifo` proves that logic correct when clocked and reset.
3. If (i) or (ii) is confirmed, the fix is root-cause: qualify or invert the
   reset convention, or re-phase the GPIF capture (negedge/IDELAY), then
   rebuild and re-test with the board as oracle.
