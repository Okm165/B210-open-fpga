// diag_pad.v - pad/clock liveness probe with NO GPIF state machine.
//
// Drives the FX3 slave-FIFO control lines statically so the FX3 must accept
// data on its IN endpoint, and holds the FD bus at a constant.  If the host
// can read 0xA5A5A5A5 back, then IFCLK, the GPIF output pads and the FD
// output path all work in this bitstream, and the fault is in the protocol
// logic or flag handling rather than clocks/pads.
`default_nettype none

module diag_fb20 (
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

   // Deterministic fabric-generated PCLK: 40 MHz reference, divided by
   // fabric FFs, driven out through a plain OBUF.  No MMCM, no clock spine
   // to the pad.  Proves whether a toggling IFCLK is all the FX3 needs.
   wire locked = 1'b1;
   wire clk40;
   IBUFDS ibufds_ref (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk40));
   reg div = 1'b0;
   always @(posedge clk40) div <= ~div;
   assign IFCLK = div;
   wire bus_clk = clk40;

   // Static slave-FIFO master: SLCS and SLWR asserted, address = control IN
   // FIFO, FD = constant, PKTEND asserted every cycle to end the packet.
   assign GPIF_CTL0  = 1'b0;   // SLCS  (active low)
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE  (not reading)
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted: pop OUT FIFO
   assign GPIF_CTL7  = 1'b0;   // PKTEND (active low)
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1] = 0
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] = 0 -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = ~locked;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
