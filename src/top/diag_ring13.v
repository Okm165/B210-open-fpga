// diag_ring13.v - 4-inverter ring BEL-pinned inside CLBLM_R_X37Y119 (vendor-
// empty), X1 slice. Tap = B6LUT O6 -> LOGIC_OUTS9 (site always-pip), which
// IMUX34 at INT_R_X95Y115 accepts; that IMUX feeds the GPIF_D[26] ODDR's D1
// (bitless always-pip). Graft target of the documented vendor data crossing.
`default_nettype none
module diag_ring13 (
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
   (* dont_touch *) wire [3:0] r;
   LUT1 #(.INIT(2'b01)) i0 (.O(r[0]), .I0(r[1]));  // B6LUT, tap -> OUTS9
   LUT1 #(.INIT(2'b01)) i1 (.O(r[1]), .I0(r[2]));  // C6LUT
   LUT1 #(.INIT(2'b01)) i2 (.O(r[2]), .I0(r[3]));  // D6LUT
   LUT1 #(.INIT(2'b01)) i3 (.O(r[3]), .I0(r[0]));  // A6LUT
   OBUFT obuf_ifclk (.O(IFCLK), .I(r[0]), .T(1'b0)); // engine-legal escape; unused in graft
   assign GPIF_CTL0=1'b0; assign GPIF_CTL1=1'b1; assign GPIF_CTL2=1'b1;
   assign GPIF_CTL3=1'b0; assign GPIF_CTL7=1'b1; assign GPIF_CTL11=1'b0;
   assign GPIF_CTL12=1'b0; assign GPIF_D=32'bz;
   assign LED_STATUS=1'b0; assign LED_CLK_G=1'b0; assign LED_RX1=1'b0;
endmodule
