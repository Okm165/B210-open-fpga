// spartan6_prim_sim.v - licence-clean behavioural models of the Spartan-6
// cells found in the stock B200 FIR Compiler netlists (hbdec1.v / hbdec2.v in
// the UHD tree, fpga/usrp3/top/b200/coregen_dsp/).
//
// Those two netlists are the receive halfband decimators of the stock Ettus
// B200 image.  They are Xilinx-generated gate-level Verilog and cannot be
// redistributed here, but they are plain structural Verilog over nineteen
// cell types, so with these models Icarus simulates the vendor filters
// themselves.  That makes them the golden reference for hbdec1 / hbdec2 in
// src/rtl/dsp/, the synthesizable replacements this design ships (see
// tests/tb_hbdec_netlist.v and `make test-dsp-netlist`).
//
// Nothing in the FPGA design instantiates these cells; this file is used by
// the netlist-reference benches only.
//
// Written from the cell descriptions in UG615 (Spartan-6 libraries guide) and
// the DSP48A1 block diagram and tables of UG389.  No vendor source was used.

`timescale 1ns/1ps

// ------------------------------------------------------------- constants ---

module VCC (output P);
   assign P = 1'b1;
endmodule

module GND (output G);
   assign G = 1'b0;
endmodule

module INV (input I, output O);
   assign O = ~I;
endmodule

// ----------------------------------------------------------- flip-flops ---

module FD #(parameter INIT = 1'b0) (input C, input D, output reg Q);
   initial Q = INIT;
   always @(posedge C) Q <= D;
endmodule

module FDE #(parameter INIT = 1'b0) (input C, input CE, input D, output reg Q);
   initial Q = INIT;
   always @(posedge C) if (CE) Q <= D;
endmodule

module FDR #(parameter INIT = 1'b0) (input C, input D, input R, output reg Q);
   initial Q = INIT;
   always @(posedge C) Q <= R ? 1'b0 : D;
endmodule

module FDRE #(parameter INIT = 1'b0) (input C, input CE, input D, input R, output reg Q);
   initial Q = INIT;
   always @(posedge C)
     if (R) Q <= 1'b0;
     else if (CE) Q <= D;
endmodule

module FDSE #(parameter INIT = 1'b1) (input C, input CE, input D, input S, output reg Q);
   initial Q = INIT;
   always @(posedge C)
     if (S) Q <= 1'b1;
     else if (CE) Q <= D;
endmodule

// ----------------------------------------------------------------- LUTs ---

module LUT1 #(parameter [1:0] INIT = 2'h0) (input I0, output O);
   assign O = INIT[I0];
endmodule

module LUT2 #(parameter [3:0] INIT = 4'h0) (input I0, input I1, output O);
   assign O = INIT[{I1, I0}];
endmodule

module LUT3 #(parameter [7:0] INIT = 8'h00) (input I0, input I1, input I2, output O);
   assign O = INIT[{I2, I1, I0}];
endmodule

module LUT4 #(parameter [15:0] INIT = 16'h0000)
   (input I0, input I1, input I2, input I3, output O);
   assign O = INIT[{I3, I2, I1, I0}];
endmodule

module LUT5 #(parameter [31:0] INIT = 32'h00000000)
   (input I0, input I1, input I2, input I3, input I4, output O);
   assign O = INIT[{I4, I3, I2, I1, I0}];
endmodule

// ---------------------------------------------------------- carry chain ---

module MUXCY (input CI, input DI, input S, output O);
   assign O = S ? CI : DI;
endmodule

module MUXCY_L (input CI, input DI, input S, output LO);
   assign LO = S ? CI : DI;
endmodule

module MUXCY_D (input CI, input DI, input S, output O, output LO);
   assign O  = S ? CI : DI;
   assign LO = O;
endmodule

module XORCY (input CI, input LI, output O);
   assign O = CI ^ LI;
endmodule

// --------------------------------------------------- distributed memory ---

// 16-bit shift register with a dynamic tap: Q is the bit that entered
// {A3..A0}+1 enabled clocks ago, Q15 the last one.
module SRLC16E #(parameter [15:0] INIT = 16'h0000)
   (input A0, input A1, input A2, input A3, input CE, input CLK, input D,
    output Q, output Q15);
   reg [15:0] sr;
   initial sr = INIT;
   always @(posedge CLK) if (CE) sr <= {sr[14:0], D};
   assign Q   = sr[{A3, A2, A1, A0}];
   assign Q15 = sr[15];
endmodule

// 16x1 dual-port RAM: synchronous write at A, asynchronous reads at A (SPO)
// and DPRA (DPO).
module RAM16X1D #(parameter [15:0] INIT = 16'h0000)
   (input A0, input A1, input A2, input A3, input D,
    input DPRA0, input DPRA1, input DPRA2, input DPRA3,
    input WCLK, input WE, output SPO, output DPO);
   reg [15:0] mem;
   initial mem = INIT;
   always @(posedge WCLK) if (WE) mem[{A3, A2, A1, A0}] <= D;
   assign SPO = mem[{A3, A2, A1, A0}];
   assign DPO = mem[{DPRA3, DPRA2, DPRA1, DPRA0}];
endmodule

// ------------------------------------------------------------------ DSP ---

// DSP48A1: 18-bit pre-adder, 18x18 multiplier, 48-bit post-adder.
//
//   B0REG -> pre-adder (D +/- B, OPMODE[4] enables, OPMODE[6] subtracts) -> B1REG
//   A0REG -> A1REG
//   A1 * B1 -> MREG
//   X = OPMODE[1:0]: 0, M, P, {D[11:0], A, B}
//   Z = OPMODE[3:2]: 0, PCIN, P, C
//   P = Z +/- (X + carry)   (OPMODE[7] subtracts) -> PREG
//
// OPMODE passes through its own register; with CARRYINSEL = "OPMODE5" the
// carry is OPMODE[5].  Synchronous resets only (RSTTYPE = "SYNC"), which is
// what the netlists use; an asynchronous RSTTYPE stops the run.
module DSP48A1 #(
   parameter integer A0REG = 0,
   parameter integer A1REG = 1,
   parameter integer B0REG = 0,
   parameter integer B1REG = 1,
   parameter integer CARRYINREG = 1,
   parameter CARRYINSEL = "OPMODE5",
   parameter integer CARRYOUTREG = 1,
   parameter integer CREG = 1,
   parameter integer DREG = 1,
   parameter integer MREG = 1,
   parameter integer OPMODEREG = 1,
   parameter integer PREG = 1,
   parameter RSTTYPE = "SYNC"
) (
   output [17:0] BCOUT,
   output CARRYOUT,
   output CARRYOUTF,
   output [35:0] M,
   output [47:0] P,
   output [47:0] PCOUT,
   input  [17:0] A,
   input  [17:0] B,
   input  [47:0] C,
   input  CARRYIN,
   input  CEA, CEB, CEC, CECARRYIN, CED, CEM, CEOPMODE, CEP,
   input  CLK,
   input  [17:0] D,
   input  [7:0] OPMODE,
   input  [47:0] PCIN,
   input  RSTA, RSTB, RSTC, RSTCARRYIN, RSTD, RSTM, RSTOPMODE, RSTP
);
   initial begin
      if (RSTTYPE != "SYNC") begin
         $display("DSP48A1 model: only RSTTYPE=SYNC is modelled (%m)"); $finish;
      end
      if (CARRYINSEL != "OPMODE5" && CARRYINSEL != "CARRYIN") begin
         $display("DSP48A1 model: bad CARRYINSEL (%m)"); $finish;
      end
   end

   reg [17:0] a0_r = 18'd0, a1_r = 18'd0, b0_r = 18'd0, b1_r = 18'd0, d_r = 18'd0;
   reg [47:0] c_r = 48'd0, p_r = 48'd0;
   reg signed [35:0] m_r = 36'sd0;
   reg [7:0]  op_r = 8'd0;
   reg        cin_r = 1'b0, cout_r = 1'b0;

   wire [7:0]  op   = (OPMODEREG == 0) ? OPMODE : op_r;
   wire [17:0] a0_q = (A0REG == 0) ? A : a0_r;
   wire [17:0] a1_q = (A1REG == 0) ? a0_q : a1_r;
   wire [17:0] b0_q = (B0REG == 0) ? B : b0_r;
   wire [17:0] d_q  = (DREG == 0) ? D : d_r;
   wire [47:0] c_q  = (CREG == 0) ? C : c_r;

   wire [17:0] pre  = op[6] ? (d_q - b0_q) : (d_q + b0_q);
   wire [17:0] b1_d = op[4] ? pre : b0_q;
   wire [17:0] b1_q = (B1REG == 0) ? b1_d : b1_r;

   wire signed [17:0] ma = a1_q;
   wire signed [17:0] mb = b1_q;
   wire signed [35:0] mult = ma * mb;
   wire signed [35:0] m_q  = (MREG == 0) ? mult : m_r;

   wire        cin_d = (CARRYINSEL == "OPMODE5") ? op[5] : CARRYIN;
   wire        cin_q = (CARRYINREG == 0) ? cin_d : cin_r;

   wire [47:0] x_mux = (op[1:0] == 2'b00) ? 48'd0 :
                       (op[1:0] == 2'b01) ? {{12{m_q[35]}}, m_q} :
                       (op[1:0] == 2'b10) ? p_r :
                                            {d_q[11:0], a1_q, b1_q};
   wire [47:0] z_mux = (op[3:2] == 2'b00) ? 48'd0 :
                       (op[3:2] == 2'b01) ? PCIN :
                       (op[3:2] == 2'b10) ? p_r :
                                            c_q;
   wire [48:0] sum   = op[7] ? ({1'b0, z_mux} - ({1'b0, x_mux} + {48'd0, cin_q}))
                             : ({1'b0, z_mux} + {1'b0, x_mux} + {48'd0, cin_q});

   always @(posedge CLK) begin
      if (RSTA) begin
         a0_r <= 18'd0; a1_r <= 18'd0;
      end else if (CEA) begin
         a0_r <= A; a1_r <= a0_q;
      end
      if (RSTB) begin
         b0_r <= 18'd0; b1_r <= 18'd0;
      end else if (CEB) begin
         b0_r <= B; b1_r <= b1_d;
      end
      if (RSTC) c_r <= 48'd0;
      else if (CEC) c_r <= C;
      if (RSTD) d_r <= 18'd0;
      else if (CED) d_r <= D;
      if (RSTM) m_r <= 36'sd0;
      else if (CEM) m_r <= mult;
      if (RSTOPMODE) op_r <= 8'd0;
      else if (CEOPMODE) op_r <= OPMODE;
      if (RSTCARRYIN) begin
         cin_r <= 1'b0; cout_r <= 1'b0;
      end else if (CECARRYIN) begin
         cin_r <= cin_d; cout_r <= sum[48];
      end
      if (RSTP) p_r <= 48'd0;
      else if (CEP) p_r <= sum[47:0];
   end

   assign P         = (PREG == 0) ? sum[47:0] : p_r;
   assign PCOUT     = P;
   assign M         = m_q;
   assign BCOUT     = b1_q;
   assign CARRYOUT  = (CARRYOUTREG == 0) ? sum[48] : cout_r;
   assign CARRYOUTF = CARRYOUT;
endmodule
