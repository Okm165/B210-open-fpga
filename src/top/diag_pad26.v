// diag_pad26.v - drive exactly one GPIF data pad from fabric (bit 26).
`default_nettype none
module diag_pad26 (
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
   assign GPIF_D[26] = 1'b1;
   genvar i;
   generate for (i = 0; i < 32; i = i + 1) begin : t
      if (i != 26) assign GPIF_D[i] = 1'bz;
   end endgenerate
   assign GPIF_CTL0=1'b0; assign GPIF_CTL1=1'b1; assign GPIF_CTL2=1'b1;
   assign GPIF_CTL3=1'b0; assign GPIF_CTL7=1'b1; assign GPIF_CTL11=1'b0;
   assign GPIF_CTL12=1'b0;
   assign IFCLK = 1'b0;  // keep the vendor pad path free for the graft later
   assign LED_STATUS=1'b0; assign LED_CLK_G=1'b0; assign LED_RX1=1'b0;
endmodule
