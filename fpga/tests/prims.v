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

// BUFG, IBUFDS: wires.
module BUFG (input I, output O); assign O = I; endmodule
module IBUFDS #(parameter DIFF_TERM = "FALSE", IOSTANDARD = "DEFAULT") (input I, IB, output O);
  assign O = I;
endmodule

// MMCME2_ADV: the output clocks its parameters define, from CLKIN1's period
// (not measured: CLKIN1_PERIOD is trusted), LOCKED 64 input cycles after
// RST falls. VCO period = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
// CLKOUTn period = VCO period * its divide; CLKOUT2 shifted by its phase.
// Only the outputs the designs here use are modelled.
module MMCME2_ADV #(
  parameter BANDWIDTH = "OPTIMIZED", COMPENSATION = "ZHOLD", STARTUP_WAIT = "FALSE",
  parameter real CLKIN1_PERIOD = 10.0, CLKFBOUT_MULT_F = 5.0, CLKOUT0_DIVIDE_F = 1.0,
  parameter real CLKOUT2_PHASE = 0.0, CLKFBOUT_PHASE = 0.0, CLKOUT0_PHASE = 0.0, CLKOUT1_PHASE = 0.0,
  parameter real CLKOUT0_DUTY_CYCLE = 0.5, CLKOUT1_DUTY_CYCLE = 0.5, CLKOUT2_DUTY_CYCLE = 0.5, REF_JITTER1 = 0.01,
  parameter integer DIVCLK_DIVIDE = 1, CLKOUT1_DIVIDE = 1, CLKOUT2_DIVIDE = 1, CLKOUT3_DIVIDE = 1,
  parameter CLKOUT4_CASCADE = "FALSE"
) (
  input CLKIN1, CLKIN2, CLKINSEL, CLKFBIN, RST, PWRDWN, DCLK, DEN, DWE, PSCLK, PSEN, PSINCDEC,
  input [6:0] DADDR, input [15:0] DI,
  output CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
  output CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
  output [15:0] DO, output DRDY, PSDONE, LOCKED, CLKFBSTOPPED, CLKINSTOPPED
);
  real vco, p0, p1, p2;
  initial begin
    vco = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    p0 = vco * CLKOUT0_DIVIDE_F; p1 = vco * CLKOUT1_DIVIDE; p2 = vco * CLKOUT2_DIVIDE;
  end
  reg c0 = 0, c1 = 0, c2 = 0, lock = 0;
  integer n = 0;
  always @(posedge CLKIN1 or posedge RST) if (RST) begin n = 0; lock <= 0; end else if (n < 64) n = n + 1; else lock <= 1;
  always begin wait (lock); #(p0 / 2) c0 = lock && !c0; end
  always begin wait (lock); #(p1 / 2) c1 = lock && !c1; end
  always begin wait (lock); #(p2 * CLKOUT2_PHASE / 360.0); while (lock) begin #(p2 / 2) c2 = !c2; end c2 = 0; end
  assign {CLKOUT0, CLKOUT1, CLKOUT2, LOCKED} = {c0, c1, c2, lock};
  assign {CLKOUT0B, CLKOUT1B, CLKOUT2B} = ~{c0, c1, c2};
  assign {CLKFBOUT, CLKFBOUTB, CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = 7'b0100000;
  assign {DO, DRDY, PSDONE, CLKFBSTOPPED, CLKINSTOPPED} = 0;
endmodule
