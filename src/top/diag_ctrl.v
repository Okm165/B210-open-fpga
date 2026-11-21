// diag_ctrl.v - FLAG-WATCH diagnostic.
//
// Question: does the FX3's GPIF engine ever CHANGE its output lines
// (CTL4/CTL5 flags, CTL6/CTL8 sideband) after data is queued for it?
//
// Behavior:
//   - drives IFCLK (PCLK for the FX3) at 100 MHz via ODDR  [required!]
//   - LED_STATUS = MMCM locked (constant on when healthy)
//   - LED_CLK_G  = free-running bus_clk blink (clocks alive)
//   - LED_RX1    = blinks ~1.5 Hz iff ANY of CTL4/5/6/8 changed level
//                  within the last ~0.7 s (FX3 is talking on its outputs)
//
// All GPIF outputs idle (high-Z data, strobes idle) so the FX3's flag
// outputs are observed without interference.

`default_nettype none

module diag_ctrl (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   input  wire GPIF_CTL4, input  wire GPIF_CTL5,
   input  wire GPIF_CTL6, input  wire GPIF_CTL8,
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

   wire gpif_clk, locked;
   b200_clk_gen gen (
      .clk_in1_p(codec_main_clk_p), .clk_in1_n(codec_main_clk_n),
      .CLK_OUT1_40_int(), .CLK_OUT2_100_gpif(gpif_clk), .CLK_OUT3_100_bus(),
      .reset(1'b0), .locked(locked));
   wire bus_clk = gpif_clk;

   // Drive the FX3's GPIF clock.  WITHOUT THIS THE GPIF IS CLOCKLESS.
   ODDR #(
      .DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")
   ) ODDR_IFCLK (
      .Q(IFCLK), .C(gpif_clk), .CE(1'b1),
      .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
   );

   // All FPGA GPIF outputs idle (FX3 slave-FIFO idle levels).
   assign GPIF_CTL0  = 1'b0;   // SLCS active (Ettus idle level)
   assign GPIF_CTL1  = 1'b1;   // SLWR idle
   assign GPIF_CTL2  = 1'b1;   // SLOE idle
   assign GPIF_CTL3  = 1'b1;   // SLRD idle
   assign GPIF_CTL7  = 1'b1;   // PKTEND idle
   assign GPIF_CTL11 = 1'b0;   // fifoadr[1] = 0
   assign GPIF_CTL12 = 1'b0;   // fifoadr[0] = 0 (thread 0)
   assign GPIF_D     = 32'hZZZZ_ZZZZ;

   // ---- flag activity watch ----
   wire [3:0] watch = {GPIF_CTL4, GPIF_CTL5, GPIF_CTL6, GPIF_CTL8};
   reg [3:0]  watch_d = 4'h0;
   reg        activity = 1'b0;
   reg [25:0] act_window = 26'd0;

   always @(posedge bus_clk) begin
      watch_d <= watch;
      if (watch != watch_d)
         activity <= 1'b1;
      act_window <= act_window + 26'd1;
      if (&act_window)                 // ~0.67 s window @ 100 MHz
         activity <= 1'b0;
   end

   assign LED_STATUS = locked;
   reg [23:0] blink_cnt = 24'd0;
   always @(posedge bus_clk) blink_cnt <= blink_cnt + 24'd1;
   assign LED_CLK_G = blink_cnt[23];
   assign LED_RX1   = activity;

endmodule
`default_nettype wire
