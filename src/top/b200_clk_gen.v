//
// B200 clock generator: the 40 MHz codec main clock into one MMCM.
// VCO = 40 MHz x 30 = 1200 MHz; bus clock = VCO / BUS_DIVIDE (12 -> 100 MHz).  ZHOLD compensation through a BUFG in the
// feedback path, active-high reset, locked output.  CLKOUT3 = VCO / 6 is the
// 200 MHz reference of the IDELAYCTRL.
//
// CLKOUT2 is the bus clock once more, for the clock forwarded to the FX3
// (IFCLK): the same frequency, later than bus_clk by IFCLK_STEPS eighths of
// a VCO period (104 ps each; 8 * BUS_DIVIDE steps are one bus clock period).
// The FX3 times everything against the clock it receives, so this one number
// places the bus's sampling instants on both sides.  CLKOUT0 is unused.
//
// IFCLK_STEPS = 66 at 100 MHz is the centre of the measured window.  With
// the bus's boundary registers in the I/O blocks (gpif2_slave_fifo32.v) the
// bus carries random data intact in both directions for a lag of 37 to 94
// steps (3.85 to 9.79 ns) and fails outside, first on GPIF_D[6]
// (scripts/bus_window.py on src/top/diag_echo.v, board 31B92DD).  That is
// IFCLK leaving 3.1 ns BEFORE the bus clock edge, with 3.0 ns to either end
// of the window.  At 0, the setting of the designs this one derives from,
// the FX3 sees data and clock change together.
//
`default_nettype none

module b200_clk_gen #(
  parameter integer BUS_DIVIDE = 12,
  parameter integer IFCLK_STEPS = 66
) (
  input  wire clk_in1_p,
  input  wire clk_in1_n,
  output wire bus_clk,
  output wire ifclk,
  output wire idelay_refclk,
  input  wire reset,
  output wire locked
);

  wire clk_in1;
  wire clkfbout;
  wire clkfbout_buf;
  wire clkout, clkout_if, clkout200;

  IBUFDS ibufds (
    .O(clk_in1),
    .I(clk_in1_p),
    .IB(clk_in1_n)
  );

  MMCME2_ADV #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(30.000),
    .CLKFBOUT_PHASE(0.000),
    .CLKIN1_PERIOD(25.000),
    .CLKOUT0_DIVIDE_F(30.000),
    .CLKOUT0_DUTY_CYCLE(0.500),
    .CLKOUT0_PHASE(0.000),
    .CLKOUT1_DIVIDE(BUS_DIVIDE),
    .CLKOUT1_DUTY_CYCLE(0.500),
    .CLKOUT1_PHASE(0.000),
    .CLKOUT2_DIVIDE(BUS_DIVIDE),
    .CLKOUT2_DUTY_CYCLE(0.500),
    .CLKOUT2_PHASE(IFCLK_STEPS * 45.0 / BUS_DIVIDE),
    .CLKOUT3_DIVIDE(6),
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
    .CLKOUT0(),
    .CLKOUT0B(),
    .CLKOUT1(clkout),
    .CLKOUT1B(),
    .CLKOUT2(clkout_if),
    .CLKOUT2B(),
    .CLKOUT3(clkout200),
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

  BUFG bufg_fb  (.I(clkfbout), .O(clkfbout_buf));
  BUFG bufg_bus (.I(clkout),   .O(bus_clk));
  BUFG bufg_if  (.I(clkout_if), .O(ifclk));
  BUFG bufg_200 (.I(clkout200), .O(idelay_refclk));

endmodule
