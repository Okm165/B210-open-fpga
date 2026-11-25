// SPDX-License-Identifier: GPL-3.0-or-later
//
// fx3_pads - the FPGA side of the FX3 GPIF II bus, every signal registered
// in its I/O block.
//
// The FX3 samples and drives the bus on the clock the FPGA forwards (IFCLK).
// Bus timing is fixed only if the last and first register of every signal
// sits in the I/O block next to its pad: then pad-to-register delay is the
// same in every build. nextpnr never moves a fabric flip-flop into an I/O
// block, so the I/O-block registers are instantiated here:
//
//   in   IDDR, Q1 only   = rising-edge register
//   out  ODDR, D1 == D2  = rising-edge register
//   T    ODDR, D1 == D2  = tristate register (T = 1: high impedance)
//
// Interface, in active-high logic (the pads are active low where the FX3
// says so): an input here is what the pad carries in the cycle after the
// next rising edge; an output is what the pad carried at the last rising
// edge. One cycle logic -> pad, one cycle pad -> logic, in every build.
//
// SLCS# is not here: the FPGA is the only master, the top level ties it low.
//
// Power-up (INIT): strobes inactive, address 0, the FPGA drives the data
// lines to 0 while SLOE# is high (the FX3 does not drive then): the bus at
// rest, as in the measured v1 design.
//
// Measured on this board (docs/STATUS.md, "Board interfaces"): with these
// registers the bus works for an IFCLK lag of 37 to 94 MMCM steps; the
// design uses 66.
`default_nettype none

module fx3_pads (
  input  wire        clk,         // bus clock, 100 MHz; IFCLK is forwarded from it
  // pads
  inout  wire [31:0] d,           // DQ[31:0]
  output wire        slwr, slrd, sloe, pktend,   // active low
  output wire [1:0]  a,           // A[1:0]: thread
  input  wire        flaga,       // current thread DMA ready
  input  wire        flagb,       // current thread above its watermark
  // logic side: pad values for the next cycle
  input  wire        wr, rd, oe, pkt_end,
  input  wire [1:0]  thread,
  input  wire        drive,       // the FPGA drives d (only while oe is 0, see fx3_master)
  input  wire [31:0] dout,
  // logic side: pad values sampled at the last edge
  output wire [31:0] din,
  output wire        ready, wmark
);
  // One output register at a pad: an ODDR with both halves equal.
  `define FX3_OREG(name, init, dn, q) \
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(init), .SRTYPE("SYNC")) name \
      (.C(clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(dn), .D2(dn), .Q(q));
  `define FX3_IREG(name, dn, q) \
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) name \
      (.C(clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(dn), .Q1(q), .Q2());

  `FX3_OREG(o_slwr,   1'b1, ~wr,      slwr)
  `FX3_OREG(o_slrd,   1'b1, ~rd,      slrd)
  `FX3_OREG(o_sloe,   1'b1, ~oe,      sloe)
  `FX3_OREG(o_pktend, 1'b1, ~pkt_end, pktend)
  `FX3_OREG(o_a0,     1'b0, thread[0], a[0])
  `FX3_OREG(o_a1,     1'b0, thread[1], a[1])
  `FX3_IREG(i_flaga,  flaga, ready)
  `FX3_IREG(i_flagb,  flagb, wmark)

  // Data: T = ~drive, registered like everything else; INIT 0 = driving.
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : bit_
      wire pad_i, pad_o, pad_t;
      IOBUF buf_ (.IO(d[i]), .I(pad_o), .T(pad_t), .O(pad_i));
      `FX3_IREG(in_,  pad_i, din[i])
      `FX3_OREG(out_, 1'b0, dout[i], pad_o)
      `FX3_OREG(tri_, 1'b0, ~drive,  pad_t)
    end
  endgenerate
  `undef FX3_OREG
  `undef FX3_IREG
endmodule

`default_nettype wire
