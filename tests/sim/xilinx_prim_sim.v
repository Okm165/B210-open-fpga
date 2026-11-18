// xilinx_prim_sim.v — licence-clean behavioural models for the 7-series cells
// this design instantiates directly. Needed because Xilinx's UNISIM sources
// cannot be redistributed, and without models the design cannot be elaborated
// or simulated at all (see .context/19-build-alignment-audit.md, F9).
//
// Fidelity policy:
//   * connectivity and port/parameter names are exact
//   * BUFG / BUFGCTRL / IBUFDS / IDDR / ODDR / SRLC32E are functional
//   * MMCME2_ADV generates clocks from its parameters, no jitter/phase noise
//   * DSP48E1 is a behavioural multiply-accumulate: good for control-path and
//     integration benches, NOT for numeric DSP verification
//
// Use with: iverilog -g2005 ... tests/sim/xilinx_prim_sim.v

`timescale 1ns/1ps

// ---------------------------------------------------------------- clocking ---

module BUFG (input I, output O);
   assign O = I;
endmodule

module BUFGCTRL #(
   parameter INIT_OUT = 0,
   parameter PRESELECT_I0 = "FALSE",
   parameter PRESELECT_I1 = "FALSE"
) (
   input  I0, I1,
   input  S0, S1,
   input  CE0, CE1,
   input  IGNORE0, IGNORE1,
   output O
);
   assign O = (S1 === 1'b1) ? I1 : I0;
endmodule

module IBUFDS #(
   parameter DIFF_TERM = "FALSE",
   parameter IBUF_LOW_PWR = "TRUE",
   parameter IOSTANDARD = "DEFAULT"
) (
   input  I, IB,
   output O
);
   assign O = I;
endmodule

module MMCME2_ADV #(
   parameter real CLKFBOUT_MULT_F = 5.0,
   parameter real CLKFBOUT_PHASE = 0.0,
   parameter real CLKIN1_PERIOD = 10.0,
   parameter real CLKOUT0_DIVIDE_F = 1.0,
   parameter real CLKOUT0_DUTY_CYCLE = 0.5,
   parameter real CLKOUT0_PHASE = 0.0,
   parameter integer CLKOUT1_DIVIDE = 1,
   parameter real CLKOUT1_DUTY_CYCLE = 0.5,
   parameter real CLKOUT1_PHASE = 0.0,
   parameter integer CLKOUT2_DIVIDE = 1,
   parameter real CLKOUT2_DUTY_CYCLE = 0.5,
   parameter real CLKOUT2_PHASE = 0.0,
   parameter CLKOUT4_CASCADE = "FALSE",
   parameter COMPENSATION = "ZHOLD",
   parameter integer DIVCLK_DIVIDE = 1,
   parameter real REF_JITTER1 = 0.010,
   parameter STARTUP_WAIT = "FALSE",
   parameter BANDWIDTH = "OPTIMIZED",
   parameter integer CLKOUT3_DIVIDE = 1,
   parameter integer CLKOUT4_DIVIDE = 1,
   parameter integer CLKOUT5_DIVIDE = 1,
   parameter integer CLKOUT6_DIVIDE = 1
) (
   input  CLKIN1, CLKIN2, CLKINSEL,
   input  CLKFBIN,
   output CLKFBOUT, CLKFBOUTB,
   output CLKOUT0, CLKOUT0B,
   output CLKOUT1, CLKOUT1B,
   output CLKOUT2, CLKOUT2B,
   output CLKOUT3, CLKOUT3B,
   output CLKOUT4, CLKOUT5, CLKOUT6,
   input  [6:0] DADDR,
   input  DCLK, DEN,
   input  [15:0] DI,
   output [15:0] DO,
   output DRDY,
   input  DWE, PSCLK, PSEN, PSINCDEC,
   output PSDONE, LOCKED, CLKFBSTOPPED, CLKINSTOPPED,
   input  PWRDWN, RST
);
   // VCO period from the input period and the feedback multiplier
   localparam real VCO = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
   localparam real P0 = VCO * CLKOUT0_DIVIDE_F;
   localparam real P1 = VCO * CLKOUT1_DIVIDE;
   localparam real P2 = VCO * CLKOUT2_DIVIDE;

   reg clk0 = 0, clk1 = 0, clk2 = 0, clkfb = 0;
   reg locked_r = 0;

   always #(P0/2.0) clk0 = ~clk0;
   always #(P1/2.0) clk1 = ~clk1;
   always #(P2/2.0) clk2 = ~clk2;
   always #(VCO/2.0) clkfb = ~clkfb;

   // LOCKED a fixed number of reference periods after reset release
   initial begin
      locked_r = 0;
      repeat (64) @(posedge CLKIN1);
      if (!RST) locked_r = 1;
   end

   assign CLKOUT0 = clk0;
   assign CLKOUT1 = clk1;
   assign CLKOUT2 = clk2;
   assign CLKFBOUT = clkfb;
   assign CLKOUT0B = ~clk0;
   assign CLKOUT1B = ~clk1;
   assign CLKOUT2B = ~clk2;
   assign CLKOUT3 = 1'b0;
   assign CLKOUT3B = 1'b0;
   assign CLKOUT4 = 1'b0;
   assign CLKOUT5 = 1'b0;
   assign CLKOUT6 = 1'b0;
   assign CLKFBOUTB = ~clkfb;
   assign LOCKED = locked_r;
   assign CLKFBSTOPPED = 1'b0;
   assign CLKINSTOPPED = 1'b0;
   assign PSDONE = 1'b0;
   assign DRDY = 1'b0;
   assign DO = 16'h0000;
endmodule

// ------------------------------------------------------------ I/O registers ---

// IDDR modelled from UG471 ("7 Series FPGAs SelectIO Resources", figures 2-5
// to 2-7).  The three modes differ exactly in WHEN the falling-edge sample is
// presented relative to the rising-edge sample:
//
//   OPPOSITE_EDGE         Q1 = D(rise n)        Q2 = D(fall n)   [not aligned]
//   SAME_EDGE             Q1 = D(rise n)        Q2 = D(fall n-1) [pair separated
//                                                                by one sample]
//   SAME_EDGE_PIPELINED   Q1 = D(rise n-1)      Q2 = D(fall n-1) [pair aligned,
//                                                                one cycle late]
//
// The separation in SAME_EDGE mode is what makes it unusable for capturing an
// I/Q pair from a DDR bus: the two halves of one sample leave the IOB in
// different clock cycles.
module IDDR #(
   parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
   parameter INIT_Q1 = 1'b0,
   parameter INIT_Q2 = 1'b0,
   parameter SRTYPE = "SYNC"
) (
   input  C, CE, D, R, S,
   output Q1, Q2
);
   reg q1 = INIT_Q1;
   reg q2 = INIT_Q2;
   reg fall = INIT_Q2;      // D sampled on the falling edge
   reg rise_d = INIT_Q1;    // D sampled on the rising edge, one cycle earlier

   always @(negedge C)
     if (CE && !R && !S) fall <= D;

   always @(posedge C) begin
      if (R) begin q1 <= 1'b0; q2 <= 1'b0; rise_d <= 1'b0; end
      else if (S) begin q1 <= 1'b1; q2 <= 1'b1; rise_d <= 1'b1; end
      else if (CE) begin
         rise_d <= D;
         if (DDR_CLK_EDGE == "SAME_EDGE") begin
            q1 <= D;                       // this cycle's rising sample
            q2 <= fall;                    // PREVIOUS cycle's falling sample
         end else if (DDR_CLK_EDGE == "SAME_EDGE_PIPELINED") begin
            q1 <= rise_d;                  // previous cycle's rising sample
            q2 <= fall;                    // previous cycle's falling sample
         end else begin
            q1 <= D;
         end
      end
   end

   always @(negedge C)
     if (DDR_CLK_EDGE == "OPPOSITE_EDGE" && CE && !R && !S) q2 <= D;

   assign Q1 = q1;
   assign Q2 = q2;
endmodule

module ODDR #(
   parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
   parameter INIT = 1'b0,
   parameter SRTYPE = "SYNC"
) (
   input  C, CE, D1, D2, R, S,
   output Q
);
   reg q = INIT;

   always @(posedge C) begin
      if (R) q <= 1'b0;
      else if (S) q <= 1'b1;
      else if (CE) q <= D1;
   end

   always @(negedge C)
     if (DDR_CLK_EDGE != "SAME_EDGE" && CE && !R && !S) q <= D2;
   else if (DDR_CLK_EDGE == "SAME_EDGE" && CE && !R && !S) q <= D2;

   assign Q = q;
endmodule

// -------------------------------------------------------- distributed memory ---

module SRLC32E #(
   parameter [31:0] INIT = 32'h00000000,
   parameter IS_CLK_INVERTED = 1'b0
) (
   input  CLK, CE,
   input  [4:0] A,
   input  D,
   output Q, Q31
);
   reg [31:0] sr;

   integer i;
   initial begin
      for (i = 0; i < 32; i = i + 1)
        sr[i] = INIT[i];
   end

   always @(posedge CLK)
     if (CE) sr <= {sr[30:0], D};

   assign Q   = sr[A];
   assign Q31 = sr[31];
endmodule

// --------------------------------------------------------------------- DSP ---

// Behavioural DSP48E1. Arithmetic is simplified: pre-adder/multiplier/accumulator
// with the OPMODE Z mux; pattern detection, carry cascade and SIMD are not
// modelled. Adequate for integration benches, not for DSP numerics.
module DSP48E1 #(
   parameter integer ACASCREG = 1,
   parameter integer ADREG = 1,
   parameter integer ALUMODEREG = 1,
   parameter integer AREG = 1,
   parameter AUTORESET_PATDET = "NO_RESET",
   parameter AUTORESET_PRIORITY = "RESET",
   parameter A_INPUT = "DIRECT",
   parameter integer BREG = 1,
   parameter integer BCASCREG = 1,
   parameter B_INPUT = "DIRECT",
   parameter integer CARRYINREG = 1,
   parameter integer CARRYINSELREG = 1,
   parameter integer CREG = 1,
   parameter integer DREG = 1,
   parameter integer INMODEREG = 1,
   parameter IS_ALUMODE_INVERTED = 4'b0000,
   parameter IS_CARRYIN_INVERTED = 1'b0,
   parameter IS_CLK_INVERTED = 1'b0,
   parameter IS_INMODE_INVERTED = 5'b00000,
   parameter IS_OPMODE_INVERTED = 7'b0000000,
   parameter [47:0] MASK = 48'h3FFFFFFFFFFF,
   parameter integer MREG = 1,
   parameter integer OPMODEREG = 1,
   parameter [47:0] PATTERN = 48'h000000000000,
   parameter integer PREG = 1,
   parameter SEL_MASK = "MASK",
   parameter SEL_PATTERN = "PATTERN",
   parameter USE_DPORT = "FALSE",
   parameter USE_MULT = "MULTIPLY",
   parameter USE_PATTERN_DETECT = "NO_PATDET",
   parameter USE_SIMD = "ONE48"
) (
   output [29:0] ACOUT,
   output [17:0] BCOUT,
   output CARRYCASCOUT,
   output [3:0] CARRYOUT,
   output MULTSIGNOUT,
   output OVERFLOW,
   output [47:0] P,
   output PATTERNBDETECT,
   output PATTERNDETECT,
   output [47:0] PCOUT,
   output UNDERFLOW,
   input  [29:0] A,
   input  [29:0] ACIN,
   input  [3:0] ALUMODE,
   input  [17:0] B,
   input  [17:0] BCIN,
   input  [47:0] C,
   input  CARRYCASCIN,
   input  CARRYIN,
   input  [2:0] CARRYINSEL,
   input  CEA1, CEA2, CEAD, CEALUMODE,
   input  CEB1, CEB2, CEC, CECARRYIN,
   input  CECTRL, CED, CEINMODE, CEM, CEP,
   input  CLK,
   input  [24:0] D,
   input  [4:0] INMODE,
   input  MULTSIGNIN,
   input  [6:0] OPMODE,
   input  [47:0] PCIN,
   input  RSTA, RSTALLCARRYIN, RSTALUMODE,
   input  RSTB, RSTC, RSTCTRL, RSTD, RSTINMODE, RSTM, RSTP
);
   wire signed [24:0] d_ext = {D[24], D};
   wire signed [24:0] a_ext = {{6{A[29]}}, A[29:0]};

   wire signed [24:0] pre = (INMODE[4] ? (d_ext - a_ext) : (d_ext + a_ext));
   wire signed [24:0] mult_a = INMODE[2] ? pre : (INMODE[1] ? d_ext : a_ext);
   wire signed [17:0] mult_b = B;

   wire signed [47:0] prod = mult_a * mult_b;
   wire signed [47:0] x_mux = INMODE[0] ? 48'sd0 : prod;

   reg signed [47:0] preg = 0;

   always @(posedge CLK)
     if (RSTM | RSTP) preg <= 0;
     else if (CEP) preg <= x_mux + (OPMODE[3] ? C : (OPMODE[2] ? PCIN : 48'sd0));

   assign P = preg;
   assign PCOUT = preg;
   assign ACOUT = A;
   assign BCOUT = B;
   assign CARRYCASCOUT = 1'b0;
   assign CARRYOUT = 4'b0000;
   assign MULTSIGNOUT = 1'b0;
   assign OVERFLOW = 1'b0;
   assign UNDERFLOW = 1'b0;
   assign PATTERNDETECT = 1'b0;
   assign PATTERNBDETECT = 1'b0;
endmodule
