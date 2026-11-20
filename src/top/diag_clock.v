// diag_clock.v - a diagnostic image whose ONLY job is to answer, with LEDs,
// whether the 40 MHz reference reaches the FPGA.
//
// This is the no-instrument test for the state-5 / no-ACK investigation
// (dsp-audit 2ay/2az/2ba): the control ACK dies if the MMCM never locks,
// and the MMCM's only input is codec_main_clk_p/n.  This image wires:
//
//   LED_STATUS (B11) : constant on                     = powered + configured
//   LED_CLK_G  (F9)  : ~1.2 Hz blink from the RAW 40 MHz (IBUFDS -> counter)
//                      blink  = 40 MHz reaches the FPGA
//                      dark   = clock absent - root cause confirmed
//   LED_RX1    (E13) : steady from the MMCM `locked`   = MMCM locks
//
// One IBUFDS only (two on the same pair breaks nextpnr - measured).  The
// MMCM parameters are copied verbatim from b200_clk_gen.v.  No FX3
// interface, no DSP, no converter.  Load with scripts/hw_load.py and LOOK.

`default_nettype none

module diag_clock (
   input  wire codec_main_clk_p,
   input  wire codec_main_clk_n,
   output wire LED_CLK_G,     // blinks iff the raw 40 MHz toggles
   output wire LED_RX1,       // on iff the MMCM locks
   output wire LED_STATUS     // constant on
);

   // ---- single IBUFDS: the raw reference, before anything else ----
   wire clk_in1;
   IBUFDS ibufds (
      .I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk_in1));

   // 2^25 x 40 ns = 0.34 s half-period -> ~1.5 Hz blink at 40 MHz.
   // If the clock is absent the counter never advances and the LED is dark.
   reg [24:0] blink_cnt = 25'd0;
   always @(posedge clk_in1) blink_cnt <= blink_cnt + 25'd1;
   assign LED_CLK_G = blink_cnt[24];

   // ---- the real design's MMCM, verbatim parameters ----
   wire clkfbout, clkfbout_buf;
   wire clk40_int, clk100_a, clk100_b;
   wire locked;
   MMCME2_ADV #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKFBOUT_MULT_F(25.000),
      .CLKFBOUT_PHASE(0.000),
      .CLKIN1_PERIOD(25.000),
      .CLKOUT0_DIVIDE_F(25.000),
      .CLKOUT0_DUTY_CYCLE(0.500),
      .CLKOUT0_PHASE(0.000),
      .CLKOUT1_DIVIDE(10),
      .CLKOUT1_DUTY_CYCLE(0.500),
      .CLKOUT1_PHASE(0.000),
      .CLKOUT2_DIVIDE(10),
      .CLKOUT2_DUTY_CYCLE(0.500),
      .CLKOUT2_PHASE(0.000),
      .CLKOUT4_CASCADE("FALSE"),
      .COMPENSATION("ZHOLD"),
      .DIVCLK_DIVIDE(1),
      .REF_JITTER1(0.010),
      .STARTUP_WAIT("FALSE")
   ) mmcm (
      .CLKIN1(clk_in1),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(clkfbout_buf),
      .CLKFBOUT(clkfbout),
      .CLKFBOUTB(),
      .CLKOUT0(clk40_int),
      .CLKOUT0B(),
      .CLKOUT1(clk100_a),
      .CLKOUT1B(),
      .CLKOUT2(clk100_b),
      .CLKOUT2B(),
      .CLKOUT3(),
      .CLKOUT3B(),
      .CLKOUT4(),
      .CLKOUT5(),
      .CLKOUT6(),
      .DI(16'h0), .DADDR(7'h0), .DWE(1'b0), .DEN(1'b0), .DCLK(1'b0), .DRDY(),
      .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
      .LOCKED(locked),
      .CLKFBSTOPPED(), .CLKINSTOPPED(), .PWRDWN(1'b0), .RST(1'b0)
   );
   BUFG bufg_fb (.I(clkfbout), .O(clkfbout_buf));
   assign LED_RX1 = locked;

   assign LED_STATUS = 1'b1;

endmodule
