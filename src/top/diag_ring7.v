// diag_ring7.v - IFCLK liveness probe with ZERO fabric clock routing.
//
// codec_main_clk_p (SRCC pad, always toggling) -> BUFIO (in the IOI column,
// auto-placed at its pad's dedicated site) -> IOCLK -> ODDR C (D1/D2 defaults
// = constant toggle) -> IFCLK pad.  No MMCM, no BUFG/BUFH/GCLK/leaf, no
// fabric crossing of any kind.  If the FX3 PIB comes alive (counter 5), the
// IOI-local clocking path works end to end in our flow.
`default_nettype none

module diag_ring7 (
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

   wire ioclk;
   BUFIO bufio_ifclk (.O(ioclk), .I(codec_main_clk_p));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   ODDR_IFCLK (.Q(IFCLK), .C(ioclk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;   // SLCS asserted
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE inactive
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted
   assign GPIF_CTL7  = 1'b1;   // PKTEND inactive
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
