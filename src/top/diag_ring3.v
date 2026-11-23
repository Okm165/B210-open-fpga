// diag_ring3.v - truly clock-free IFCLK liveness probe.
//
// IFCLK is driven COMBINATIONALLY from a 3-LUT1 ring oscillator routed as an
// ordinary fabric net into the OBUF (OMUX.D1 pass-through).  No FF, no BUFG,
// no MMCM, no GCLK/BUFH/leaf clock routing anywhere.  If the FX3 GPIF then
// drains, our flow's fabric + OBUF output path work end to end and the only
// broken layer is clock distribution.
`default_nettype none

module diag_ring3 (
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

   // Ring oscillator: 101 explicit LUT1 inverters.  A short 3-LUT ring runs
   // near 1 GHz - far above the FX3 PCLK maximum (~100 MHz) - so this probe
   // uses a long ring to land in the tens of MHz.
   (* dont_touch *) wire [100:0] r;
   genvar i;
   generate
      for (i = 0; i < 100; i = i + 1) begin : g
         LUT1 #(.INIT(2'b01)) inv (.O(r[i]), .I0(r[i+1]));
      end
   endgenerate
   LUT1 #(.INIT(2'b01)) inv_last (.O(r[100]), .I0(r[0]));

   // IFCLK toggles combinationally from the ring - no clock network at all.
   // OBUFT with T tied low forces the toolchain to route the tristate enable
   // to GND (the plain OBUF pass-through leaves T at its VCC default, which
   // tri-states the pad forever).
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
