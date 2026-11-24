// diag_drain.v - atomic GPIF communication test, MMCM-clocked variant.
//
// Purpose: the ONLY thing this design does is consume host->FPGA data
// (USB bulk OUT on EP 0x02).  No state machine, no flags, no FIFOs: the
// slave-FIFO control lines are static and select the DATA_RX thread
// (fifoadr = 2'b01, per src/rtl/gpif2/gpif2_slave_fifo32.v parameters)
// with SLOE+SLRD asserted so the FX3 advances its OUT FIFO pointer every
// IFCLK edge and discards the data.
//
// Observable: host write throughput.  FX3 buffers exactly 1024 B before it
// needs the FPGA to consume; vendor = 8 MB @ 12.8 MB/s, our designs = stall
// at 1024 B.  If this design drains, communication (MMCM, IFCLK, control
// pads, direction, FIFOADR encoding) is proven end-to-end.  Compare against
// diag_drain40.v which removes the MMCM from the clock path entirely.
`default_nettype none

module diag_drain (
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

   wire bus_clk, gpif_clk, locked;
   b200_clk_gen gen (
      .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
      .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(gpif_clk),
      .CLK_OUT3_100_bus(bus_clk),
      .reset(GPIF_CTL9), .locked(locked));

   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   oddr_ifclk (.Q(IFCLK), .C(gpif_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   // Drain the host->FPGA data thread: never idle, always read.
   assign GPIF_CTL0  = 1'b0;   // SLCS  (active low)
   assign GPIF_CTL1  = 1'b1;   // SLWR  idle
   assign GPIF_CTL2  = 1'b0;   // SLOE  active (FX3 drives FD)
   assign GPIF_CTL3  = 1'b0;   // SLRD  active (read a word every IFCLK)
   assign GPIF_CTL7  = 1'b1;   // PKTEND idle
   assign GPIF_CTL11 = 1'b0;   // fifoadr[1]
   assign GPIF_CTL12 = 1'b0;   // fifoadr[0]  => 2'b00 = thread0 = EP2 OUT
   assign GPIF_D     = 32'bz;  // read direction only

   assign LED_STATUS = ~locked;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
