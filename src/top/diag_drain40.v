// diag_drain40.v - atomic GPIF communication test, MMCM-free variant.
//
// Identical GPIF behaviour to diag_drain.v (drain the host->FPGA data
// thread) but IFCLK comes straight from the 40 MHz codec reference through
// IBUFDS -> BUFG -> OBUFT.  No MMCM, no PLL, no derived clocks anywhere.
//
// If diag_drain stalls at 1024 B and this one drains, the fault is in the
// clock-generation path (MMCM/CMT), not in the GPIF protocol or IO config.
// 40 MHz x 32 bit = 160 MB/s is ample for any RX proof-of-life test.
`default_nettype none

module diag_drain40 (
   input  wire codec_main_clk_p, input wire codec_main_clk_n,
   input  wire GPIF_CTL4, input wire GPIF_CTL5,
   input  wire GPIF_CTL6, input wire GPIF_CTL8,
   input  wire GPIF_CTL9,
   output wire GPIF_CTL0, output wire GPIF_CTL1, output wire GPIF_CTL2,
   output wire GPIF_CTL3, output wire GPIF_CTL7,
   output wire GPIF_CTL11, output wire GPIF_CTL12,
   inout  wire [31:0] GPIF_D,
   output wire IFCLK,
   output wire LED_STATUS, output wire LED_CLK_G, output wire LED_RX1
);

   wire clk_ref, clk_buf;
   IBUFDS ibufds (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk_ref));
   BUFG   bufg   (.I(clk_ref), .O(clk_buf));
   OBUFT  obuft  (.O(IFCLK), .I(clk_buf), .T(1'b0));

   assign GPIF_CTL0  = 1'b0;   // SLCS
   assign GPIF_CTL1  = 1'b1;   // SLWR idle
   assign GPIF_CTL2  = 1'b0;   // SLOE active
   assign GPIF_CTL3  = 1'b0;   // SLRD active
   assign GPIF_CTL7  = 1'b1;   // PKTEND idle
   assign GPIF_CTL11 = 1'b0;   // fifoadr[1]
   assign GPIF_CTL12 = 1'b1;   // fifoadr[0] => 2'b01 = ADDR_DATA_RX
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
