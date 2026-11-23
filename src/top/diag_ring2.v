// diag_ring2.v - IFCLK/PCLK liveness probe with a ring-oscillator clock.
//
// No IBUFDS, no BUFG, no MMCM: three explicit LUT1 inverters form a ring
// oscillator, a divider produces a clean square wave that drives the FX3 PCLK
// (IFCLK), and the GPIF control lines are held so the FX3 pops its OUT FIFO.
// If host writes to the data OUT endpoint drain, PCLK and the GPIF output
// pads work in our bitstream (and the fault is in clock sourcing); if they
// stall at ~1 KB the pad/PCLK path itself is broken.
`default_nettype none

module diag_ring2 (
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

   // Ring oscillator from three explicit LUT1 inverters (INIT=01 -> O=!I0).
   wire r0, r1, r2;
   LUT1 #(.INIT(2'b01)) inv0 (.O(r0), .I0(r2));
   LUT1 #(.INIT(2'b01)) inv1 (.O(r1), .I0(r0));
   LUT1 #(.INIT(2'b01)) inv2 (.O(r2), .I0(r1));

   // Divide by 4 for a clean 50% duty square wave to the FX3.
   reg [1:0] div = 2'd0;
   always @(posedge r0) div <= div + 2'd1;

   assign IFCLK = div[1];

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;   // SLCS asserted
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE inactive
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted
   assign GPIF_CTL7  = 1'b1;   // PKTEND inactive
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = div[1];
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
