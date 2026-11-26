// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_gray_sync - gray_sync through its ports only: a source counter in one
// clock domain read in another.
//
// The source steps a binary counter once per sclk, Grey-codes it, and this
// module (dclk) turns it back into binary. The properties that make the
// timestamp trustworthy, checked at every dclk edge:
//   - it never moves backwards;
//   - it never shows a value the source has not reached yet (b <= cnt);
//   - and after the source stops at N, it settles at exactly N.
//
// SKEW delays four Gray bits by 2 ns against the rest - modelling the routing
// spread the Gray code exists to tolerate. A Gray value changes one bit per
// step, so skew must not produce a wrong value: that case is a PASS.
// FAULT 1 sends the *binary* counter (many bits change at once) through the
// same skew: the two-register synchroniser then captures a mix, and the bench
// must catch it. Without this control the bench would not show that it can
// see a mixed read at all, since zero-delay RTL never mixes.
`timescale 1ns/1ps
`default_nettype none

module tb_gray_sync;
  parameter W = 64;             // a multiple of 16
  parameter N = 600;            // source steps
  // The counter starts here, and must fit the counter's width. Chunk k's
  // parity is bit 16k of the count, so the
  // cross-chunk stage is only exercised when the low bit of each chunk above
  // is set: a count near zero makes every parity zero and a broken parity
  // above it invisible (measured: XOR -> AND survives BASE = 0).
  parameter [63:0] BASE = 0;
  parameter SRC = 8138;         // source half period, ps (61.44 MHz)
  parameter DST = 5000;         // destination half period, ps (100 MHz)
  parameter SKEW = 0;           // ps added to bits 0 .. 3
  parameter FAULT = 0;          // 1: send the binary counter through the skew

  reg sclk = 0, dclk = 0;
  always #(SRC / 1000.0) sclk = ~sclk;
  always #(DST / 1000.0) dclk = ~dclk;

  reg [W-1:0] cnt;              // the source's count
  initial cnt = BASE;
  always @(posedge sclk) if (cnt < BASE + N) cnt <= cnt + 1;

  wire [W-1:0] g = FAULT == 1 ? cnt : (cnt ^ (cnt >> 1));
  wire [W-1:0] g_in;
  genvar b;
  generate
    for (b = 0; b < W; b = b + 1) begin : pin
      if (b < 4) assign #(SKEW / 1000.0) g_in[b] = g[b];
      else       assign g_in[b] = g[b];
    end
  endgenerate

  wire [W-1:0] bin;
  gray_sync #(.W(W)) dut (.clk(dclk), .g_in(g_in), .b(bin));

  integer errors = 0;
  reg [W-1:0] last = 0;         // bin at the previous dclk edge
  always @(posedge dclk) begin
    if (bin < last) begin
      errors = errors + 1;
      if (errors < 6) $display("%0t bin moved backwards: %0d -> %0d (source %0d)", $time, last, bin, cnt);
    end
    if (bin > cnt) begin
      errors = errors + 1;
      if (errors < 6) $display("%0t bin %0d ahead of the source %0d", $time, bin, cnt);
    end
    last <= bin;
  end

  initial begin
    wait (cnt == BASE + N);
    repeat (20) @(posedge dclk);
    if (bin !== BASE + N) begin
      errors = errors + 1;
      $display("%0t after %0d steps bin is %0d, not %0d", $time, N, bin, BASE + N);
    end
    $display("%0d steps from %0d, %0d-bit, skew %0s, fault %0d: %0d errors",
             N, BASE, W, SKEW == 0 ? "none" : "on", FAULT, errors);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
  initial begin #5_000_000; $display("RESULT: FAIL (timeout at %0d)", cnt); $finish; end
endmodule

`default_nettype wire
