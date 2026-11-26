// SPDX-License-Identifier: GPL-3.0-or-later
//
// spi_master - the SPI master for the board's two serial devices (opcode 3 SPI,
// docs/PROTOCOL.md 4): device 0 the AD9361 (cat_*), device 1 the ADF4001
// reference PLL (pll_*, write only). One frame = 24 bits, MSB first.
//
// A frame is 50 half periods of H bus cycles each (H = HALF0 for the
// AD9361, HALF1 for the ADF4001), numbered h = 0 .. 49:
//
//   h = 0          CS low, SCLK low, MOSI = word[23]
//   h = 2 i + 1    SCLK high (rising edge i at its start), i = 0 .. 23
//   h = 2 i + 2    SCLK low  (falling edge i at its start); MISO is taken
//                  at falling edge i; MOSI moves to word[22 - i] (0 after
//                  the last bit) H/2 cycles into the half
//   h = 49         CS high, SCLK low: a gap of H before `done`
//
// so a frame takes exactly 50 H cycles from `start` to `done` (+1). MOSI
// changing in the middle of the low half keeps it H/2 cycles away from
// either SCLK edge, whichever edge a device samples on:
//   setup before a rising edge H - H/2, before a falling edge 2 H - H/2;
//   hold after a falling edge H/2,  after a rising edge H + H/2   (cycles).
// `rdata` = the last 8 bits taken (the data byte of an AD9361 read), held
// from `done` to the next frame; 0 for the ADF4001, which has no output.
// The deselected device's pins stay idle: CS high, SCLK and MOSI low.
//
// The two devices (UHD 3.15, the software that runs this board in v1):
//   AD9361  SPI mode 1: SCLK idles low, SPI_DO changes tCO = 3 .. 8 ns
//           after a rising edge (AD9361 data sheet Rev. F, p. 6, "SPI
//           timing"), so it is taken at the falling edge, and SPI_DI is
//           sampled on the falling edge (UHD ad9361_ctrl.cpp: mosi_edge =
//           EDGE_FALL, "the edge on which MOSI is valid"). Limits: SCLK
//           period >= 20 ns, high and low >= 9 ns, CS low to the first
//           rising edge >= 1 ns, last falling edge to CS high >= 0, SPI_DI
//           setup 2 ns, hold 1 ns.
//           Rate: v1 ran it at 1 MHz (b200_regs.hpp AD9361_SPI_RATE = 1e6
//           from the 100 MHz bus clock): HALF0 = 100 MHz / (2 x 1 MHz) = 50.
//   ADF4001 data taken on the rising edge, MSB first; LE (pll_ce) high
//           loads the 24-bit shift register into the latch its two low
//           bits select (ADF4001 data sheet, "Timing characteristics":
//           data setup t1 >= 10 ns, hold t2 >= 10 ns, CLK high t3 and low
//           t4 >= 25 ns, last CLK to LE high t5 >= 10 ns, LE high t6 >=
//           20 ns). v1 ran it at 10 kHz, "slow for large time constant on
//           spi lines" (b200_regs.hpp ADF4001_SPI_RATE = 10e3):
//           HALF1 = 100 MHz / (2 x 10 kHz) = 5000.
// Both cases meet every limit with H >= 3 at 100 MHz: CS to the first
// rising edge H cycles, SCLK high and low H cycles each, data setup and
// hold >= H/2 cycles >= 10 ns, last clock edge to CS high >= H cycles, CS
// high between frames >= H cycles. MISO crosses two flip-flops: a frame
// takes it 2 cycles before the falling edge leaves the FPGA, H - 2 cycles
// after the rising edge that launched it, which covers tCO = 8 ns plus the
// board for H >= 3.
//
// start: a one-cycle strobe with dev and word; ignored while a frame runs.
`default_nettype none

module spi_master #(
  parameter integer HALF0 = 50,      // AD9361: bus cycles per half SCLK period (>= 3)
  parameter integer HALF1 = 5000     // ADF4001
) (
  input  wire        clk, rst,
  input  wire        start,
  input  wire        dev,            // 0 AD9361, 1 ADF4001
  input  wire [23:0] word,
  output reg         done = 0,       // one cycle: the frame is over, rdata valid
  output reg  [7:0]  rdata = 0,
  // AD9361
  output reg         cat_ce = 1,
  output reg         cat_sclk = 0,
  output reg         cat_mosi = 0,
  input  wire        cat_miso,
  // ADF4001
  output reg         pll_ce = 1,
  output reg         pll_sclk = 0,
  output reg         pll_mosi = 0
);
  localparam integer HMAX = HALF0 > HALF1 ? HALF0 : HALF1;
  localparam integer CW   = $clog2(HMAX);
  localparam [CW-1:0] LAST0 = HALF0 - 1, LAST1 = HALF1 - 1,          // last cycle of a half
                      MID0 = HALF0 / 2 - 1, MID1 = HALF1 / 2 - 1;     // MOSI moves after it

  reg          busy = 0;
  reg          d = 0;              // the frame's device
  reg [22:0]   sh = 0;             // bits still to go out, next at the top
  reg [7:0]    rx = 0;             // the last 8 bits in
  reg [5:0]    h = 0;              // half period, 0 .. 49
  reg [CW-1:0] cnt = 0;            // cycle within the half
  (* ASYNC_REG = "TRUE" *) reg miso1 = 0, miso2 = 0;
  always @(posedge clk) begin miso1 <= cat_miso; miso2 <= miso1; end

  wire       end_half = cnt == (d ? LAST1 : LAST0);
  wire       mid      = cnt == (d ? MID1 : MID0) && !h[0] && h != 0;   // middle of a low half after a falling edge
  wire [5:0] hn       = h + 1;

  always @(posedge clk) begin
    done <= 0;
    if (rst) begin
      busy <= 0;
      cat_ce <= 1; cat_sclk <= 0; cat_mosi <= 0;
      pll_ce <= 1; pll_sclk <= 0; pll_mosi <= 0;
    end else if (!busy) begin
      if (start) begin                       // h = 0: select, first bit out
        busy <= 1; d <= dev; sh <= word[22:0]; h <= 0; cnt <= 0;
        if (dev) begin pll_ce <= 0; pll_mosi <= word[23]; end
        else     begin cat_ce <= 0; cat_mosi <= word[23]; end
      end
    end else begin
      cnt <= end_half ? {CW{1'b0}} : cnt + 1'b1;
      if (mid) begin                         // the next bit (0 after the last)
        if (d) pll_mosi <= sh[22]; else cat_mosi <= sh[22];
        sh <= {sh[21:0], 1'b0};
      end
      if (end_half) begin
        h <= hn;
        if (hn == 49) begin                  // deselect
          if (d) pll_ce <= 1; else cat_ce <= 1;
        end else if (hn == 50) begin         // the gap is over
          busy <= 0; done <= 1; rdata <= d ? 8'd0 : rx;
        end else begin                       // 1 .. 48: a clock edge
          if (d) pll_sclk <= hn[0]; else cat_sclk <= hn[0];
          if (!hn[0]) rx <= {rx[6:0], miso2};
        end
      end
    end
  end
endmodule

`default_nettype wire
