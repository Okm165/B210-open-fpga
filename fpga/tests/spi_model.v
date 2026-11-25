// SPDX-License-Identifier: GPL-3.0-or-later
//
// spi_model.v - the board's two SPI devices as their pins see them, each
// checking its data-sheet timing on every edge (errors counted, the first
// few printed). Time in ns.
//
// ad9361_spi_model (AD9361 data sheet Rev. F, p. 6, "SPI timing"; UG-570
// "SPI interface"): SPI mode 1, 24-bit frames: instruction bit 23 W (1
// write, 0 read), bits 22:20 the byte count - 1 (must be 0: one byte),
// bits 17:8 the register address, bits 7:0 the data. SPI_DI is sampled on
// the falling edge; on a read the AD9361 drives SPI_DO from the rising
// edge after the 16th instruction bit, D7 first, each bit undefined from
// 3 ns (tCO min) to 8 ns (tCO max) after its rising edge. Otherwise SPI_DO
// is released (the bench adds a pull-down). Register 0x3FF reads the
// counter floor(t / CNT_NS) mod 256 (for POLL); the others are a 1024-byte
// register file `r`.
// Checked: CS falls and rises with SCLK low; the first rising edge >= tSC
// = 1 ns after CS falls; SCLK period >= tCP = 20 ns, high and low >= tMP =
// 9 ns; SPI_DI stable tS = 2 ns before and tH = 1 ns after each falling
// edge, never X there; exactly 24 rising and 24 falling edges per frame;
// no SCLK edge while CS is high.
//
// adf4001_model (ADF4001 data sheet, "Timing characteristics"): DATA taken
// on CLK rising, MSB first; LE rising loads the 24-bit word, which is
// appended to `log`. Checked: CLK low at either LE edge; DATA setup t1 =
// 10 ns and hold t2 = 10 ns around each rising edge, never X there; CLK
// high t3 and low t4 >= 25 ns; last rising edge to LE high t5 >= 10 ns; LE
// high t6 >= 20 ns between frames; exactly 24 rising edges per frame; no
// CLK edge while LE is high.
`timescale 1ns/1ps
`default_nettype none

module ad9361_spi_model #(
  parameter real CNT_NS = 1000.0
) (
  input  wire ce, sclk, mosi,
  output wire miso
);
  localparam real T_SC = 1, T_CP = 20, T_MP = 9, T_S = 2, T_H = 1, T_CO_MIN = 3, T_CO_MAX = 8;
  reg [7:0]  r [0:1023];
  integer    errors = 0, frames = 0, writes = 0, reads = 0, i;
  initial for (i = 0; i < 1024; i = i + 1) r[i] = 0;
  task err(input [8*48-1:0] what);
    begin errors = errors + 1; if (errors <= 10) $display("%0t ad9361 spi: %0s", $time, what); end
  endtask

  realtime   t_ce = 0, t_rise = -1000, t_fall = -1000, t_mosi = 0;
  integer    rises = 0, falls = 0;
  reg [23:0] sh = 0;
  reg [7:0]  rd = 0;                   // the byte a read returns
  reg        is_read = 0;
  reg        do_q = 0, do_en = 0;
  assign miso = do_en ? do_q : 1'bz;

  reg        in_frame = 0;             // CS fell (a rise from X at power-up is no frame end)
  always @(negedge ce) begin
    if (sclk !== 1'b0) err("CS fell with SCLK not low");
    t_ce = $realtime; rises = 0; falls = 0; in_frame = 1;
  end
  always @(posedge ce) if (in_frame) begin
    in_frame = 0;
    do_en <= 0;
    if (sclk !== 1'b0) err("CS rose with SCLK not low");
    if (rises != 24 || falls != 24) begin
      err("frame not 24 bits"); $display("    %0d rising, %0d falling edges", rises, falls);
    end else if (sh[23]) begin
      if (sh[22:20] != 0) err("multi-byte write");
      r[sh[17:8]] = sh[7:0]; writes = writes + 1;
    end else reads = reads + 1;
    frames = frames + 1;
  end
  always @(posedge sclk) begin
    if (ce !== 1'b0) err("SCLK rose while CS high");
    else begin
      if (rises == 0 && $realtime - t_ce < T_SC) err("CS to first SCLK (tSC)");
      if (rises > 0 && $realtime - t_rise < T_CP) err("SCLK period (tCP)");
      if (falls > 0 && $realtime - t_fall < T_MP) err("SCLK low (tMP)");
      t_rise = $realtime;
      // a read's data byte: rising edge 16 + j drives D(7 - j)
      if (rises >= 16 && is_read) begin
        do_en <= 1;
        do_q <= #(T_CO_MIN) 1'bx;
        do_q <= #(T_CO_MAX) rd[23 - rises];
      end
      rises = rises + 1;
    end
  end
  always @(negedge sclk) if (ce === 1'b0) begin
    if ($realtime - t_rise < T_MP) err("SCLK high (tMP)");
    if ($realtime - t_mosi < T_S) err("SPI_DI setup (tS)");
    if (mosi !== 1'b0 && mosi !== 1'b1) err("SPI_DI undefined at a falling edge");
    t_fall = $realtime;
    sh = {sh[22:0], mosi};
    falls = falls + 1;
    if (falls == 16) begin             // instruction complete
      is_read = !sh[15];
      rd = sh[9:0] == 10'h3FF ? $rtoi($realtime / CNT_NS) : r[sh[9:0]];
      if (sh[14:12] != 0) err("multi-byte read");
    end
    if (falls == 24) is_read = 0;
  end
  always @(mosi) begin
    if (ce === 1'b0 && falls > 0 && $realtime - t_fall < T_H) err("SPI_DI hold (tH)");
    t_mosi = $realtime;
  end
endmodule

module adf4001_model (
  input wire le, clk, data
);
  localparam real T1 = 10, T2 = 10, T3 = 25, T4 = 25, T5 = 10, T6 = 20;
  reg [23:0] log [0:4095];
  integer    errors = 0, n = 0;
  task err(input [8*48-1:0] what);
    begin errors = errors + 1; if (errors <= 10) $display("%0t adf4001: %0s", $time, what); end
  endtask

  realtime   t_le = -1000, t_rise = -1000, t_fall = -1000, t_data = 0;
  integer    rises = 0;
  reg [23:0] sh = 0;
  reg        in_frame = 0;             // LE fell (a rise from X at power-up is no frame end)
  always @(negedge le) begin
    if (clk !== 1'b0) err("LE fell with CLK not low");
    if (n > 0 && $realtime - t_le < T6) err("LE high (t6)");
    rises = 0; in_frame = 1;
  end
  always @(posedge le) if (in_frame) begin
    in_frame = 0;
    t_le = $realtime;
    if (clk !== 1'b0) err("LE rose with CLK not low");
    if ($realtime - t_rise < T5) err("CLK to LE (t5)");
    if (rises != 24) begin err("frame not 24 bits"); $display("    %0d rising edges", rises); end
    else begin log[n] = sh; n = n + 1; end
  end
  always @(posedge clk) begin
    if (le !== 1'b0) err("CLK rose while LE high");
    else begin
      if ($realtime - t_data < T1) err("DATA setup (t1)");
      if (data !== 1'b0 && data !== 1'b1) err("DATA undefined at a rising edge");
      if (rises > 0 && $realtime - t_fall < T4) err("CLK low (t4)");
      t_rise = $realtime;
      sh = {sh[22:0], data};
      rises = rises + 1;
    end
  end
  always @(negedge clk) if (le === 1'b0) begin
    if ($realtime - t_rise < T3) err("CLK high (t3)");
    t_fall = $realtime;
  end
  always @(data) begin
    if (le === 1'b0 && rises > 0 && $realtime - t_rise < T2) err("DATA hold (t2)");
    t_data = $realtime;
  end
endmodule

`default_nettype wire
