// diag_pad.v - pad/clock liveness probe with NO GPIF state machine.
//
// Drives the FX3 slave-FIFO control lines statically so the FX3 must accept
// data on its IN endpoint, and holds the FD bus at a constant.  If the host
// can read 0xA5A5A5A5 back, then IFCLK, the GPIF output pads and the FD
// output path all work in this bitstream, and the fault is in the protocol
// logic or flag handling rather than clocks/pads.
`default_nettype none

module diag_bfh (
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

   wire bus_clk, gpif_clk, locked;
   b200_clk_gen_bfh gen (
      .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
      .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(gpif_clk), .CLK_OUT3_100_bus(bus_clk),
      .reset(GPIF_CTL9), .locked(locked));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   ODDR_IFCLK (.Q(IFCLK), .C(gpif_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

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
