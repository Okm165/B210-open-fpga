// diag_ring12.v - IFCLK clocked by OUR ring through the vendor-shaped chain.
//
// 36-inverter ring (BEL-pinned to vendor-empty tiles, ~tens of MHz) -> BUFG
// -> GCLK spine (ACTIVE rows patched by build) -> BUFHCE pass-through ->
// BUFHCLK -> HCLK_IOI leaf -> IOI_OCLK -> ODDR(D1=1,D2=0) -> IFCLK pad.
// No external clock, no IBUFDS, no MMCM: the only clock in the design is ours.
`default_nettype none
module diag_ring12 (
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

   wire gclk;
   BUFG bufg_ring (.I(s[0]), .O(gclk));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   oddr_ifclk (.Q(IFCLK), .C(gclk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   assign GPIF_CTL0=1'b0; assign GPIF_CTL1=1'b1; assign GPIF_CTL2=1'b1;
   assign GPIF_CTL3=1'b0; assign GPIF_CTL7=1'b1; assign GPIF_CTL11=1'b0;
   assign GPIF_CTL12=1'b0; assign GPIF_D=32'bz;
   assign LED_STATUS=1'b0; assign LED_CLK_G=1'b0; assign LED_RX1=1'b0;
endmodule
