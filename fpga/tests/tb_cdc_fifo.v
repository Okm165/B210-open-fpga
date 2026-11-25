// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_cdc_fifo - cdc_fifo between two unrelated clocks, through its ports
// only, so the same bench runs on the RTL and on the synthesised netlist
// (with `define POSTSYN against a yosys netlist, whose parameters are
// fixed at W = 112, AW = 4).
//
// The writer offers a random W-bit entry in random cycles and keeps it
// while w_full; the reader takes in random cycles. Every entry must come
// out once, in order, unchanged (all W bits random, so any bit swapped,
// stuck or taken from the wrong address is a mismatch); r_valid must never
// show an entry not yet written; the FIFO must fill (w_full seen) and drain.
// Halfway through, with the reader held so the FIFO is half full and both
// pointers off zero, w_rst and r_rst are asserted together for 8 cycles of
// the slower clock (both, long enough for each side's reset pointer to cross,
// as the module requires): at the end of it r_valid == 0 and !w_full; the
// entries queued are lost (the reference queue clears), and the first entry
// read after reset is the first written after it.
// FAULT 1: one bit of entry 500 flipped on its way in (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_cdc_fifo;
  parameter W = 112, AW = 4, N = 20000, SEED = 1, FAULT = 0;
  parameter WCLK = 8138, RCLK = 5000;           // half periods, ps: 61.44 and 100 MHz

  reg wclk = 0, rclk = 0;
  always #(WCLK / 1000.0) wclk = ~wclk;
  always #(RCLK / 1000.0) rclk = ~rclk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  reg          w_valid = 0, r_take = 0;
  reg  [W-1:0] w_data = 0;
  wire         w_full, r_valid;
  wire [W-1:0] r_data;
`ifdef POSTSYN
  cdc_fifo dut (
`else
  cdc_fifo #(.W(W), .AW(AW)) dut (
`endif
    .wclk(wclk), .w_rst(rst), .w_valid(w_valid), .w_data(w_data), .w_full(w_full),
    .rclk(rclk), .r_rst(rst), .r_valid(r_valid), .r_data(r_data), .r_take(r_take));

  // the entries, in order
  reg [W-1:0] e [0:N-1];
  integer i, k;
  initial for (i = 0; i < N; i = i + 1)
    for (k = 0; k < W; k = k + 32) e[i][k +: 32] = $random(seed);

  // writer: an entry is written at an edge with w_valid && !w_full
  integer wn = 0, fulls = 0;
  always @(posedge wclk) if (!rst) begin
    if (w_valid && !w_full) wn = wn + 1;
    if (w_full) fulls = fulls + 1;
    w_valid <= wn < N && rnd(4) != 0;
    w_data  <= e[wn < N ? wn : 0] ^ ((FAULT == 1 && wn == 500) << 77);   // FAULT 1: entry 500 corrupted
    if (w_valid && w_full) w_data <= w_data;    // keep the offered entry
  end

  // reader: an entry is taken at an edge with r_take && r_valid
  integer rn = 0, pause = 0, lost = 0;
  reg hold = 0;                                 // reader held, to fill the FIFO before the reset
  always @(posedge rclk) if (!rst) begin
    if (r_take && r_valid) begin
      if (rn >= wn) begin
        errors = errors + 1;
        if (errors < 6) $display("%0t entry %0d read before it was written", $time, rn);
      end
      else if (r_data !== e[rn]) begin
        errors = errors + 1;
        if (errors < 6) $display("%0t entry %0d: %h, expected %h", $time, rn, r_data, e[rn]);
      end
      rn = rn + 1;
    end
    // the reader is faster than the writer, but pauses now and then long
    // enough for the FIFO to fill
    if (pause > 0) pause = pause - 1; else if (rnd(300) == 0) pause = 20 + rnd(100);
    r_take <= pause == 0 && !hold && rnd(3) != 0;
  end

  initial begin
    repeat (5) @(posedge rclk);
    rst = 0;
    // reset mid-traffic: half full, write and read pointers both off zero
    // freeze the reader only with its pointer off a multiple of the depth:
    // a frozen reader at 0 mod depth leaves the writer stopping (full) at
    // 0 mod depth too, and the pattern below could never occur
    while (wn < N / 2 || rn % (1 << AW) == 0 || r_take) @(posedge rclk);
    hold = 1;
    while (!(wn - rn >= (1 << AW) / 2 && wn % (1 << AW) != 0 && rn % (1 << AW) != 0 && !r_take))
      @(posedge rclk);
    #0.3 rst = 1;
    lost = wn - rn; rn = wn;                    // what was queued is gone
    repeat (8) @(posedge wclk);
    @(posedge rclk); #0.3;
    if (r_valid !== 1'b0 || w_full !== 1'b0) begin
      errors = errors + 1;
      $display("%0t after reset: r_valid %b w_full %b, 0 0 expected", $time, r_valid, w_full);
    end
    rst = 0; hold = 0;
    $display("reset with %0d entries queued (write pointer %0d, read pointer %0d)",
             lost, wn % (2 << AW), (rn - lost) % (2 << AW));
    while (rn < N) @(posedge rclk);
    repeat (20) @(posedge rclk);
    if (fulls == 0) begin errors = errors + 1; $display("never full: the full path is untested"); end
    $display("%0d entries through, full in %0d write cycles", rn, fulls);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
  initial begin #50_000_000; $display("RESULT: FAIL (timeout at %0d of %0d)", rn, N); $finish; end
endmodule

`default_nettype wire
