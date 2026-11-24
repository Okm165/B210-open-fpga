// diag_drain_t.v - the missing cell of the clock-source matrix: IFCLK from
// the codec 40 MHz reference (IBUFDS -> BUFG -> OBUFT, no MMCM, no ring)
// with EVERY control pad through an explicit OBUFT(T=0) and the read
// strobes gated by the FX3 ready+watermark flags.
//
// If this drains while diag_ringdrain_t does not, the fabric ring is dead
// but the codec-clock path works and communication is established at
// 40 MHz.  If both stall, the flag-gated read protocol itself is in
// question (then compare with diag_drain40/diag_ringdrainu history).
`default_nettype none

module diag_drain_t (
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

   wire rd = GPIF_CTL4 & GPIF_CTL5;

   OBUFT o_ifclk  (.O(IFCLK),      .I(clk_buf), .T(1'b0));
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
