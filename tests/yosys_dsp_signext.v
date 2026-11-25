// yosys_dsp_signext.v - the smallest designs that show, and do not show, a
// synthesis fault of yosys 0.69 (`synth_xilinx`, DSP48E1 inference).
//
// A signed 17 x 18 bit product has 35 bits.  Each module below registers it
// in a 36-bit register, i.e. sign-extended by one bit, which is ordinary
// Verilog.  Yosys moves that register into the DSP48E1 (MREG).  The DSP
// drives the 35 bits it has; the 36th bit of the register is a copy of bit
// 34 and stays behind as a flip-flop of its own.
//
//   signext_plain   plain register                   synthesized correctly
//   signext_rst     register with synchronous reset  bit 35 is constant 0
//   signext_en      register with clock enable       bit 35 is constant 0
//
// In the two bad cases the flip-flop left behind still reads the multiplier's
// old output net, which has no driver any more once the DSP's P port has been
// reconnected to the register's output; the undriven net is later optimised
// to a constant.  Every negative product then reads as a large positive
// number (-15 becomes 2^35 - 15), while RTL simulation is correct.
//
// This is what put the receive mixer of the earlier ddc_chain on the positive
// rail on hardware (its multiplier, MULT_MACRO, has a reset and an enable,
// and one operand carried a duplicated sign bit), and what src/rtl/dsp/
// hbdec47.v avoids by registering its partial sums at exactly their width.
//
// tests/tb_yosys_dsp_signext.v compares each module with its netlist;
// tests/postsyn.sh runs yosys' own `check` right after the DSP mapping, which
// reports the dangling net.  `just test` requires the two to agree, so the
// same check can be trusted on the whole design.
`default_nettype none

module signext_plain (
  input  wire               clk,
  input  wire               rst,
  input  wire               en,
  input  wire signed [16:0] a,
  input  wire signed [17:0] b,
  output reg  signed [35:0] p
);
  reg signed [16:0] ar;
  reg signed [17:0] br;
  always @(posedge clk) begin
    ar <= a;
    br <= b;
    p  <= ar * br;
  end
endmodule

module signext_rst (
  input  wire               clk,
  input  wire               rst,
  input  wire               en,
  input  wire signed [16:0] a,
  input  wire signed [17:0] b,
  output reg  signed [35:0] p
);
  reg signed [16:0] ar;
  reg signed [17:0] br;
  always @(posedge clk) begin
    ar <= a;
    br <= b;
    if (rst) p <= 36'sd0;
    else     p <= ar * br;
  end
endmodule

module signext_en (
  input  wire               clk,
  input  wire               rst,
  input  wire               en,
  input  wire signed [16:0] a,
  input  wire signed [17:0] b,
  output reg  signed [35:0] p
);
  reg signed [16:0] ar;
  reg signed [17:0] br;
  always @(posedge clk) begin
    ar <= a;
    br <= b;
    if (en) p <= ar * br;
  end
endmodule

`default_nettype wire
