//
// B200 clock generator.  The MMCM settings match the original clk_wiz
// customization: 40 MHz differential input, VCO 1000 MHz, 40/100/100 MHz
// outputs, ZHOLD compensation, active-high reset, locked output.
//
`default_nettype none

module b200_clk_gen_bfh2 (
  input  wire clk_in1_p,
  input  wire clk_in1_n,
  output wire CLK_OUT1_40_int,
  output wire CLK_OUT2_100_gpif,
  output wire CLK_OUT3_100_bus,
  input  wire reset,
  output wire locked
);

  wire clk_in1;
  wire clkfbout;
  wire [2:0] clkout;

  IBUFDS ibufds (
    .O(clk_in1),
    .I(clk_in1_p),
    .IB(clk_in1_n)
  );

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
    .COMPENSATION("INTERNAL"),
    .DIVCLK_DIVIDE(1),
    .REF_JITTER1(0.010),
    .STARTUP_WAIT("FALSE")
  ) mmcm (
    .CLKIN1(clk_in1),
    .CLKIN2(1'b0),
    .CLKINSEL(1'b1),
    .CLKFBIN(clkfbout),
    .CLKFBOUT(clkfbout),
    .CLKFBOUTB(),
    .CLKOUT0(clkout[0]),
    .CLKOUT0B(),
    .CLKOUT1(clkout[1]),
    .CLKOUT1B(),
    .CLKOUT2(clkout[2]),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .DADDR(7'b0),
    .DCLK(1'b0),
    .DEN(1'b0),
    .DI(16'b0),
    .DO(),
    .DRDY(),
    .DWE(1'b0),
    .PSCLK(1'b0),
    .PSEN(1'b0),
    .PSINCDEC(1'b0),
    .PSDONE(),
    .LOCKED(locked),
    .CLKFBSTOPPED(),
    .CLKINSTOPPED(),
    .PWRDWN(1'b0),
    .RST(reset)
  );

  BUFG bufg_40  (.I(clkout[0]), .O(CLK_OUT1_40_int));
  // Regional clock buffer for the GPIF/IFCLK output: the vendor bitstream
  // feeds the IFCLK ODDR leaf from a BUFHCLK line, not from a global GCLK.
  BUFHCE bufh_gpif (.I(clkout[1]), .CE(1'b1), .O(CLK_OUT2_100_gpif));
  BUFG bufg_bus (.I(clkout[2]), .O(CLK_OUT3_100_bus));

endmodule
