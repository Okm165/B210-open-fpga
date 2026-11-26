// SPDX-License-Identifier: GPL-3.0-or-later
//
// ad9361_io - the AD9361 sample port: CMOS, dual port, DDR, full duplex
// (UG-570 "Dual port full duplex mode (CMOS)": P0 carries rx, P1 tx), on
// the AD9361's own DATA_CLK: the sample logic runs on dclk (DATA_CLK
// through one BUFG) with a sample strobe, as ADI's Pluto and Ettus' e310_io
// do; no divided clock.
//
// The words: each DATA_CLK period T carries one complex sample of one
// channel, I in the first half (from the rising edge), Q in the second.
//   1R1T  a sample time every period:      I, Q, I, Q, ...
//   2R2T  channels alternate, a sample time every 2 periods: I1, Q1, I2, Q2
// (UG-570 Figures 74, 75 with 0x010 = 0xC8, 0x011 = 0x00, 0x012 = 0x02,
// exactly what UHD's ad9361_device.cpp writes for this board.) RX_FRAME is
// in pulse mode (0x010 bit 3): a 50 % pulse train rising at each frame's
// start, so high for I and low for Q in 1R1T, high for channel 0's period
// and low for channel 1's in 2R2T; TX_FRAME is driven the same way (as v1's
// b200_io.v did). DATA_CLK = sample rate x channels, at most 61.44 MHz.
//
// Receive timing. The AD9361 launches a word tDDRX = 0 .. 1.5 ns (frame
// tDDDV = 0 .. 1.0 ns) after a DATA_CLK edge (data sheet Rev. F, p. 6),
// plus its rx data delay (0x006[3:0] = 0x9, ours, not UHD's 0xF: the
// driver's own measured eye, see below). Here the capture clock reaches the
// IDDRs 2.25 ns after the pad (pad -> BUFG, src/constraints/b210.xdc at tag v1-ettus-uhd),
// and every rx pin passes an IDELAYE2 of RX_IDELAY_TAPS taps of 1 / (64 x
// 200 MHz) = 78.125 ps (UG471 "IDELAYE2"; 20 taps = 1.56 ns, UHD's value).
//
// The chip's rx eye, measured by this driver on this image with the BIST
// PRBS (`b210-radio scan`): at clock delay 0, the data delays 4 .. 15 carry
// the sequence with zero errors at 0.2 s per point, both in 2R2T at
// 30.72 MS/s and 1R1T at 61.44 MS/s; UHD's 0xF sits one 0.24 ns step from
// the failing edge (v1's claim of an 11-step margin from its 31 x 31
// loopback held on one side only). The shipped value is the window's
// midpoint (AN-1441's practice): data 9, 1.44 ns to the near edge, 1.68 ns
// to the far one. A word launched at edge k thus settles 2.16 +
// 1.5 + 1.56 - 2.25 = 2.97 ns after the capture clock's edge k at the
// latest, and is taken by its next edge, T/2 = 8.14 ns later: the word
// launched on the rising edge (I) by the falling edge, the one launched on
// the falling edge (Q) by the next rising edge. IDDR SAME_EDGE (UG471
// figure 2-6) gives both at that rising edge: Q2 = the falling-edge sample,
// Q1 = the rising-edge one, so {Q2, Q1} = {I, Q} of one sample, exactly the
// pairing v1 used and proved on the board (b200_io.v: Q2 -> i, Q1 -> q;
// the AD9361's BIST PRBS arrived with zero errors on both channels in 8 of
// 8 sessions of 2.1 M samples, and its receive test tone measured SFDR
// 73.4 dB, SINAD 62.5 dB at 2 x 30.72 and 1 x 61.44 MS/s; v1 measurement,
// docs/STATUS.md at tag v1-ettus-uhd).
//
// Sample times (on dclk, registered): per period the pair {I, Q} and its
// frame bits fi (with I), fq (with Q).
//   1R1T  stb every period, adc = {0, 0, Q, I} (the one channel is
//         channel 0; channel 1's slots are 0).
//   2R2T  a pair starts a frame (channel 0) when fi = 1 and the previous
//         pair's fq = 0. c1 says the next pair is channel 1: after a start
//         it is, otherwise it alternates, so the strobe keeps every other
//         period while the frame is absent (time keeps running) and locks
//         to the frame when it comes (a pair that starts a frame is never
//         taken as channel 1: at most one sample time is skipped while it
//         locks). stb with channel 1's pair: adc = {Q1, I1, Q0, I0}.
// adc and stb change together at the edge after the IDDRs present the
// pair, so a sample time is on adc during the cycle stb marks.
//
// Transmit. sample_domain changes dac at the edges where stb is high
// (dac = the sample to play, held to the next strobe). At every edge:
//   1R1T, or 2R2T with stb low:  channel 0 of dac,  TX_FRAME high, low (1R1T)
//                                                   or high, high (2R2T)
//   2R2T with stb high:          channel 1 of dac,  TX_FRAME low, low
// so in 2R2T channel 0 goes out the period before the strobe and channel 1
// the period of it, both from the same dac value. ODDR SAME_EDGE takes the
// pair at the next rising edge and drives I while dclk is high, Q while it
// is low; FB_CLK = ODDR(1, 0) leaves with them, a copy of DATA_CLK with the
// data's phase. The AD9361 takes P1 on FB_CLK after its tx data delay
// (0x007[3:0] = 0xF, UHD), setup tSTX >= 1 ns, hold tHTX >= 0 (data sheet);
// at 61.44 MHz the nearest data transition lay 14 AD9361 delay steps
// (3.4 ns) from UHD's 0x007 = 0x0F, by the AD9361's digital loopback run
// over all 31 x 31 clock / data delays (v1 measurement, docs/STATUS.md at
// tag v1-ettus-uhd).
//
// Latency (dclk periods, both modes): rx, from the rising edge that
// captures a sample time's last word (Q0 in 1R1T, Q1 in 2R2T) to the edge
// where adc and stb change: 1; tx, from the edge where dac changes to the
// rising edge where the sample time's first word (I0) leaves: 2.
//
// two_async: 2R2T mode from the bus clock, crossed by two flip-flops; it
// must change only while no stream runs (the sample times around a change
// are not defined). ref200 / ref_rst: the IDELAYCTRL's 200 MHz reference
// and its reset (high >= 52 ns after ref200 is stable, UG471 "IDELAYCTRL");
// delay_ready: the delay taps are calibrated.
`default_nettype none

module ad9361_io #(
  parameter integer RX_IDELAY_TAPS = 20
) (
  // AD9361 pins
  input  wire        data_clk,       // DATA_CLK
  input  wire        rx_frame,       // RX_FRAME
  input  wire [11:0] rx_d,           // P0_D
  output wire        fb_clk,         // FB_CLK
  output wire        tx_frame,       // TX_FRAME
  output wire [11:0] tx_d,           // P1_D
  // input delays
  input  wire        ref200, ref_rst,
  output wire        delay_ready,
  // sample side, on dclk
  output wire        dclk,
  input  wire        two_async,      // 2R2T
  output reg         stb = 0,
  output reg  [47:0] adc = 0,        // {Q1, I1, Q0, I0}
  input  wire [47:0] dac             // {Q1, I1, Q0, I0}
);
  BUFG b_dclk (.I(data_clk), .O(dclk));
  IDELAYCTRL dctl (.REFCLK(ref200), .RST(ref_rst), .RDY(delay_ready));

  (* ASYNC_REG = "TRUE" *) reg two1 = 0, two = 0;
  always @(posedge dclk) begin two1 <= two_async; two <= two1; end

  // -- rx: delay, capture -------------------------------------------------------------
  wire [12:0] pad = {rx_frame, rx_d};
  wire [12:0] dly;                    // pad through the input delay
  wire [11:0] ri, rq;                 // the pair: I (falling edge), Q (rising edge)
  wire        fi, fq;                 // the frame with each
  genvar n;
  generate for (n = 0; n < 13; n = n + 1) begin : rx_bit
    IDELAYE2 #(.IDELAY_TYPE("FIXED"), .IDELAY_VALUE(RX_IDELAY_TAPS), .DELAY_SRC("IDATAIN"),
      .HIGH_PERFORMANCE_MODE("TRUE"), .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")) d (
      .IDATAIN(pad[n]), .DATAOUT(dly[n]), .DATAIN(1'b0), .C(1'b0), .CE(1'b0), .INC(1'b0), .LD(1'b0),
      .LDPIPEEN(1'b0), .CNTVALUEIN(5'd0), .CNTVALUEOUT(), .CINVCTRL(1'b0), .REGRST(1'b0));
    if (n < 12) begin : data
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) c (.C(dclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(dly[n]),
        .Q1(rq[n]), .Q2(ri[n]));
    end else begin : frame
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) c (.C(dclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(dly[n]),
        .Q1(fq), .Q2(fi));
    end
  end endgenerate

  // -- rx: sample times ---------------------------------------------------------------------
  reg        fq_p = 0;                // the previous pair's fq
  reg        c1 = 0;                  // this pair is channel 1 (2R2T)
  reg [23:0] ch0 = 0;                 // channel 0's {Q, I}, waiting for channel 1
  wire       start = fi && !fq_p;     // this pair begins a frame
  wire       is1   = c1 && !start;
  always @(posedge dclk) begin
    fq_p <= fq;
    c1   <= !is1;
    if (!two) begin
      stb <= 1; adc <= {24'd0, rq, ri};
    end else begin
      stb <= is1;
      if (is1) adc <= {rq, ri, ch0};
      else     ch0 <= {rq, ri};
    end
  end

  // -- tx -------------------------------------------------------------------------------------
  reg [11:0] ti = 0, tq = 0;          // the next pair out
  reg        tf1 = 0, tf2 = 0;        // TX_FRAME with I, with Q
  always @(posedge dclk)
    if (!two || !stb) begin ti <= dac[11:0];  tq <= dac[23:12]; tf1 <= 1; tf2 <= two; end
    else              begin ti <= dac[35:24]; tq <= dac[47:36]; tf1 <= 0; tf2 <= 0; end
  generate for (n = 0; n < 12; n = n + 1) begin : tx_bit
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) o (.C(dclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(ti[n]), .D2(tq[n]),
      .Q(tx_d[n]));
  end endgenerate
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) o_frame (.C(dclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(tf1), .D2(tf2),
    .Q(tx_frame));
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) o_fb (.C(dclk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(1'b1), .D2(1'b0),
    .Q(fb_clk));
endmodule

`default_nettype wire
