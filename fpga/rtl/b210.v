// SPDX-License-Identifier: GPL-3.0-or-later
//
// b210 - the FPGA top, step 1: the USB path end to end with the AD9361
// replaced by a test clock and sample_core's pattern / loopback.
//
//   host <-USB-> FX3 <-GPIF-> fx3_pads, fx3_master
//     thread 0 tx      -> tx ring  -> tx_player -> cdc_fifo -> sample_core
//     thread 1 rx      <- rx ring  <- rx_framer <- cdc_fifo <- sample_core
//     thread 2 command -> cmd fifo -> ctrl -> regs, spi (AD9361, ADF4001)
//     thread 3 result  <- packet_mux <- result fifo (ctrl), event fifo (events)
//
// Clocks, from the 40 MHz reference (codec_main_clk, running from power-up)
// through one MMCM, VCO 40 * 30 = 1200 MHz:
//   bus_clk  1200 / 12   = 100 MHz   everything but the sample side
//   ifclk    1200 / 12   = 100 MHz   forwarded to the FX3 as IFCLK, lagging
//            bus_clk by IFCLK_STEPS * 45 / 12 degrees (66 steps: the centre
//            of the window 37 .. 94 measured on this board, docs/STATUS.md)
//   sclk     1200 / 19.5 = 61.54 MHz the step-1 sample clock (the VCO has no
//            exact 61.44; 0.16 % faster than the AD9361's top rate)
// A sample strobe every test_div + 1 sclk cycles (register 0x0F1).
// GPIF_CTL9 (the FX3's global reset) resets the MMCM; each clock domain
// leaves reset two of its cycles after the MMCM locks.
//
// The AD9361 stays in reset (RESETB low) until the radio register (0x030)
// releases it; its SPI and the ADF4001's are spi.v's, deselected between
// frames. Pins this step does not use are held where the radio is off and
// silent: both PA enables and every antenna-switch line low, the reference
// on the internal oscillator.
//
// LEDs (every pin lights its LED when high):
//   STATUS  blue    heartbeat of the bus clock (0.67 s)
//   CLK     green   sample clock running      red  clocks not locked
//   USR     green   a flash per command packet  red  a sample lost, a tx
//                   underflow, late burst, sequence jump or bad packet in
//                   the last 2 s
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
  // held off in step 1
  output wire        ref_sel,
  output wire        tx_enable1, tx_enable2,
  output wire        SFDX1_RX, SFDX1_TX, SFDX2_RX, SFDX2_TX, SRX1_RX, SRX1_TX, SRX2_RX, SRX2_TX,
  // LEDs
  output wire        LED_STATUS, LED_CLK_G, LED_CLK_R, LED_USR_G, LED_USR_R,
  output wire        LED_RX1, LED_TXRX1_RX, LED_TXRX1_TX
);
  // -- clocks and resets ------------------------------------------------------------------------
  wire ref_clk, fb, fb_buf, bus_raw, if_raw, s_raw, bus_clk, ifclk, sclk, locked;
  IBUFDS ibuf_ref (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(ref_clk));
  MMCME2_ADV #(
    .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(25.000), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(30.000),
    .CLKOUT0_DIVIDE_F(19.500), .CLKOUT1_DIVIDE(12), .CLKOUT2_DIVIDE(12),
    .CLKOUT2_PHASE(IFCLK_STEPS * 45.0 / 12), .COMPENSATION("ZHOLD"), .STARTUP_WAIT("FALSE")
  ) mmcm (
    .CLKIN1(ref_clk), .CLKIN2(1'b0), .CLKINSEL(1'b1), .CLKFBIN(fb_buf), .CLKFBOUT(fb), .CLKFBOUTB(),
    .CLKOUT0(s_raw), .CLKOUT0B(), .CLKOUT1(bus_raw), .CLKOUT1B(), .CLKOUT2(if_raw), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DO(), .DRDY(), .DWE(1'b0),
    .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
    .LOCKED(locked), .CLKFBSTOPPED(), .CLKINSTOPPED(), .PWRDWN(1'b0), .RST(GPIF_CTL9));
  BUFG b_fb  (.I(fb),      .O(fb_buf));
  BUFG b_bus (.I(bus_raw), .O(bus_clk));
  BUFG b_if  (.I(if_raw),  .O(ifclk));
  BUFG b_s   (.I(s_raw),   .O(sclk));
  // IFCLK: a clock forwarded through an output register (high, then low)
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) o_ifclk
    (.C(ifclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(1'b1), .D2(1'b0), .Q(IFCLK));

  (* ASYNC_REG = "TRUE" *) reg [1:0] bus_rs = 2'b11, s_rs = 2'b11;
  always @(posedge bus_clk or negedge locked) if (!locked) bus_rs <= 2'b11; else bus_rs <= {bus_rs[0], 1'b0};
  always @(posedge sclk    or negedge locked) if (!locked) s_rs   <= 2'b11; else s_rs   <= {s_rs[0], 1'b0};
  wire rst = bus_rs[1], srst = s_rs[1];

  // -- FX3 bus -------------------------------------------------------------------------------------
  wire        wr, rd, oe, pkt_end, drive, ready, wmark, out_last;
  wire [1:0]  thread, out_valid, in_take, out_room, in_avail, in_last;
  wire [31:0] dout, din, out_data, in_data0, in_data1;
  assign GPIF_CTL0 = 1'b0;
  fx3_pads pads (.clk(bus_clk), .d(GPIF_D), .slwr(GPIF_CTL1), .slrd(GPIF_CTL3), .sloe(GPIF_CTL2),
    .pktend(GPIF_CTL7), .a({GPIF_CTL11, GPIF_CTL12}), .flaga(GPIF_CTL4), .flagb(GPIF_CTL5),
    .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end), .thread(thread), .drive(drive), .dout(dout),
    .din(din), .ready(ready), .wmark(wmark));
  fx3_master master (.clk(bus_clk), .rst(rst), .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end), .drive(drive),
    .thread(thread), .dout(dout), .din(din), .ready(ready), .wmark(wmark),
    .out_room(out_room), .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
    .in_avail(in_avail), .in_data0(in_data0), .in_data1(in_data1), .in_last(in_last), .in_take(in_take));

  // -- tx: ring, player, crossing ------------------------------------------------------------------
  wire        tx_avail, tx_last, tx_take, txp_valid, txp_ready, txp_present, txp_sob, txp_eob, txp_timed;
  wire [31:0] tx_data, tx_bad_packets, tx_seq_errors;
  wire [63:0] txp_time;
  wire [47:0] txp_data;
  wire [16:0] tx_used_w;
  packet_fifo #(.AW(16), .MAX(4096)) tx_ring (.clk(bus_clk), .rst(rst), .w_room(out_room[0]),
    .w_valid(out_valid[0]), .w_last(out_last), .w_data(out_data), .w_used(tx_used_w),
    .r_avail(tx_avail), .r_data(tx_data), .r_last(tx_last), .r_take(tx_take), .r_used());
  tx_player player (.clk(bus_clk), .rst(rst), .r_avail(tx_avail), .r_data(tx_data), .r_last(tx_last), .r_take(tx_take),
    .o_valid(txp_valid), .o_ready(txp_ready), .o_present(txp_present), .o_sob(txp_sob), .o_eob(txp_eob),
    .o_timed(txp_timed), .o_time(txp_time), .o_data(txp_data),
    .bad_packets(tx_bad_packets), .seq_errors(tx_seq_errors));
  wire         txc_full, txs_valid, txs_take;
  wire [115:0] txs_entry;
  assign txp_ready = !txc_full;
  cdc_fifo #(.W(116), .AW(4)) tx_cross (.wclk(bus_clk), .w_rst(rst), .w_valid(txp_valid),
    .w_data({txp_present, txp_sob, txp_eob, txp_timed, txp_time, txp_data}), .w_full(txc_full),
    .rclk(sclk), .r_rst(srst), .r_valid(txs_valid), .r_data(txs_entry), .r_take(txs_take));

  // -- sample side -----------------------------------------------------------------------------------
  wire [15:0] test_div;
  wire [1:0]  test;
  (* ASYNC_REG = "TRUE" *) reg [15:0] div1 = 0, div2 = 0;    // static while streaming
  reg  [15:0] div_cnt = 0;
  reg         stb = 0;
  always @(posedge sclk) begin
    div1 <= test_div; div2 <= div1;
    stb <= div_cnt == 0;
    div_cnt <= div_cnt == 0 ? div2 : div_cnt - 1;
  end
  wire [63:0]  time_set, now_gray;
  wire         time_req, time_ack, rxs_valid, rxc_full, tx_active, sclk_alive;
  wire [111:0] rxs_entry;
  wire [15:0]  lost_g, under_g, late_g, ack_g;
  sample_core core (.sclk(sclk), .srst(srst), .stb(stb), .adc(48'd0), .dac(), .mode_async(test),
    .set_value(time_set), .set_req(time_req), .set_ack(time_ack), .now_gray(now_gray),
    .rx_valid(rxs_valid), .rx_entry(rxs_entry), .rx_full(rxc_full),
    .tx_valid(txs_valid), .tx_entry(txs_entry), .tx_take(txs_take),
    .rx_lost_gray(lost_g), .underflow_gray(under_g), .late_gray(late_g), .ack_gray(ack_g),
    .tx_active(tx_active), .sclk_alive(sclk_alive));

  // -- rx: crossing, framer, ring -------------------------------------------------------------------
  wire         rxb_valid, rxb_take;
  wire [111:0] rxb_entry;
  cdc_fifo #(.W(112), .AW(4)) rx_cross (.wclk(sclk), .w_rst(srst), .w_valid(rxs_valid), .w_data(rxs_entry),
    .w_full(rxc_full), .rclk(bus_clk), .r_rst(rst), .r_valid(rxb_valid), .r_data(rxb_entry), .r_take(rxb_take));
  wire        rx_start, rx_stop, rx_at, rx_running, rf_room, rf_valid, rf_last;
  wire [3:0]  rx_format;
  wire [1:0]  rx_channels;
  wire [31:0] rx_count, rx_dropped, rf_data;
  wire [63:0] rx_time;
  wire [12:0] rx_spp;
  rx_framer framer (.clk(bus_clk), .rst(rst), .s_valid(rxb_valid), .s_time(rxb_entry[111:48]),
    .s_data(rxb_entry[47:0]), .s_take(rxb_take), .format(rx_format), .channels(rx_channels), .spp(rx_spp),
    .start(rx_start), .stop(rx_stop), .start_at(rx_at), .start_time(rx_time), .count(rx_count),
    .w_room(rf_room), .w_valid(rf_valid), .w_last(rf_last), .w_data(rf_data), .running(rx_running), .dropped(rx_dropped));
  wire [17:0] rx_used_w;
  packet_fifo #(.AW(17), .MAX(4096)) rx_ring (.clk(bus_clk), .rst(rst), .w_room(rf_room), .w_valid(rf_valid),
    .w_last(rf_last), .w_data(rf_data), .w_used(rx_used_w), .r_avail(in_avail[0]), .r_data(in_data0),
    .r_last(in_last[0]), .r_take(in_take[0]), .r_used());

  // -- control: commands, results, events ----------------------------------------------------------------
  wire        c_avail, c_last, c_take, r_room, r_valid, r_last, ra, rl, rta, e_room, e_valid, e_last, ea, el, eta;
  wire [31:0] c_data, r_data, rdat, e_data, edat, cmd_dropped;
  wire        reg_we, reg_re;
  wire [15:0] reg_addr;
  wire [31:0] reg_wdata, reg_rdata;
  wire        spi_start, spi_dev, spi_done, resetb;
  wire [23:0] spi_word;
  wire [7:0]  spi_rdata;
  packet_fifo #(.AW(9), .MAX(256)) cmd_fifo (.clk(bus_clk), .rst(rst), .w_room(out_room[1]),
    .w_valid(out_valid[1]), .w_last(out_last), .w_data(out_data), .w_used(),
    .r_avail(c_avail), .r_data(c_data), .r_last(c_last), .r_take(c_take), .r_used());
  ctrl control (.clk(bus_clk), .rst(rst), .c_avail(c_avail), .c_data(c_data), .c_last(c_last), .c_take(c_take),
    .r_room(r_room), .r_valid(r_valid), .r_last(r_last), .r_data(r_data),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .spi_start(spi_start), .spi_dev(spi_dev), .spi_word(spi_word), .spi_done(spi_done), .spi_rdata(spi_rdata),
    .dropped(cmd_dropped));
  spi serial (.clk(bus_clk), .rst(rst), .start(spi_start), .dev(spi_dev), .word(spi_word), .done(spi_done),
    .rdata(spi_rdata), .cat_ce(cat_ce), .cat_sclk(cat_sclk), .cat_mosi(cat_mosi), .cat_miso(cat_miso),
    .pll_ce(pll_ce), .pll_sclk(pll_sclk), .pll_mosi(pll_mosi));
  packet_fifo #(.AW(9), .MAX(256)) result_fifo (.clk(bus_clk), .rst(rst), .w_room(r_room), .w_valid(r_valid),
    .w_last(r_last), .w_data(r_data), .w_used(), .r_avail(ra), .r_data(rdat), .r_last(rl), .r_take(rta), .r_used());

  // time and the sample side's counters, read on the bus clock
  wire [63:0] now;
  gray_sync #(.W(64)) g_now (.clk(bus_clk), .g_in(now_gray), .b(now));
  wire [15:0] lost16, under16, late16, ack16;
  gray_sync #(.W(16)) g_lost  (.clk(bus_clk), .g_in(lost_g),  .b(lost16));
  gray_sync #(.W(16)) g_under (.clk(bus_clk), .g_in(under_g), .b(under16));
  gray_sync #(.W(16)) g_late  (.clk(bus_clk), .g_in(late_g),  .b(late16));
  gray_sync #(.W(16)) g_ack   (.clk(bus_clk), .g_in(ack_g),   .b(ack16));
  // extended to 32 bits: add each change modulo 2^16 (a change between two
  // bus cycles is far below 2^15)
  reg [15:0] lost_p = 0, under_p = 0, late_p = 0, ack_p = 0;
  reg [31:0] rx_lost = 0, underflows = 0, lates = 0, acks = 0;
  always @(posedge bus_clk) begin
    lost_p <= lost16; under_p <= under16; late_p <= late16; ack_p <= ack16;
    rx_lost <= rx_lost + {16'd0, lost16 - lost_p};
    underflows <= underflows + {16'd0, under16 - under_p};
    lates <= lates + {16'd0, late16 - late_p};
    acks <= acks + {16'd0, ack16 - ack_p};
  end
  // event codes 1 .. 6: OVERFLOW (rx dropped + lost crossing), UNDERFLOW,
  // LATE, SEQ_ERROR, BURST_ACK, BAD_PACKET
  // registered: the sums would otherwise sit in series with events' compares
  wire [31:0] rx_overflows = rx_dropped + rx_lost;
  reg  [191:0] counts = 0;
  always @(posedge bus_clk) counts <= {tx_bad_packets, acks, tx_seq_errors, lates, underflows, rx_overflows};
  events ev (.clk(bus_clk), .rst(rst), .counts(counts), .now(now), .w_room(e_room), .w_valid(e_valid),
    .w_last(e_last), .w_data(e_data));
  packet_fifo #(.AW(7), .MAX(32)) event_fifo (.clk(bus_clk), .rst(rst), .w_room(e_room), .w_valid(e_valid),
    .w_last(e_last), .w_data(e_data), .w_used(), .r_avail(ea), .r_data(edat), .r_last(el), .r_take(eta), .r_used());
  packet_mux to_host (.clk(bus_clk), .rst(rst), .a_avail(ra), .a_last(rl), .a_data(rdat), .a_take(rta),
    .b_avail(ea), .b_last(el), .b_data(edat), .b_take(eta),
    .o_avail(in_avail[1]), .o_last(in_last[1]), .o_data(in_data1), .o_take(in_take[1]));

  // sample clock running: the radio's clock itself (sample_core's
  // sclk_alive toggles every 2 sclk cycles) moved within the last 1023 bus
  // cycles = 10.24 us, so a slow strobe divider cannot look like a stopped
  // clock and a stopped clock cannot look alive
  reg [63:0] now_p = 0;
  (* ASYNC_REG = "TRUE" *) reg alive1 = 0, alive2 = 0, alive_p = 0;
  reg [9:0]  still = 0;
  wire alive_change = alive2 != alive_p;
  always @(posedge bus_clk) begin
    now_p <= now; alive1 <= sclk_alive; alive2 <= alive1; alive_p <= alive2;
    still <= alive_change ? 10'd0 : still == 10'h3FF ? still : still + 1;
  end
  wire sample_running = still != 10'h3FF;
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
  (* ASYNC_REG = "TRUE" *) reg ack1 = 0, ack2 = 0, ack3 = 0, ack4 = 0;
  always @(posedge bus_clk) begin ack1 <= time_ack; ack2 <= ack1; ack3 <= ack2; ack4 <= ack3; end

  regs #(.BUILD_NUMBER(BUILD_NUMBER), .BUILD_COMMIT(BUILD_COMMIT)) registers (.clk(bus_clk), .rst(rst),
    .reg_we(reg_we), .reg_re(reg_re), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
    .locked(locked), .sample_running(sample_running), .now(now), .time_set(time_set), .time_req(time_req),
    .time_ack(ack4), .rx_start(rx_start), .rx_stop(rx_stop), .rx_at(rx_at), .rx_format(rx_format),
    .rx_channels(rx_channels), .rx_count(rx_count), .rx_time(rx_time), .rx_spp(rx_spp), .rx_running(rx_running),
    .events(counts), .rx_lost(rx_lost), .cmd_dropped(cmd_dropped),
    .rx_used(rx_used_w[12:0]), .tx_used(tx_used_w[12:0]), .sample_ksps(sample_ksps),
    .resetb(resetb), .test(test), .test_div(test_div));

  // -- AD9361 reset, pins held off -------------------------------------------------------------------
  assign codec_reset = resetb;                     // AD9361 RESETB, active low
  assign ref_sel = 1'b0;
  assign {tx_enable1, tx_enable2} = 2'b00;
  assign {SFDX1_RX, SFDX1_TX, SFDX2_RX, SFDX2_TX, SRX1_RX, SRX1_TX, SRX2_RX, SRX2_TX} = 8'd0;

  // -- LEDs ----------------------------------------------------------------------------------------------
  reg [25:0] beat = 0;
  always @(posedge bus_clk) beat <= beat + 1;
  // lit for N bus cycles after a trigger
  reg [22:0] cmd_lit = 0;          // 84 ms
  reg [27:0] err_lit = 0;          // 2.7 s
  // the trouble counters as one sum (codes 1, 2, 3, 4, 6; 5 is BURST_ACK):
  // 32 flip-flops instead of a copy of the 192-bit counter bus
  reg  [31:0] trouble = 0, trouble_p = 0;
  always @(posedge bus_clk) begin
    trouble <= rx_overflows + underflows + lates + tx_seq_errors + tx_bad_packets;
    trouble_p <= trouble;
    cmd_lit <= (r_valid && r_last) ? 23'h7FFFFF : cmd_lit != 0 ? cmd_lit - 1 : 0;
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
