// SPDX-License-Identifier: GPL-3.0-or-later
//
// fx3_pads - the FPGA side of the FX3 GPIF II bus, every signal registered
// in its I/O block.
//
// The FX3 samples and drives the bus on the clock the FPGA forwards (IFCLK).
// Its timing is only fixed if the last and first register of every bus
// signal sits in the I/O block next to the pad: then the pad-to-register
// delay is the same in every build. nextpnr never moves a fabric flip-flop
// into an I/O block, so the I/O-block registers are instantiated here:
//
//   in   IDDR, Q1 only   = rising-edge register with clock enable
//   out  ODDR, D1 == D2  = rising-edge register
//   T    ODDR, D1 == D2  = tristate register (T = 1 is high impedance)
//
// Interface: every *_n input is the value the pad shall carry from the next
// rising clk edge on; every *_q output is the value the pad carried at the
// last rising edge. The bus is therefore 1 cycle from logic to pad and 1
// cycle from pad to logic, in every build.
//
// Power-up (INIT): strobes high (inactive), address 0, data lines driven
// to 0 by the FPGA: the bus at rest, as in the measured v1 design (with
// SLOE high the FX3 never drives the data lines).
//
// Measured on this board (docs/STATUS.md, "Board interfaces"): with these
// registers the bus works for an IFCLK lag of 37 to 94 MMCM steps; the
// design uses 66.
`default_nettype none

module fx3_pads (
  input  wire        clk,          // bus clock, 100 MHz, the clock IFCLK is forwarded from
  // pads
  inout  wire [31:0] d,            // GPIF_D
  output wire        slwr, slrd, sloe, pktend,   // active low
  output wire [1:0]  addr,         // thread select A1:A0
  input  wire        flag_ready,   // FLAG A: current thread's DMA buffer ready
  input  wire        flag_wmark,   // FLAG B: current thread above its watermark
  // logic side
  input  wire        slwr_n, slrd_n, sloe_n, pktend_n,  // next pad values (active low)
  input  wire [1:0]  addr_n,
  input  wire [31:0] d_n,          // data to drive while sloe_n is high (FPGA writes)
  input  wire        d_ce,         // capture the data pads at the next edge
  output wire [31:0] d_q,          // data captured (FPGA reads)
  output wire        ready_q, wmark_q
);
  // One output register at a pad: an ODDR with both halves equal.
  `define FX3_OREG(name, init, dn, q) \
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(init), .SRTYPE("SYNC")) name \
      (.C(clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(dn), .D2(dn), .Q(q));

  `FX3_OREG(o_slwr,   1'b1, slwr_n,    slwr)
  `FX3_OREG(o_slrd,   1'b1, slrd_n,    slrd)
  `FX3_OREG(o_sloe,   1'b1, sloe_n,    sloe)
  `FX3_OREG(o_pktend, 1'b1, pktend_n,  pktend)
  `FX3_OREG(o_addr0,  1'b0, addr_n[0], addr[0])
  `FX3_OREG(o_addr1,  1'b0, addr_n[1], addr[1])

  IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) i_ready
    (.C(clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(flag_ready), .Q1(ready_q), .Q2());
  IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) i_wmark
    (.C(clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(flag_wmark), .Q1(wmark_q), .Q2());

  // Data: the FPGA drives the pads exactly while SLOE is high (the FX3 does
  // not output). T = 1 releases a pad, so T is the inverse of SLOE; the
  // inversion sits in front of the register (the T register has no usable
  // input inverter). INIT 0 = driving, consistent with SLOE's INIT 1.
  wire       t_n = ~sloe_n;
  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : bit_
      wire pad_i, pad_o, pad_t;
      IOBUF buf_ (.IO(d[i]), .I(pad_o), .T(pad_t), .O(pad_i));
      IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) in_
        (.C(clk), .CE(d_ce), .R(1'b0), .S(1'b0), .D(pad_i), .Q1(d_q[i]), .Q2());
      `FX3_OREG(out_, 1'b0, d_n[i], pad_o)
      `FX3_OREG(tri_, 1'b0, t_n,    pad_t)
    end
  endgenerate
  `undef FX3_OREG
endmodule

`default_nettype wire
