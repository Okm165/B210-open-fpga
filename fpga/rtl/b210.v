// SPDX-License-Identifier: GPL-3.0-or-later
//
// b210 - the FPGA top, step 2: the USB path end to end and the AD9361's
// sample port; the AD9361's DATA_CLK is the sample clock.
//
//   host <-USB-> FX3 <-GPIF-> fx3_pads, fx3_master
//     thread 0 tx      -> tx ring  -> tx_deframer -> cdc_fifo -> sample_domain -> ad9361_io -> P1
//     thread 1 rx      <- rx ring  <- rx_framer   <- cdc_fifo <- sample_domain <- ad9361_io <- P0
//     thread 2 command -> cmd fifo -> command -> regs, spi_master (AD9361, ADF4001)
//     thread 3 result  <- packet_mux <- result fifo (command), event fifo (events)
//
// Wires between blocks are named <path>_<port>: txr_ tx ring read side,
// txd_ tx deframer to its crossing, txs_ / rxs_ the crossings' sample-clock
// sides, rxb_ the rx crossing's bus side, rxr_ rx framer to ring, cmd_ the
// command fifo's read side, res_w_ / res_r_ the result fifo's write / read
// side, ev_w_ / ev_r_ the event fifo's.
//
// Clocks. From the 40 MHz reference (codec_main_clk, running from power-up)
// through one MMCM, VCO 40 * 30 = 1200 MHz:
//   ref200   1200 / 6    = 200 MHz   the IDELAYCTRL's reference (ad9361_io)
//   bus_clk  1200 / 12   = 100 MHz   everything but the sample side
//   ifclk    1200 / 12   = 100 MHz   forwarded to the FX3 as IFCLK, lagging
//            bus_clk by IFCLK_STEPS * 45 / 12 degrees (66 steps: inside the
//            window 37 .. 94 steps = 3.85 .. 9.79 ns in which the bus moved
//            data intact on this board, 3.0 ns from either end; v1
//            measurement, docs/STATUS.md at tag v1-ettus-uhd)
// and the sample clock dclk: the AD9361's DATA_CLK through one BUFG
// (ad9361_io), sample rate x channels, at most 61.44 MHz, with ad9361_io's
// sample strobe (every cycle in 1R1T, every other in 2R2T). DATA_CLK runs
// only while the AD9361 is out of reset and its clocks are set up: the
// sample side must expect no clock at all, and a clock that stops and
// starts again.
//
// Resets, in order:
//   1 GPIF_CTL9 (the FX3's global reset) resets the MMCM. While it is
//     unlocked every reset below is held, asynchronously.
//   2 rst (bus side): released two bus cycles after the MMCM locks.
//   3 ref_rst (IDELAYCTRL): high while unlocked and for 32 bus cycles
//     (320 ns) after rst falls: UG471 ("IDELAYCTRL", RST) asks for a reset
//     once REFCLK is stable, of at least T_IDELAYCTRL_RPW = 52 ns (DS182,
//     "Input/Output Delay Switching Characteristics"). delay_ready follows.
//   4 x_rst (the sample path, a bus-clock register): high while rst, while
//     the radio register holds the AD9361 in reset (RESETB low), while the
//     delays are not calibrated (delay_ready low, as v1 held its radio), and
//     while the sample clock is not running (status bit 1); released when
//     all four have been fine for 1023 bus cycles (10.2 us, >= 600 cycles
//     of a 61.44 MHz DATA_CLK). It resets the bus-side halves of both clock
//     crossings (cdc_fifo) and asserts srst asynchronously.
//   5 srst (sample side): set by x_rst at once, whether dclk runs or not;
//     released by two dclk flip-flops, 2 - 3 dclk cycles after x_rst falls.
//     While srst is high the strobe is held off, so the sample side neither
//     counts time nor writes or takes crossing entries.
// Both halves of each cdc_fifo are thus reset together and stay in reset
// for >= 1023 bus and >= 600 dclk cycles with the clock running: each
// side's copy of the other's pointer is 0 before either side leaves reset
// (cdc_fifo crosses a pointer in 2 cycles of the receiving clock). A
// pointer frozen by a stopped clock never reaches the bus side as data:
// while x_rst is high the rx framer sees no entries and the tx deframer
// sees a full crossing. Releasing the bus side 2 - 3 dclk cycles before
// the sample side is safe: the sample side neither writes nor takes until
// srst falls, and the bus side's tx entries wait in the crossing.
//
// The sample clock lost (status bit 1 falls 10.24 us after DATA_CLK
// stops), RESETB written 0, or a bus reset ends a running rx stream: while
// x_rst is high rx_framer is held stopped and fed zero sample times, so the
// packet in progress is completed with zeros and the stream closes with
// its END_OF_BURST packet (as for a stop write, PROTOCOL.md 3.2); x_rst
// stays high until the framer is idle (that needs ring room, i.e. a host
// that reads). A start while x_rst is high ends at once: an untimed one in
// a header-only START + END_OF_BURST packet, a timed one with no packet
// (rx_framer's rules for a stop before the first sample). The next stream starts clean on the restarted
// clock, with the time back at 0 (srst). A tx burst's entries in the
// crossing are lost; the rest of it waits in the tx ring for the clock.
//
// The AD9361 stays in reset (RESETB low) until the radio register (0x030)
// releases it; its SPI and the ADF4001's are spi_master's, deselected between
// frames; its control inputs are held at Ettus's constants; the band-select
// switches follow register 0x031. Pins this step does not drive per state
// are held where the radio is off and silent: both PA enables low, the RF
// switches in UHD's off state (below; per-state switching from tx_active
// is a later step), the reference on the internal oscillator.
//
// LEDs (every pin lights its LED when high):
//   STATUS  blue    heartbeat of the bus clock (0.67 s)
//   CLK     green   sample clock running      red  clocks not locked
//   USR     green   a flash per command packet  red  a sample lost, a tx
//                   underflow, late burst, sequence jump or bad packet in
//                   the last 2.68 s (2^28 bus cycles)
//   RX2 1   green   an rx stream runs
//   TX/RX 1 amber   a tx burst plays (green + red)
`default_nettype none

module b210 #(
  parameter integer IFCLK_STEPS  = 66,
  parameter [15:0]  BUILD_NUMBER = 0,
  parameter [31:0]  BUILD_COMMIT = 0
) (
  input  wire        codec_main_clk_p, codec_main_clk_n,
  // FX3
  output wire        IFCLK,
  inout  wire [31:0] GPIF_D,
  output wire        GPIF_CTL0, GPIF_CTL1, GPIF_CTL2, GPIF_CTL3, GPIF_CTL7,   // SLCS# SLWR# SLOE# SLRD# PKTEND#
  output wire        GPIF_CTL11, GPIF_CTL12,                                  // A1 A0
  input  wire        GPIF_CTL4, GPIF_CTL5,                                    // FLAGA FLAGB
  input  wire        GPIF_CTL9,                                               // global reset
  // AD9361 control and SPI, ADF4001 SPI
  output wire        codec_reset, cat_ce, cat_mosi, cat_sclk, pll_ce, pll_mosi, pll_sclk,
  input  wire        cat_miso,
  // AD9361 control pins (Ettus's constants), band-select switches (register 0x031)
  output wire        codec_enable, codec_txrx, codec_en_agc, codec_sync,
  output wire [3:0]  codec_ctrl_in,
  output wire        rx_bandsel_a, rx_bandsel_b, rx_bandsel_c, tx_bandsel_a, tx_bandsel_b,
  // AD9361 sample port: P0 receive, P1 transmit (ad9361_io)
  input  wire        codec_data_clk_p, rx_frame_p,
  input  wire [11:0] rx_codec_d,
  output wire        codec_fb_clk_p, tx_frame_p,
  output wire [11:0] tx_codec_d,
  // held off in step 2
  output wire        ref_sel,
  output wire        tx_enable1, tx_enable2,
  output wire        SFDX1_RX, SFDX1_TX, SFDX2_RX, SFDX2_TX, SRX1_RX, SRX1_TX, SRX2_RX, SRX2_TX,
  // LEDs
  output wire        LED_STATUS, LED_CLK_G, LED_CLK_R, LED_USR_G, LED_USR_R,
  output wire        LED_RX1, LED_TXRX1_RX, LED_TXRX1_TX
);
  // -- clocks and resets ------------------------------------------------------------------------
  wire ref_clk, fb, fb_buf, bus_raw, if_raw, r_raw, bus_clk, ifclk, ref200, locked;
  IBUFDS ibuf_ref (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(ref_clk));
  MMCME2_ADV #(
    .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(25.000), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(30.000),
    .CLKOUT0_DIVIDE_F(6.000), .CLKOUT1_DIVIDE(12), .CLKOUT2_DIVIDE(12),
    .CLKOUT2_PHASE(IFCLK_STEPS * 45.0 / 12), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE")
  ) mmcm (
    .CLKIN1(ref_clk), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb_buf), .CLKFBOUT(fb), .CLKFBOUTB(),
    .CLKOUT0(r_raw), .CLKOUT0B(), .CLKOUT1(bus_raw), .CLKOUT1B(), .CLKOUT2(if_raw), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DO(), .DRDY(), .DWE(1'b0),
    .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
    .LOCKED(locked), .CLKFBSTOPPED(), .CLKINSTOPPED(), .PWRDWN(1'b0), .RST(GPIF_CTL9));
  BUFG b_fb  (.I(fb),      .O(fb_buf));
  BUFG b_bus (.I(bus_raw), .O(bus_clk));
  BUFG b_if  (.I(if_raw),  .O(ifclk));
  BUFG b_ref (.I(r_raw),   .O(ref200));
  // IFCLK: a clock forwarded through an output register (high, then low)
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) o_ifclk
    (.C(ifclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(1'b1), .D2(1'b0), .Q(IFCLK));

  (* ASYNC_REG = "TRUE" *) reg [1:0] bus_rs = 2'b11;
  always @(posedge bus_clk or negedge locked) if (!locked) bus_rs <= 2'b11; else bus_rs <= {bus_rs[0], 1'b0};
  wire rst = bus_rs[1];
  // the IDELAYCTRL's reset: 32 bus cycles = 320 ns >= 52 ns after rst
  reg [4:0] ref_cnt = 0;
  reg       ref_rst = 1;
  always @(posedge bus_clk) ref_cnt <= rst ? 5'd0 : ref_cnt + {4'd0, ref_cnt != 5'h1F};
  always @(posedge bus_clk or negedge locked) if (!locked) ref_rst <= 1; else ref_rst <= rst || ref_cnt != 5'h1F;

  // -- the AD9361 sample port and the sample-path reset ---------------------------------------
  wire        dclk, io_stb, delay_ready, two, resetb, sample_running, rx_running;
  wire [47:0] adc, dac;
  ad9361_io radio (.data_clk(codec_data_clk_p), .rx_frame(rx_frame_p), .rx_d(rx_codec_d),
    .fb_clk(codec_fb_clk_p), .tx_frame(tx_frame_p), .tx_d(tx_codec_d),
    .ref200(ref200), .ref_rst(ref_rst), .delay_ready(delay_ready),
    .dclk(dclk), .two_async(two), .stb(io_stb), .adc(adc), .dac(dac));
  // x_rst: see the header. up counts bus cycles with everything fine.
  (* ASYNC_REG = "TRUE" *) reg ready1 = 0, ready2 = 0;
  reg [9:0] up = 0;
  reg       x_rst = 1;
  always @(posedge bus_clk) begin
    ready1 <= delay_ready; ready2 <= ready1;
    up <= (rst || !resetb || !ready2 || !sample_running) ? 10'd0 : up + {9'd0, up != 10'h3FF};
  end
  // ... and held until a stream it ended has closed
  always @(posedge bus_clk or negedge locked)
    if (!locked) x_rst <= 1; else x_rst <= up != 10'h3FF || (x_rst && rx_running);
  // srst: set by x_rst at once (dclk may be stopped), released on dclk
  (* ASYNC_REG = "TRUE" *) reg [1:0] s_rs = 2'b11;
  always @(posedge dclk or posedge x_rst) if (x_rst) s_rs <= 2'b11; else s_rs <= {s_rs[0], 1'b0};
  wire srst = s_rs[1];
  wire stb  = io_stb && !srst;

  // -- FX3 bus -------------------------------------------------------------------------------------
  wire        wr, rd, oe, pkt_end, drive, ready, wmark, out_last;
  wire [1:0]  thread, out_valid, in_take, out_room, in_avail, in_last;
  wire [31:0] dout, din, out_data;
  wire [63:0] in_data;              // in stream c in bits 32 c + 31 : 32 c
  assign GPIF_CTL0 = 1'b0;
  fx3_pads pads (.clk(bus_clk), .d(GPIF_D), .slwr(GPIF_CTL1), .slrd(GPIF_CTL3), .sloe(GPIF_CTL2),
    .pktend(GPIF_CTL7), .a({GPIF_CTL11, GPIF_CTL12}), .flaga(GPIF_CTL4), .flagb(GPIF_CTL5),
    .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end), .thread(thread), .drive(drive), .dout(dout),
    .din(din), .ready(ready), .wmark(wmark));
  fx3_master master (.clk(bus_clk), .rst(rst), .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end), .drive(drive),
    .thread(thread), .dout(dout), .din(din), .ready(ready), .wmark(wmark),
    .out_room(out_room), .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
    .in_avail(in_avail), .in_data(in_data), .in_last(in_last), .in_take(in_take));

  // -- tx: ring, deframer, crossing ----------------------------------------------------------------
  wire        txr_avail, txr_last, txr_take, txd_valid, txd_full, txd_present, txd_sob, txd_eob, txd_timed;
  wire [31:0] txr_data, tx_bad_packets, tx_seq_errors;
  wire [63:0] txd_at;
  wire [47:0] txd_data;
  wire [16:0] tx_used;
  packet_fifo #(.AW(16), .MAX(4096)) tx_ring (.clk(bus_clk), .rst(rst), .w_room(out_room[0]),
    .w_valid(out_valid[0]), .w_last(out_last), .w_data(out_data), .w_used(tx_used),
    .r_avail(txr_avail), .r_data(txr_data), .r_last(txr_last), .r_take(txr_take), .r_used());
  tx_deframer deframer (.clk(bus_clk), .rst(rst),
    .r_avail(txr_avail), .r_data(txr_data), .r_last(txr_last), .r_take(txr_take),
    .s_valid(txd_valid), .s_full(txd_full), .s_present(txd_present), .s_sob(txd_sob), .s_eob(txd_eob),
    .s_timed(txd_timed), .s_at(txd_at), .s_data(txd_data),
    .bad_packets(tx_bad_packets), .seq_errors(tx_seq_errors));
  wire         txs_valid, txs_take;
  wire [115:0] txs_entry;
  // while x_rst is high the crossing takes nothing: the deframer sees it full
  wire         txc_full;
  assign txd_full = txc_full || x_rst;
  cdc_fifo #(.W(116), .AW(4)) tx_cross (.wclk(bus_clk), .w_rst(x_rst), .w_valid(txd_valid),
    .w_data({txd_present, txd_sob, txd_eob, txd_timed, txd_at, txd_data}), .w_full(txc_full),
    .rclk(dclk), .r_rst(srst), .r_valid(txs_valid), .r_data(txs_entry), .r_take(txs_take));

  // -- sample side -----------------------------------------------------------------------------------
  wire [1:0]  rx_source;
  wire [63:0]  time_set, now_gray;
  wire         time_req, time_ack, rxs_valid, rxs_full, tx_active, sclk_alive;
  wire [111:0] rxs_entry;
  wire [15:0]  cdc_lost_g, underflow_g, late_g, burst_ack_g;
  sample_domain sample (.sclk(dclk), .srst(srst), .stb(stb), .adc(adc), .dac(dac), .rx_source_async(rx_source),
    .time_set(time_set), .time_req(time_req), .time_ack(time_ack), .now_gray(now_gray),
    .rx_valid(rxs_valid), .rx_entry(rxs_entry), .rx_full(rxs_full),
    .tx_valid(txs_valid), .tx_entry(txs_entry), .tx_take(txs_take),
    .cdc_lost_gray(cdc_lost_g), .underflow_gray(underflow_g), .late_gray(late_g), .burst_ack_gray(burst_ack_g),
    .tx_active(tx_active), .sclk_alive(sclk_alive));

  // -- rx: crossing, framer, ring -------------------------------------------------------------------
  wire         rxb_valid, rxb_take, rxc_valid;
  wire [111:0] rxb_entry, rxc_entry;
  cdc_fifo #(.W(112), .AW(4)) rx_cross (.wclk(dclk), .w_rst(srst), .w_valid(rxs_valid), .w_data(rxs_entry),
    .w_full(rxs_full), .rclk(bus_clk), .r_rst(x_rst), .r_valid(rxc_valid), .r_data(rxc_entry), .r_take(rxb_take));
  // While x_rst is high the framer is told to stop and, from the cycle after
  // it rose (stop seen first), gets a zero sample time every cycle - never
  // the crossing's, whose sample-side pointer may be frozen. They complete
  // the packet in progress, then are discarded; x_rst falls only once the
  // stream has closed.
  reg x_rst_p = 1;
  always @(posedge bus_clk) x_rst_p <= x_rst;
  assign rxb_valid = x_rst ? x_rst_p : rxc_valid;
  assign rxb_entry = x_rst ? 112'd0 : rxc_entry;
  wire        rx_start, rx_stop, rx_timed, rxr_room, rxr_valid, rxr_last;
  wire [3:0]  rx_format;
  wire [1:0]  rx_channels;
  wire [31:0] rx_count, rx_framer_overflows, rxr_data;
  wire [63:0] rx_at;
  wire [12:0] rx_spp;
  rx_framer framer (.clk(bus_clk), .rst(rst), .s_valid(rxb_valid), .s_time(rxb_entry[111:48]),
    .s_data(rxb_entry[47:0]), .s_take(rxb_take), .format(rx_format), .channels(rx_channels), .spp(rx_spp),
    .start(rx_start), .stop(rx_stop || x_rst), .timed(rx_timed), .at(rx_at), .count(rx_count),
    .w_room(rxr_room), .w_valid(rxr_valid), .w_last(rxr_last), .w_data(rxr_data), .running(rx_running),
    .overflows(rx_framer_overflows));
  wire [17:0] rx_used;
  packet_fifo #(.AW(17), .MAX(4096)) rx_ring (.clk(bus_clk), .rst(rst), .w_room(rxr_room), .w_valid(rxr_valid),
    .w_last(rxr_last), .w_data(rxr_data), .w_used(rx_used), .r_avail(in_avail[0]), .r_data(in_data[31:0]),
    .r_last(in_last[0]), .r_take(in_take[0]), .r_used());

  // -- control: commands, results, events ----------------------------------------------------------------
  wire        cmd_avail, cmd_last, cmd_take, res_w_room, res_w_valid, res_w_last, res_r_avail, res_r_last, res_r_take;
  wire        ev_w_room, ev_w_valid, ev_w_last, ev_r_avail, ev_r_last, ev_r_take;
  wire [31:0] cmd_data, res_w_data, res_r_data, ev_w_data, ev_r_data, cmd_dropped;
  wire        reg_we, reg_re;
  wire [15:0] reg_addr;
  wire [31:0] reg_wdata, reg_rdata;
  wire        spi_start, spi_dev, spi_done;
  wire [23:0] spi_word;
  wire [7:0]  spi_rdata;
  wire [4:0]  bands;
  packet_fifo #(.AW(9), .MAX(256)) cmd_fifo (.clk(bus_clk), .rst(rst), .w_room(out_room[1]),
    .w_valid(out_valid[1]), .w_last(out_last), .w_data(out_data), .w_used(),
    .r_avail(cmd_avail), .r_data(cmd_data), .r_last(cmd_last), .r_take(cmd_take), .r_used());
  command commands (.clk(bus_clk), .rst(rst),
    .r_avail(cmd_avail), .r_data(cmd_data), .r_last(cmd_last), .r_take(cmd_take),
    .w_room(res_w_room), .w_valid(res_w_valid), .w_last(res_w_last), .w_data(res_w_data),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .spi_start(spi_start), .spi_dev(spi_dev), .spi_word(spi_word), .spi_done(spi_done), .spi_rdata(spi_rdata),
    .cmd_dropped(cmd_dropped));
  spi_master spi (.clk(bus_clk), .rst(rst), .start(spi_start), .dev(spi_dev), .word(spi_word), .done(spi_done),
    .rdata(spi_rdata), .cat_ce(cat_ce), .cat_sclk(cat_sclk), .cat_mosi(cat_mosi), .cat_miso(cat_miso),
    .pll_ce(pll_ce), .pll_sclk(pll_sclk), .pll_mosi(pll_mosi));
  packet_fifo #(.AW(9), .MAX(256)) result_fifo (.clk(bus_clk), .rst(rst),
    .w_room(res_w_room), .w_valid(res_w_valid), .w_last(res_w_last), .w_data(res_w_data), .w_used(),
    .r_avail(res_r_avail), .r_data(res_r_data), .r_last(res_r_last), .r_take(res_r_take), .r_used());

  // time and the sample side's counters, read on the bus clock
  wire [63:0] now;
  gray_sync #(.W(64)) g_now (.clk(bus_clk), .g_in(now_gray), .b(now));
  wire [15:0] cdc_lost16, underflow16, late16, burst_ack16;
  gray_sync #(.W(16)) g_cdc_lost  (.clk(bus_clk), .g_in(cdc_lost_g),  .b(cdc_lost16));
  gray_sync #(.W(16)) g_underflow (.clk(bus_clk), .g_in(underflow_g), .b(underflow16));
  gray_sync #(.W(16)) g_late      (.clk(bus_clk), .g_in(late_g),      .b(late16));
  gray_sync #(.W(16)) g_burst_ack (.clk(bus_clk), .g_in(burst_ack_g), .b(burst_ack16));
  // extended to 32 bits: add each change modulo 2^16 (a change between two
  // bus cycles is far below 2^15)
  reg [15:0] cdc_lost_p = 0, underflow_p = 0, late_p = 0, burst_ack_p = 0;
  reg [31:0] rx_cdc_lost = 0, underflows = 0, lates = 0, burst_acks = 0;
  always @(posedge bus_clk) begin
    cdc_lost_p <= cdc_lost16; underflow_p <= underflow16; late_p <= late16; burst_ack_p <= burst_ack16;
    rx_cdc_lost <= rx_cdc_lost + {16'd0, cdc_lost16 - cdc_lost_p};
    underflows <= underflows + {16'd0, underflow16 - underflow_p};
    lates <= lates + {16'd0, late16 - late_p};
    burst_acks <= burst_acks + {16'd0, burst_ack16 - burst_ack_p};
  end
  // event codes 1 .. 6: OVERFLOW (dropped by rx_framer for lack of ring room
  // + lost in the rx clock crossing), UNDERFLOW, LATE, SEQ_ERROR, BURST_ACK,
  // BAD_PACKET
  // registered: the sums would otherwise sit in series with events' compares
  wire [31:0] rx_overflows = rx_framer_overflows + rx_cdc_lost;
  reg  [191:0] counts = 0;
  always @(posedge bus_clk) counts <= {tx_bad_packets, burst_acks, tx_seq_errors, lates, underflows, rx_overflows};
  events ev (.clk(bus_clk), .rst(rst), .counts(counts), .now(now), .w_room(ev_w_room), .w_valid(ev_w_valid),
    .w_last(ev_w_last), .w_data(ev_w_data));
  packet_fifo #(.AW(7), .MAX(32)) event_fifo (.clk(bus_clk), .rst(rst),
    .w_room(ev_w_room), .w_valid(ev_w_valid), .w_last(ev_w_last), .w_data(ev_w_data), .w_used(),
    .r_avail(ev_r_avail), .r_data(ev_r_data), .r_last(ev_r_last), .r_take(ev_r_take), .r_used());
  packet_mux to_host (.clk(bus_clk), .rst(rst),
    .a_avail(res_r_avail), .a_last(res_r_last), .a_data(res_r_data), .a_take(res_r_take),
    .b_avail(ev_r_avail), .b_last(ev_r_last), .b_data(ev_r_data), .b_take(ev_r_take),
    .o_avail(in_avail[1]), .o_last(in_last[1]), .o_data(in_data[63:32]), .o_take(in_take[1]));

  // sample clock running: the radio's clock itself (sample_domain's
  // sclk_alive toggles every 2 dclk cycles, also in reset) moved within the
  // last 1023 bus cycles = 10.24 us, so a strobe every other cycle cannot
  // look like a stopped clock and a stopped clock cannot look alive
  reg [63:0] now_p = 0;
  (* ASYNC_REG = "TRUE" *) reg alive1 = 0, alive2 = 0, alive_p = 0;
  reg [9:0]  still = 0;
  wire alive_change = alive2 != alive_p;
  always @(posedge bus_clk) begin
    now_p <= now; alive1 <= sclk_alive; alive2 <= alive1; alive_p <= alive2;
    still <= alive_change ? 10'd0 : still == 10'h3FF ? still : still + 1;
  end
  assign sample_running = still != 10'h3FF;
  // sample rate: strobes in the last 100 000 bus cycles (1 ms at 100 MHz).
  // The 16-bit difference is exact: fewer than 2^16 strobes fit in 1 ms at
  // any rate this design allows.
  reg [16:0] rate_cnt = 0, sample_ksps = 0;
  reg [16:0] ms = 0;
  wire [15:0] tick_delta = now[15:0] - now_p[15:0];
  always @(posedge bus_clk) begin
    ms <= ms + 1;
    if (ms == 100_000 - 1) begin sample_ksps <= rate_cnt + tick_delta; rate_cnt <= 0; ms <= 0; end
    else rate_cnt <= rate_cnt + tick_delta;
  end
  // time_ack crosses back to the bus clock. The ack is delayed 2 more cycles
  // so that it rises no earlier than the now copy: gray_sync takes 4 stages
  // (2 synchronisers + local XOR + b), the ack 2 synchronisers + these 2.
  // Without that, a POLL of 0x014 could see "done" and read a mixed `now`.
  (* ASYNC_REG = "TRUE" *) reg time_ack1 = 0, time_ack2 = 0, time_ack3 = 0, time_ack4 = 0;
  always @(posedge bus_clk) begin
    time_ack1 <= time_ack; time_ack2 <= time_ack1; time_ack3 <= time_ack2; time_ack4 <= time_ack3;
  end

  regs #(.BUILD_NUMBER(BUILD_NUMBER), .BUILD_COMMIT(BUILD_COMMIT)) registers (.clk(bus_clk), .rst(rst),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .locked(locked), .sample_running(sample_running), .now(now), .time_set(time_set), .time_req(time_req),
    .time_ack(time_ack4), .rx_start(rx_start), .rx_stop(rx_stop), .rx_timed(rx_timed), .rx_format(rx_format),
    .rx_channels(rx_channels), .rx_count(rx_count), .rx_at(rx_at), .rx_spp(rx_spp), .rx_running(rx_running),
    .counts(counts), .rx_cdc_lost(rx_cdc_lost), .cmd_dropped(cmd_dropped),
    .rx_used(rx_used), .tx_used(tx_used), .sample_ksps(sample_ksps),
    .delay_ready(ready2), .sample_ready(!x_rst), .resetb(resetb), .two(two), .bands(bands), .rx_source(rx_source));

  // -- AD9361 reset and control pins, band selects, RF switches -------------------------------------
  assign codec_reset = resetb;                     // AD9361 RESETB, active low
  // as Ettus's b200.v drives them (and v1, src/top/b200.v at tag
  // v1-ettus-uhd): CTRL_IN = 0001, EN_AGC high, TXNRX high, ENABLE high,
  // SYNC_IN low; with the ENSM under SPI control (UHD's setting) ENABLE and
  // TXNRX do not move it
  assign codec_ctrl_in = 4'b0001;
  assign {codec_en_agc, codec_txrx, codec_enable, codec_sync} = 4'b1110;
  assign {tx_bandsel_b, tx_bandsel_a, rx_bandsel_c, rx_bandsel_b, rx_bandsel_a} = bands;
  assign ref_sel = 1'b0;
  assign {tx_enable1, tx_enable2} = 2'b00;
  // RF switches in UHD's "off" state for each channel, STATE_RXn_OFF =
  // SFDXn_RX | SRXn_TX (host/lib/usrp/b200/b200_regs.hpp of current UHD;
  // bits there: SFDXn_RX 6, SFDXn_TX 5, SRXn_RX 4, SRXn_TX 3, as v1's b200.v
  // wires them: {tx_enablen, SFDXn_RX, SFDXn_TX, SRXn_RX, SRXn_TX} =
  // gpio[7:3]). Constant in this step; driving them per state from
  // tx_active (ATR) is a later step.
  assign {SFDX1_RX, SFDX1_TX, SFDX2_RX, SFDX2_TX, SRX1_RX, SRX1_TX, SRX2_RX, SRX2_TX} = 8'b1010_0101;

  // -- LEDs ----------------------------------------------------------------------------------------------
  reg [25:0] beat = 0;
  always @(posedge bus_clk) beat <= beat + 1;
  // lit for N bus cycles after a trigger
  reg [22:0] cmd_lit = 0;          // 84 ms
  reg [27:0] err_lit = 0;          // 2^28 cycles = 2.68 s
  // the trouble counters as one sum (codes 1, 2, 3, 4, 6; 5 is BURST_ACK):
  // 32 flip-flops instead of a copy of the 192-bit counter bus
  reg  [31:0] trouble = 0, trouble_p = 0;
  always @(posedge bus_clk) begin
    trouble <= rx_overflows + underflows + lates + tx_seq_errors + tx_bad_packets;
    trouble_p <= trouble;
    cmd_lit <= (res_w_valid && res_w_last) ? 23'h7FFFFF : cmd_lit != 0 ? cmd_lit - 1 : 0;
    err_lit <= trouble != trouble_p ? 28'hFFFFFFF : err_lit != 0 ? err_lit - 1 : 0;
  end
  (* ASYNC_REG = "TRUE" *) reg [1:0] txa = 0;
  always @(posedge bus_clk) txa <= {txa[0], tx_active};
  assign LED_STATUS   = beat[25];
  assign LED_CLK_G    = locked && sample_running;
  assign LED_CLK_R    = !locked;
  assign LED_USR_G    = cmd_lit != 0;
  assign LED_USR_R    = err_lit != 0;
  assign LED_RX1      = rx_running;
  assign LED_TXRX1_RX = txa[1];
  assign LED_TXRX1_TX = txa[1];
endmodule

`default_nettype wire
