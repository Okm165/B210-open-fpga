// xilinx_prim_sim.v — licence-clean behavioural models for the 7-series cells
// this design instantiates directly. Needed because Xilinx's UNISIM sources
// cannot be redistributed, and without models the design cannot be elaborated
// or simulated at all.
//
// Fidelity policy:
//   * connectivity and port/parameter names are exact
//   * BUFG / BUFGCTRL / IBUFDS / IDDR / ODDR / SRLC32E are functional
//   * MMCME2_ADV generates clocks from its parameters, no jitter/phase noise
//   * DSP48E1 is register-accurate for the arithmetic modes (pre-adder,
//     multiplier, X/Y/Z muxes, 48-bit adder); unmodelled modes stop the run
//
// Use with: iverilog -g2005 ... tests/sim/xilinx_prim_sim.v

`timescale 1ns/1ps

// ---------------------------------------------------------------- clocking ---

module BUFG (input I, output O);
   assign O = I;
endmodule

// Glitchless clock mux, per UG472: only the SELECTED clock's edges may drive
// the output.  On a switchover the old clock's edges stop being applied (its
// final high pulse is truncated, which is real mux physics) and the output
// resumes on the new clock's next rising edge.  A plain combinational mux
// would glue two half-cycles together; the silicon never does.
module BUFGCTRL #(
   parameter INIT_OUT = 0,
   parameter PRESELECT_I0 = "FALSE",
   parameter PRESELECT_I1 = "FALSE"
) (
   input  I0, I1,
   input  S0, S1,
   input  CE0, CE1,
   input  IGNORE0, IGNORE1,
   output reg O
);
   wire sel1 = (S1 === 1'b1) && (S0 !== 1'b1);
   wire sel0 = (S0 === 1'b1) && (S1 !== 1'b1);

   initial O = 1'b0;
   always @(posedge I0) if (sel0) O <= 1'b1;
   always @(negedge I0) if (sel0) O <= 1'b0;
   always @(posedge I1) if (sel1) O <= 1'b1;
   always @(negedge I1) if (sel1) O <= 1'b0;
   // both selects asserted or both deasserted: output low (undefined select)
   always @(S0 or S1)
     if (!((S0 === 1'b1) ^ (S1 === 1'b1))) O <= 1'b0;
endmodule

// Regional clock buffer with divider.  The divided output rises on the first
// input edge after CLR is released and every BUFR_DIVIDE input periods after
// that (the 50 % duty cycle of the primitive is modelled for even divides).
module BUFR #(
   parameter BUFR_DIVIDE = "BYPASS",
   parameter SIM_DEVICE  = "7SERIES"
) (input I, input CE, input CLR, output O);
   localparam integer N = (BUFR_DIVIDE == "BYPASS" || BUFR_DIVIDE == "1") ? 1 :
                          (BUFR_DIVIDE == "2") ? 2 : (BUFR_DIVIDE == "3") ? 3 :
                          (BUFR_DIVIDE == "4") ? 4 : (BUFR_DIVIDE == "5") ? 5 :
                          (BUFR_DIVIDE == "6") ? 6 : (BUFR_DIVIDE == "7") ? 7 : 8;
   integer cnt = 0;
   reg     q   = 1'b0;
   always @(posedge I or posedge CLR)
      if (CLR) begin
         q <= 1'b0; cnt <= 0;
      end else if (CE) begin
         if (cnt == 0)          q <= 1'b1;
         else if (cnt == N / 2) q <= 1'b0;
         cnt <= (cnt + 1 >= N) ? 0 : cnt + 1;
      end
   assign O = (N == 1) ? I : q;
endmodule

// Fixed input delay: IDELAY_VALUE taps of 1 / (64 * REFCLK_FREQUENCY).
module IDELAYE2 #(
   parameter IDELAY_TYPE = "FIXED",
   parameter integer IDELAY_VALUE = 0,
   parameter DELAY_SRC = "IDATAIN",
   parameter HIGH_PERFORMANCE_MODE = "FALSE",
   parameter real REFCLK_FREQUENCY = 200.0,
   parameter SIGNAL_PATTERN = "DATA",
   parameter CINVCTRL_SEL = "FALSE",
   parameter PIPE_SEL = "FALSE"
) (
   input  IDATAIN, DATAIN, C, CE, INC, LD, LDPIPEEN, CINVCTRL, REGRST,
   input  [4:0] CNTVALUEIN,
   output [4:0] CNTVALUEOUT,
   output DATAOUT
);
   localparam real TAP_NS = 1000.0 / (64.0 * REFCLK_FREQUENCY);
   reg dly = 1'b0;
   always @(IDATAIN) dly <= #(IDELAY_VALUE * TAP_NS) IDATAIN;
   assign DATAOUT     = dly;
   assign CNTVALUEOUT = IDELAY_VALUE;
endmodule

module IDELAYCTRL (input REFCLK, input RST, output RDY);
   reg rdy = 1'b0;
   always @(posedge REFCLK or posedge RST) rdy <= !RST;
   assign RDY = rdy;
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
   localparam real P3 = VCO * CLKOUT3_DIVIDE;

   reg clk0 = 0, clk1 = 0, clk2 = 0, clk3 = 0, clkfb = 0;
   reg locked_r = 0;

   always #(P0/2.0) clk0 = ~clk0;
   always #(P1/2.0) clk1 = ~clk1;
   always #(P2/2.0) clk2 = ~clk2;
   always #(P3/2.0) clk3 = ~clk3;
   always #(VCO/2.0) clkfb = ~clkfb;

   // LOCKED a fixed number of reference periods after reset release
   initial begin
      locked_r = 0;
      repeat (64) @(posedge CLKIN1);
      if (!RST) locked_r = 1;
   end

   assign CLKOUT0 = clk0;
   assign CLKOUT1 = clk1;
   // CLKOUT2 carries its phase shift (the forwarded bus clock uses it)
   localparam real D2 = P2 * (CLKOUT2_PHASE < 0.0 ? CLKOUT2_PHASE + 360.0 : CLKOUT2_PHASE) / 360.0;
   reg clk2_shifted = 0;
   always @(clk2) clk2_shifted <= #(D2) clk2;
   assign CLKOUT2 = clk2_shifted;
   assign CLKFBOUT = clkfb;
   assign CLKOUT0B = ~clk0;
   assign CLKOUT1B = ~clk1;
   assign CLKOUT2B = ~clk2_shifted;
   assign CLKOUT3 = clk3;
   assign CLKOUT3B = ~clk3;
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
   reg q1 = INIT;      // SAME_EDGE: both halves captured on the rising edge
   reg q2 = INIT;

   // UG471: in SAME_EDGE mode D1 and D2 are BOTH clocked on the rising edge and
   // the output mux selects D1 for the first half of the cycle and D2 for the
   // second.  In OPPOSITE_EDGE mode D1 is captured on the rise and D2 on the
   // fall, which is what the always block below implements.
   always @(posedge C) if (CE && !R && !S) begin
      q1 <= D1;
      q2 <= D2;
   end

   always @(posedge C) begin
      if (R) q <= 1'b0;
      else if (S) q <= 1'b1;
      else if (CE) q <= D1;
   end

   always @(negedge C)
     if (DDR_CLK_EDGE != "SAME_EDGE" && CE && !R && !S) q <= D2;
   else if (DDR_CLK_EDGE == "SAME_EDGE" && CE && !R && !S) q <= D2;

   assign Q = (DDR_CLK_EDGE == "SAME_EDGE") ? (C ? q1 : q2) : q;
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

// Register-accurate DSP48E1 for the arithmetic configurations this design
// uses (written from the block diagram and tables of UG479, no vendor code).
//
// Modelled exactly: the A1/A2, B1/B2, D, AD, C, M and P registers with their
// clock enables and synchronous resets, the registered INMODE / OPMODE /
// ALUMODE / CARRYIN controls, the 25-bit pre-adder (INMODE[3:1]), the
// A1/A2 and B1/B2 selects (INMODE[0], INMODE[4]), the 25x18 multiplier, the
// X/Y/Z multiplexers and the four arithmetic ALU modes of the 48-bit adder.
// The Ettus halfband (add_then_mac) depends on every one of those pipeline
// stages: it presents samples, coefficient and accumulator-load on different
// clocks, so a model without the input registers computes a different filter.
//
// Not modelled, and rejected at elaboration so a bench cannot be silently
// wrong: cascade inputs (A_INPUT/B_INPUT = "CASCADE"), SIMD, pattern detect,
// the logic-unit ALU modes and the non-zero CARRYINSEL sources.  The cascade
// outputs carry the registered values; CARRYOUT and the flags read zero.
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
   initial begin
      if (A_INPUT != "DIRECT" || B_INPUT != "DIRECT") begin
         $display("DSP48E1 model: cascade inputs are not modelled (%m)"); $finish;
      end
      if (USE_SIMD != "ONE48" || USE_PATTERN_DETECT != "NO_PATDET") begin
         $display("DSP48E1 model: SIMD / pattern detect are not modelled (%m)"); $finish;
      end
      if (USE_MULT != "MULTIPLY" && USE_MULT != "NONE") begin
         $display("DSP48E1 model: USE_MULT must be MULTIPLY or NONE (%m)"); $finish;
      end
      if (USE_DPORT != "TRUE" && USE_DPORT != "FALSE") begin
         $display("DSP48E1 model: USE_DPORT must be TRUE or FALSE (%m)"); $finish;
      end
      if (AREG < 0 || AREG > 2 || BREG < 0 || BREG > 2) begin
         $display("DSP48E1 model: AREG/BREG must be 0, 1 or 2 (%m)"); $finish;
      end
      if (IS_CLK_INVERTED != 1'b0 || IS_ALUMODE_INVERTED != 4'b0000 ||
          IS_CARRYIN_INVERTED != 1'b0 || IS_INMODE_INVERTED != 5'b00000 ||
          IS_OPMODE_INVERTED != 7'b0000000) begin
         $display("DSP48E1 model: programmable inversions are not modelled (%m)"); $finish;
      end
   end

   // ---- input registers --------------------------------------------------
   reg [29:0] a1_r = 30'd0, a2_r = 30'd0;
   reg [17:0] b1_r = 18'd0, b2_r = 18'd0;
   reg [24:0] d_r  = 25'd0, ad_r = 25'd0;
   reg [47:0] c_r  = 48'd0;
   reg [4:0]  inmode_r  = 5'd0;
   reg [6:0]  opmode_r  = 7'd0;
   reg [3:0]  alumode_r = 4'd0;
   reg [2:0]  carryinsel_r = 3'd0;
   reg        carryin_r = 1'b0;
   reg signed [42:0] m_r = 43'sd0;
   reg [47:0] p_r = 48'd0;

   // AREG = 1 uses the A2 register only (A1 is bypassed); AREG = 2 uses both.
   wire [29:0] a1_q = (AREG == 2) ? a1_r : A;
   wire [29:0] a2_q = (AREG == 0) ? A : a2_r;
   wire [17:0] b1_q = (BREG == 2) ? b1_r : B;
   wire [17:0] b2_q = (BREG == 0) ? B : b2_r;
   wire [24:0] d_q  = (DREG == 0) ? D : d_r;
   wire [47:0] c_q  = (CREG == 0) ? C : c_r;

   wire [4:0] inmode_q  = (INMODEREG  == 0) ? INMODE  : inmode_r;
   wire [6:0] opmode_q  = (OPMODEREG  == 0) ? OPMODE  : opmode_r;
   wire [3:0] alumode_q = (ALUMODEREG == 0) ? ALUMODE : alumode_r;
   wire [2:0] carryinsel_q = (CARRYINSELREG == 0) ? CARRYINSEL : carryinsel_r;
   wire       carryin_q = (CARRYINREG == 0) ? CARRYIN : carryin_r;

   always @(posedge CLK) begin
      if (RSTA) begin
         a1_r <= 30'd0; a2_r <= 30'd0;
      end else begin
         if (CEA1) a1_r <= A;
         if (CEA2) a2_r <= (AREG == 2) ? a1_r : A;
      end
      if (RSTB) begin
         b1_r <= 18'd0; b2_r <= 18'd0;
      end else begin
         if (CEB1) b1_r <= B;
         if (CEB2) b2_r <= (BREG == 2) ? b1_r : B;
      end
      if (RSTC) c_r <= 48'd0;
      else if (CEC) c_r <= C;
      if (RSTINMODE) inmode_r <= 5'd0;
      else if (CEINMODE) inmode_r <= INMODE;
      if (RSTCTRL) begin
         opmode_r <= 7'd0; carryinsel_r <= 3'd0;
      end else if (CECTRL) begin
         opmode_r <= OPMODE; carryinsel_r <= CARRYINSEL;
      end
      if (RSTALUMODE) alumode_r <= 4'd0;
      else if (CEALUMODE) alumode_r <= ALUMODE;
      if (RSTALLCARRYIN) carryin_r <= 1'b0;
      else if (CECARRYIN) carryin_r <= CARRYIN;
   end

   // ---- pre-adder ----------------------------------------------------------
   // INMODE[0] picks A1 over A2, INMODE[1] zeroes the A operand, INMODE[2]
   // enables D, INMODE[3] subtracts A.  The pre-adder wraps at 25 bits.
   wire [24:0] a_sel = inmode_q[1] ? 25'd0 : (inmode_q[0] ? a1_q[24:0] : a2_q[24:0]);
   wire [24:0] d_sel = inmode_q[2] ? d_q : 25'd0;
   wire [24:0] ad    = inmode_q[3] ? (d_sel - a_sel) : (d_sel + a_sel);

   always @(posedge CLK)
      if (RSTD) begin
         d_r <= 25'd0; ad_r <= 25'd0;
      end else begin
         if (CED)  d_r  <= D;
         if (CEAD) ad_r <= ad;
      end

   wire [24:0] ad_q = (ADREG == 0) ? ad : ad_r;

   // ---- multiplier ---------------------------------------------------------
   wire signed [24:0] mult_a = (USE_DPORT == "TRUE") ? ad_q : a_sel;
   wire signed [17:0] mult_b = inmode_q[4] ? b1_q : b2_q;
   wire signed [42:0] mult   = mult_a * mult_b;

   always @(posedge CLK)
      if (RSTM) m_r <= 43'sd0;
      else if (CEM) m_r <= mult;

   wire signed [42:0] m_q = (MREG == 0) ? mult : m_r;
   wire [47:0] m_ext = {{5{m_q[42]}}, m_q};

   // ---- X / Y / Z multiplexers and the adder -------------------------------
   // X = Y = 01 is the multiplier: its two partial products add up to M.
   wire use_m = (opmode_q[1:0] == 2'b01) && (opmode_q[3:2] == 2'b01);
   wire [47:0] x_mux = (opmode_q[1:0] == 2'b00) ? 48'd0 :
                       (opmode_q[1:0] == 2'b01) ? m_ext :
                       (opmode_q[1:0] == 2'b10) ? p_r :
                                                  {a2_q, b2_q};
   wire [47:0] y_mux = (opmode_q[3:2] == 2'b00) ? 48'd0 :
                       (opmode_q[3:2] == 2'b01) ? 48'd0 :      // carried by x_mux
                       (opmode_q[3:2] == 2'b10) ? {48{1'b1}} :
                                                  c_q;
   wire [47:0] z_mux = (opmode_q[6:4] == 3'b000) ? 48'd0 :
                       (opmode_q[6:4] == 3'b001) ? PCIN :
                       (opmode_q[6:4] == 3'b010) ? p_r :
                       (opmode_q[6:4] == 3'b011) ? c_q :
                       (opmode_q[6:4] == 3'b100) ? p_r :
                       (opmode_q[6:4] == 3'b101) ? {{17{PCIN[47]}}, PCIN[47:17]} :
                                                   {{17{p_r[47]}},  p_r[47:17]};

   wire [47:0] xy  = x_mux + y_mux + {47'd0, carryin_q};
   wire [47:0] alu = (alumode_q == 4'b0000) ? (z_mux + xy) :
                     (alumode_q == 4'b0011) ? (z_mux - xy) :
                     (alumode_q == 4'b0001) ? (~z_mux + xy) :
                                              ~(z_mux + xy);     // 4'b0010

   always @(posedge CLK)
      if (RSTP) p_r <= 48'd0;
      else if (CEP) p_r <= alu;

   // Combinations the model does not implement are a simulation error, not a
   // quiet wrong answer.
   always @(posedge CLK) begin
      if (alumode_q > 4'b0011) begin
         $display("DSP48E1 model: logic-unit ALUMODE %b is not modelled (%m)", alumode_q); $finish;
      end
      if (carryinsel_q !== 3'b000) begin
         $display("DSP48E1 model: CARRYINSEL %b is not modelled (%m)", carryinsel_q); $finish;
      end
      if ((opmode_q[1:0] == 2'b01) != (opmode_q[3:2] == 2'b01)) begin
         $display("DSP48E1 model: OPMODE %b selects half a multiplier (%m)", opmode_q); $finish;
      end
      if (use_m && USE_MULT == "NONE") begin
         $display("DSP48E1 model: OPMODE selects M with USE_MULT=NONE (%m)"); $finish;
      end
      if (opmode_q[6:4] == 3'b111) begin
         $display("DSP48E1 model: OPMODE[6:4]=111 is illegal (%m)"); $finish;
      end
   end

   assign P     = (PREG == 0) ? alu : p_r;
   assign PCOUT = P;
   assign ACOUT = (ACASCREG == AREG) ? a2_q : a1_q;
   assign BCOUT = (BCASCREG == BREG) ? b2_q : b1_q;
   assign CARRYCASCOUT = 1'b0;
   assign CARRYOUT = 4'b0000;
   assign MULTSIGNOUT = 1'b0;
   assign OVERFLOW = 1'b0;
   assign UNDERFLOW = 1'b0;
   assign PATTERNDETECT = 1'b0;
   assign PATTERNBDETECT = 1'b0;
endmodule

// Bidirectional pad buffer: the pad follows I while T is low and is released
// while T is high; O is what the pad carries.
module IOBUF #(
   parameter integer DRIVE = 12,
   parameter IBUF_LOW_PWR = "TRUE",
   parameter IOSTANDARD = "DEFAULT",
   parameter SLEW = "SLOW"
) (
   inout  IO,
   input  I, T,
   output O
);
   bufif0 (IO, I, T);      // T unknown: the pad is unknown
   assign O = IO;
endmodule
