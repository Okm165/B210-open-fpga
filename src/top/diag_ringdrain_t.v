// diag_ringdrain_t.v - ring-clocked drain test with the tristate defect
// explicitly worked around: EVERY output pad is an OBUFT with T tied low.
//
// Rationale: the engine emits a plain OBUF whose tristate input sits at the
// VCC power-up default, i.e. the pad is high-Z forever.  In the vendor
// bitstream the T tie is a real bit (GFAN/GND chain).  All earlier designs
// used plain `assign` outputs and therefore may have driven nothing at all.
// OBUFT-with-T=0 is the engine-legal way to force the output buffer on.
//
// Behaviour identical to diag_ringdrain.v (36-stage ring -> IFCLK, drain the
// ADDR_DATA_RX thread gated by ready+watermark flags).
`default_nettype none

module diag_ringdrain_t (
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
   (* dont_touch *) wire [35:0] s;
   genvar i;
   generate
      for (i = 0; i < 36; i = i + 1) begin : g
         if (i == 35) LUT1 #(.INIT(2'b01)) inv (.O(s[35]), .I0(s[0]));
         else         LUT1 #(.INIT(2'b01)) inv (.O(s[i]),  .I0(s[i+1]));
      end
   endgenerate

   wire rd = GPIF_CTL4 & GPIF_CTL5;

   // every pad through an explicit enabled OBUFT
   OBUFT o_ifclk  (.O(IFCLK),      .I(s[0]), .T(1'b0));
   OBUFT o_slcs   (.O(GPIF_CTL0),  .I(1'b0), .T(1'b0));
   OBUFT o_slwr   (.O(GPIF_CTL1),  .I(1'b1), .T(1'b0));
   OBUFT o_sloe   (.O(GPIF_CTL2),  .I(~rd),  .T(1'b0));
   OBUFT o_slrd   (.O(GPIF_CTL3),  .I(~rd),  .T(1'b0));
   OBUFT o_pktend (.O(GPIF_CTL7),  .I(1'b1), .T(1'b0));
   OBUFT o_addr1  (.O(GPIF_CTL11), .I(1'b0), .T(1'b0));
   OBUFT o_addr0  (.O(GPIF_CTL12), .I(1'b1), .T(1'b0));
   OBUFT o_led1   (.O(LED_STATUS), .I(1'b0), .T(1'b0));
   OBUFT o_led2   (.O(LED_CLK_G),  .I(1'b0), .T(1'b0));
   OBUFT o_led3   (.O(LED_RX1),    .I(1'b0), .T(1'b0));
   assign GPIF_D = 32'bz;

endmodule
