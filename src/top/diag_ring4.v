// diag_ring4.v - IFCLK liveness probe: loopback of a live board clock.
//
// The AD9361 codec clock differential pair is ALWAYS toggling on the board
// (free-running oscillator).  This probe takes one side as a plain IBUF and
// drives it straight out through an OBUFT to IFCLK.  One short fabric net,
// no oscillator, no MMCM, no BUFG/BUFH/GCLK/leaf clock routing at all.
// If GET_COUNTERS then shows PCLK alive, our flow's IO+fabric path works and
// the only broken layer is clock distribution.
`default_nettype none

module diag_ring4 (
   input  wire codec_main_clk_p, input wire codec_main_clk_n,
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8,
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

   // Live board clock straight through the fabric to the FX3 PCLK.
   OBUFT obuf_ifclk (.O(IFCLK), .I(codec_main_clk_p), .T(1'b0));

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;   // SLCS asserted
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE inactive
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted
   assign GPIF_CTL7  = 1'b1;   // PKTEND inactive
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = codec_main_clk_p;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
