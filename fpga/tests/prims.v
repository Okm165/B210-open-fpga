// SPDX-License-Identifier: GPL-3.0-or-later
//
// prims.v - behavioural models of the 7-series cells fpga/rtl instantiates
// (Xilinx's UNISIM sources cannot be redistributed). Port and parameter
// names are exact; behaviour follows UG471 ("7 Series FPGAs SelectIO
// Resources"), synchronous set/reset only (SRTYPE "SYNC").
`timescale 1ns/1ps

// IDDR (UG471 figures 2-5 .. 2-7): when the falling-edge sample appears
// relative to the rising-edge one:
//   OPPOSITE_EDGE        Q1 = D(rise n) at rise n,  Q2 = D(fall n) at fall n
//   SAME_EDGE            Q1 = D(rise n),            Q2 = D(fall n-1), both at rise n
//   SAME_EDGE_PIPELINED  Q1 = D(rise n-1),          Q2 = D(fall n-1), both at rise n
module IDDR #(
  parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
  parameter INIT_Q1 = 1'b0, INIT_Q2 = 1'b0,
  parameter SRTYPE = "SYNC"
) (
  input  C, CE, D, R, S,
  output reg Q1 = INIT_Q1, Q2 = INIT_Q2
);
  reg fall = INIT_Q2, rise = INIT_Q1;
  always @(negedge C) if (CE && !R && !S) begin
    fall <= D;
    if (DDR_CLK_EDGE == "OPPOSITE_EDGE") Q2 <= D;
  end
  always @(posedge C)
    if (R)      begin Q1 <= 0; Q2 <= 0; rise <= 0; end
    else if (S) begin Q1 <= 1; Q2 <= 1; rise <= 1; end
    else if (CE) begin
      rise <= D;
      if (DDR_CLK_EDGE == "SAME_EDGE_PIPELINED") begin Q1 <= rise; Q2 <= fall; end
      else begin
        Q1 <= D;
        if (DDR_CLK_EDGE == "SAME_EDGE") Q2 <= fall;
      end
    end
endmodule

// ODDR: Q carries the D1 sample in the high half of C and the D2 sample in
// the low half. SAME_EDGE takes both at the rising edge; OPPOSITE_EDGE
// takes D2 at the falling edge.
module ODDR #(
  parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
  parameter INIT = 1'b0,
  parameter SRTYPE = "SYNC"
) (
  input  C, CE, D1, D2, R, S,
  output Q
);
  reg q1 = INIT, q2 = INIT;
  always @(posedge C)
    if (R)       begin q1 <= 0; q2 <= 0; end
    else if (S)  begin q1 <= 1; q2 <= 1; end
    else if (CE) begin q1 <= D1; if (DDR_CLK_EDGE == "SAME_EDGE") q2 <= D2; end
  always @(negedge C)
    if (DDR_CLK_EDGE != "SAME_EDGE" && CE && !R && !S) q2 <= D2;
  assign Q = C ? q1 : q2;
endmodule

// IOBUF: T = 1 releases the pad; O follows the pad.
module IOBUF #(
  parameter integer DRIVE = 12,
  parameter IBUF_LOW_PWR = "TRUE", IOSTANDARD = "DEFAULT", SLEW = "SLOW"
) (
  inout IO,
  input I, T,
  output O
);
  bufif0 (IO, I, T);
  assign O = IO;
endmodule
