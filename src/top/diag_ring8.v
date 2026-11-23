// diag_ring8.v - IFCLK liveness probe clocked by the FX3's I2C SCL.
//
// GPIF_CTL8 is the FX3's SCL (settings I2C bus) - an FX3-driven pin in the
// SAME clock region as IFCLK, 2 tiles away.  It toggles whenever the host or
// FX3 firmware performs a settings transaction (raw vendor request 0x30/0x31,
// or any UHD operation).  This probe uses SCL as the ODDR clock:
//   SCL pad -> ILOGIC (D bypass) -> LOGIC_OUTS -> IMUX31 -> OCLK -> ODDR C
// All hops are inside the IOI column - no fabric bridge, no clock network.
// During I2C traffic IFCLK toggles -> FX3 PIB sees PCLK edges.
`default_nettype none

module diag_ring8 (
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

   // SCL (FX3-driven) clocks the ODDR directly.
   ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
   ODDR_IFCLK (.Q(IFCLK), .C(GPIF_CTL8), .CE(1'b1), .D1(1'b1), .D2(1'b0),
               .R(1'b0), .S(1'b0));

   // Static GPIF master: pop the OUT FIFO continuously.
   assign GPIF_CTL0  = 1'b0;   // SLCS asserted
   assign GPIF_CTL1  = 1'b1;   // SLWR inactive
   assign GPIF_CTL2  = 1'b1;   // SLOE inactive
   assign GPIF_CTL3  = 1'b0;   // SLRD asserted
   assign GPIF_CTL7  = 1'b1;   // PKTEND inactive
   assign GPIF_CTL11 = 1'b0;   // FIFOADR[1]
   assign GPIF_CTL12 = 1'b0;   // FIFOADR[0] -> data OUT endpoint
   assign GPIF_D     = 32'bz;

   assign LED_STATUS = 1'b0;
   assign LED_CLK_G  = 1'b0;
   assign LED_RX1    = 1'b0;

endmodule
