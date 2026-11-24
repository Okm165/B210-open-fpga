//
// Copyright 2015 Ettus Research, A National Instruments Company
// SPDX-License-Identifier: LGPL-3.0
//
// Description: the AD9361 sample port: DDR capture of the receive pins, the
// transmit pins, and the clock network between the capture clock and the
// radio clock.  Derived from Ettus' E31x CMOS IO.
//

module b200_io #(
  // Fixed delay on rx_data/rx_frame, in IDELAYE2 taps of 78 ps (200 MHz
  // reference).  The AD9361 launches receive data on DATA_CLK edges and UHD
  // programs it to delay the data by 15 of its ~0.3 ns steps; the capture
  // clock reaches the IDDRs through a BUFG and arrives late enough to leave
  // only 2 of those steps before the data transition.  This delay moves the
  // data further behind the clock.  Measured with scripts/eyescan.sh on the
  // board (margin in AD9361 steps below UHD's operating point): no delay
  // element 2, tap 0: 5, tap 8: 8, tap 16: 11, tap 24: 13, tap 31: 15.  One
  // step is about 0.24 ns here, so at the 61.44 MHz maximum the clean eye is
  // about 24 steps wide and tap 20 sits in its middle.
  parameter RX_IDELAY_TAPS = 20
) (
  input areset,
  input idelay_refclk,   // 200 MHz
  input idelay_rst,      // high until idelay_refclk has been stable for >= 52 ns
  output idelay_rdy,     // the input delays are calibrated
  input mimo,
  // Baseband sample interface
  output radio_clk,
  output radio_rst,
  output reg [11:0] rx_i0,
  output reg [11:0] rx_q0,
  output reg [11:0] rx_i1,
  output reg [11:0] rx_q1,
  output reg rx_stb,
  input [11:0] tx_i0,
  input [11:0] tx_q0,
  input [11:0] tx_i1,
  input [11:0] tx_q1,
  output reg tx_stb,
  // AD9361 interface
  input rx_clk,
  input rx_frame,
  input [11:0] rx_data,
  output tx_clk,
  output tx_frame,
  output [11:0] tx_data
);

  // Synchronize asynchronous reset and MIMO
  synchronizer #(.STAGES(3), .INITIAL_VAL(1'b1)) sychronizer_radio_rst (
    .clk(radio_clk), .rst(areset), .in(1'b0), .out(radio_rst));

  wire mimo_sync;
  synchronizer synchronizer_mimo (.clk(radio_clk), .rst(radio_rst), .in(mimo), .out(mimo_sync));

  /****************************************************************************
  ** RX Capture Interface
  ****************************************************************************/
  wire rx_clk_bufr; // Capture clock
  wire rx_clk_mimo_bufr;
  
  BUFG bufr_rx_clk (.I(rx_clk), .O(rx_clk_bufr));
  
  // MIMO radio clock: rx_clk / 2 from a regional buffer, phase-aligned to
  // rx_clk_bufr (the capture clock), as in the vendor design.  A fabric
  // toggle flop + BUFG here gives radio_clk an arbitrary phase against
  // rx_clk_bufr and scrambles the I/Q and channel pairing between domains.
  BUFR #(.BUFR_DIVIDE("2"), .SIM_DEVICE("7SERIES")) BUFR_inst (
    .O(rx_clk_mimo_bufr), .CE(1'b1), .CLR(areset), .I(rx_clk));

  // Compatibility: BUFGMUX is the same glitch-free mux as BUFGCTRL with
  // S0=~S, S1=S.  nextpnr places BUFGCTRL directly.
  BUFGCTRL #(
    .INIT_OUT(0),
    .PRESELECT_I0("TRUE"),
    .PRESELECT_I1("FALSE")
  ) BUFGCTRL_inst (
    .O(radio_clk),
    .I0(rx_clk_bufr),
    .I1(rx_clk_mimo_bufr),
    .S0(~mimo_sync),
    .S1(mimo_sync),
    .CE0(1'b1),
    .CE1(1'b1),
    .IGNORE0(1'b0),
    .IGNORE1(1'b0)
  );


  IDELAYCTRL idelayctrl (.REFCLK(idelay_refclk), .RST(idelay_rst), .RDY(idelay_rdy));

  // {rx_frame, rx_data} through the input delay
  wire [12:0] rx_pads = {rx_frame, rx_data};
  wire [12:0] rx_dly;
  genvar n;
  generate
    for (n = 0; n < 13; n = n + 1) begin
      IDELAYE2 #(
        .IDELAY_TYPE("FIXED"), .IDELAY_VALUE(RX_IDELAY_TAPS), .DELAY_SRC("IDATAIN"),
        .HIGH_PERFORMANCE_MODE("TRUE"), .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
      ) idelay (
        .IDATAIN(rx_pads[n]), .DATAOUT(rx_dly[n]), .DATAIN(1'b0),
        .C(1'b0), .CE(1'b0), .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0),
        .CNTVALUEIN(5'd0), .CNTVALUEOUT(), .CINVCTRL(1'b0), .REGRST(1'b0));
    end
  endgenerate

  wire [11:0] rx_i, rx_q;
  generate
    for (n = 0; n < 12; n = n + 1) begin
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr (
        .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
        .D(rx_dly[n]), .Q1(rx_q[n]), .Q2(rx_i[n]));
    end
  endgenerate

  wire rx_frame_rising, rx_frame_falling;
  IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr_frame (
    .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
    .D(rx_dly[12]), .Q1(rx_frame_rising), .Q2(rx_frame_falling));

  // Samples in the capture-clock domain.  In 2R2T mode the two channels
  // arrive on alternate cycles; `pair` holds one complete {ch0, ch1} sample
  // pair and changes when the second channel of the pair has arrived.
  reg [11:0] cap_i0, cap_q0;
  reg [47:0] pair;
  always @(posedge rx_clk_bufr or posedge radio_rst) begin
    if (radio_rst) begin
      rx_stb <= 1'b0;
    end else begin
      if (mimo_sync) begin
        if (rx_frame_rising) begin
          cap_i0 <= rx_i;
          cap_q0 <= rx_q;
        end else begin
          pair   <= {cap_i0, cap_q0, rx_i, rx_q};
        end
        rx_stb  <= ~rx_frame_rising;
      end else begin
        pair    <= {rx_i, rx_q, rx_i, rx_q};
        rx_stb  <= 1'b1;
      end
    end
  end

  // Hand-over to radio_clk.  radio_clk is the capture clock through a second
  // global buffer (1R1T) or through the BUFR /2 (2R2T), so each of its
  // rising edges follows a rising edge of the capture clock by a lag of a
  // few ns that no tool constrains: a register that changes on that edge
  // must not feed the radio.  The pair is therefore presented on the FALLING
  // edge of the capture clock, half a capture period (8.1 ns at 61.44 MHz)
  // away from every radio_clk rising edge.  In 2R2T mode `pair` holds for
  // two capture cycles and radio_clk rises once in them, on either of the
  // two rising edges depending on the phase the divider came up in; both
  // are half a period from the change.  Correct for any lag below half a
  // capture period less the path delay; b210.xdc bounds that path.
  always @(negedge rx_clk_bufr)
    {rx_i0, rx_q0, rx_i1, rx_q1} <= pair;

  /****************************************************************************
  ** TX Output Interface
  ****************************************************************************/
  reg [11:0] tx_i, tx_q;
  reg tx_frame_int = 1'b1;
  generate
    for (n = 0; n < 12; n = n + 1) begin
      ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) oddr (
        .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
        .D1(tx_i[n]), .D2(tx_q[n]), .Q(tx_data[n]));
    end
  endgenerate

  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) oddr_frame (
    .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
    // In SISO mode, TX frame is asserted only on the falling edge
    .D1(tx_frame_int), .D2(tx_frame_int & mimo_sync), .Q(tx_frame));

  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) oddr_clk (
    .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
    .D1(1'b1), .D2(1'b0), .Q(tx_clk));

  reg [11:0] tx_i1_hold, tx_q1_hold;
  always @(posedge rx_clk_bufr or posedge radio_rst) begin
    if (radio_rst) begin
      tx_stb       <= 1'b0;
      tx_frame_int <= 1'b1;
    end else begin
      if (mimo_sync) begin
        tx_stb       <= ~tx_stb;
        tx_frame_int <= tx_stb;
        if (tx_stb) begin
          tx_i       <= tx_i0;
          tx_q       <= tx_q0;
          tx_i1_hold <= tx_i1;
          tx_q1_hold <= tx_q1;
        end else begin
          tx_i       <= tx_i1_hold;
          tx_q       <= tx_q1_hold;
        end
      end else begin
        tx_stb       <= 1'b1;
        tx_frame_int <= 1'b1;
        if ({tx_i0,tx_q0} != 24'd0) begin
          tx_i <= tx_i0;
          tx_q <= tx_q0;
        end else begin
          tx_i <= tx_i1;
          tx_q <= tx_q1;
        end
      end
    end
  end

endmodule
