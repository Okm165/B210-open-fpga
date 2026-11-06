//
// Copyright 2015 Ettus Research, A National Instruments Company
// SPDX-License-Identifier: LGPL-3.0
//
// Description: E31X IO for CMOS interface
//

module b200_io (
  input areset,
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
  
  // Compatibility: fabric divide-by-2 + BUFG instead of the BUFR regional
  // buffer.  The open xc7 database does not expose a placeable BUFR bel.
  reg rx_clk_div2;
  always @(posedge rx_clk or posedge areset)
    if (areset) rx_clk_div2 <= 1'b0;
    else        rx_clk_div2 <= ~rx_clk_div2;
  BUFG bufg_mimo_div2 (.I(rx_clk_div2), .O(rx_clk_mimo_bufr));

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


  wire [11:0] rx_i, rx_q;
  genvar n;
  generate
    for (n = 0; n < 12; n = n + 1) begin
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr (
        .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
        .D(rx_data[n]), .Q1(rx_q[n]), .Q2(rx_i[n]));
    end
  endgenerate

  wire rx_frame_rising, rx_frame_falling;
  IDDR #(.DDR_CLK_EDGE("SAME_EDGE")) iddr_frame (
    .C(rx_clk_bufr), .CE(1'b1), .R(1'b0), .S(1'b0),
    .D(rx_frame), .Q1(rx_frame_rising), .Q2(rx_frame_falling));

  always @(posedge rx_clk_bufr or posedge radio_rst) begin
    if (radio_rst) begin
      rx_stb <= 1'b0;
    end else begin
      if (mimo_sync) begin
        if (rx_frame_rising) begin
          rx_i0 <= rx_i;
          rx_q0 <= rx_q;
        end else begin
          rx_i1 <= rx_i;
          rx_q1 <= rx_q;
        end
        rx_stb  <= ~rx_frame_rising;
      end else begin
        rx_i0   <= rx_i;
        rx_q0   <= rx_q;
        rx_i1   <= rx_i;
        rx_q1   <= rx_q;
        rx_stb  <= 1'b1;
      end
    end
  end

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
