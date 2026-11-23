// diag_ring11.v - IFCLK from a REAL in-region clock, vendor-shaped chain.
//
// codec_main_clk_p/n (SRCC pad AA17/AA18, 40 MHz PLL reference, always
// toggling) -> IBUFDS -> BUFG -> GCLK spine -> (crossed clock rows must carry
// CLK_HROW_R_CK_GCLK<n>_ACTIVE; patched into the FASM by build_ring11.sh)
// -> BUFHCE pass-through -> BUFHCLK -> HCLK_IOI leaf -> IOI_OCLK
// -> ODDR (D1=1, D2=0) -> IFCLK pad (AD1).
`default_nettype none
module diag_ring11 (
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
   wire clk, gclk;
   IBUFDS ibufds_ref (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk));
   BUFG   bufg_ref   (.I(clk), .O(gclk));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   oddr_ifclk (.Q(IFCLK), .C(gclk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;
   assign GPIF_CTL1  = 1'b1;
   assign GPIF_CTL2  = 1'b1;
   assign GPIF_CTL3  = 1'b0;
   assign GPIF_CTL7  = 1'b1;
   assign GPIF_CTL11 = 1'b0;
   assign GPIF_CTL12 = 1'b0;
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;
endmodule
