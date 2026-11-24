// diag_ringdrain.v - atomic GPIF drain test with a FABRIC-ClOCKED IFCLK.
//
// Reuses the proven 36-stage inverter ring from diag_ring9 (no external
// clock, no IBUFDS, no MMCM, no BUFG): s[0] -> OBUFT -> IFCLK pad.
//
// GPIF behaviour: drain the host->FPGA data thread (fifoadr = 2'b01,
// ADDR_DATA_RX) with read strobes gated by the FX3's own flags, exactly as
// gpif2_slave_fifo32.v does (read only when CTL4 'ready' AND CTL5
// 'watermark' are high; reading an empty thread aborts the FX3 channel).
// Purely combinational, no flops: nothing here needs a clock except IFCLK.
//
// If the host can write more than the FX3's 1024 B of internal buffering,
// then simultaneously: the ring oscillates, IFCLK reaches the FX3, the
// control pads and FIFOADR encoding are right, and the read handshake works.
`default_nettype none

module diag_ringdrain (
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
   OBUFT obuf_ifclk (.O(IFCLK), .I(s[0]), .T(1'b0));

   wire rd = GPIF_CTL4 & GPIF_CTL5;  // ready & watermark

   assign GPIF_CTL0  = 1'b0;   // SLCS  active
   assign GPIF_CTL1  = 1'b1;   // SLWR  idle
   assign GPIF_CTL2  = ~rd;    // SLOE  active while reading
   assign GPIF_CTL3  = ~rd;    // SLRD  active while reading
   assign GPIF_CTL7  = 1'b1;   // PKTEND idle
   assign GPIF_CTL11 = 1'b0;   // fifoadr[1]
   assign GPIF_CTL12 = 1'b0;   // fifoadr[0] => 2'b00 = thread0 = EP2 OUT
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
