// diag_ctrl.v - PURELY COMBINATIONAL GPIF speaker (no flip-flops at all).
//
// Question it answers over USB only:
//   Does the FX3 receive our PCLK and sample our bus at all?
//
//   IFCLK  = raw 40 MHz codec clock -> BUFG -> OBUF   (independent of GWE)
//   SLCS   = 0 (active), SLWR = 0 (write every cycle)
//   fifoadr= 01 -> thread 1 = DATA_RX (FX3 -> host data channel)
//   GPIF_D = 0xDEADBEEF constant
//
// No registers anywhere, so this works even if the fabric's global
// write-enable (GWE) never asserts.  If data appears on EP 0x86, the FX3
// has PCLK and samples our pins -> then a dead control path means our
// sequential logic never runs (GWE/reset), not a wiring/clock problem.

`default_nettype none

module diag_ctrl (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   input  wire GPIF_CTL4, input  wire GPIF_CTL5,
   input  wire GPIF_CTL6, input  wire GPIF_CTL8,
   input  wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   inout  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS,
   output wire LED_CLK_G,
   output wire LED_RX1
);

   wire clk_in, clk_buf;
   IBUFDS ibufds (.O(clk_in), .I(codec_main_clk_p), .IB(codec_main_clk_n));
   BUFG   bufg   (.I(clk_in), .O(clk_buf));

   assign IFCLK = clk_buf;      // PCLK to the FX3, no FF in the path

   assign GPIF_CTL0  = 1'b0;    // SLCS active
   assign GPIF_CTL1  = 1'b0;    // SLWR asserted every cycle -> continuous write
   assign GPIF_CTL2  = 1'b1;    // SLOE idle
   assign GPIF_CTL3  = 1'b1;    // SLRD idle
   assign GPIF_CTL7  = 1'b1;    // PKTEND idle
   assign GPIF_CTL11 = 1'b0;    // fifoadr[1:0] = 01 -> thread 1
   assign GPIF_CTL12 = 1'b1;
   assign GPIF_D     = 32'hDEAD_BEEF;

   assign LED_STATUS = 1'b1;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
`default_nettype wire
