// diag_ring5.v - locally-placed IFCLK liveness probe for the old engine.
//
// 51 LUT1 inverters, every one of them hand-placed in the two CLB columns
// adjacent to the IFCLK pad (AD1 / X95Y109), so the oscillator loop and the
// D1 route use only short, fully-documented local hops: LOGIC_OUTS -> IMUX34
// -> OLOGIC D1.  No long lines, no bridge pips, no clock network.
`default_nettype none

module diag_ring5 (
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

   (* dont_touch *) wire [50:0] r;
   genvar i;
   generate
      for (i = 0; i < 50; i = i + 1) begin : g
         LUT1 #(.INIT(2'b01)) inv (.O(r[i]), .I0(r[i+1]));
      end
   endgenerate
   LUT1 #(.INIT(2'b01)) inv_last (.O(r[50]), .I0(r[0]));

   OBUFT obuf_ifclk (.O(IFCLK), .I(r[0]), .T(1'b0));

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;   // SLCS asserted
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE inactive
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted
   assign GPIF_CTL7  = 1'b1;   // PKTEND inactive
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = r[0];
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
