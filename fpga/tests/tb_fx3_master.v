// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_fx3_master - fx3_pads + fx3_master against the strict FX3 model.
//
// Every word on all four threads is pat(t, seq, j) = {t, seq, j}: word j of
// packet seq on thread t. So any loss, duplicate, reordering, wrong packet
// boundary or flipped bit is a mismatch, and a packet's end must arrive
// exactly at its length.
//
//   host -> FPGA (threads 0, 2): the host commits buffers of random length
//     (1 .. buffer size, weighted to the corners 1..8, size-8..size) after
//     random gaps; the sink (2 buffers deep, drained at random) must receive
//     each buffer word for word with out_last on its final word.
//   FPGA -> host (threads 1, 3): the sources offer packets of random length
//     after random gaps; the host takes each FX3 buffer after random delays
//     and must find exactly one packet in it.
//
// MODE 0 random traffic on all threads, sinks closed now and then; MODE 1
// full-size data buffers both ways with no gaps (duplex streaming); MODE 2
// rx alone and MODE 3 tx alone, no gaps, every other thread's local side
// closed, so the master returns to the same thread back to back (the case
// where a stale READY after a transfer would show). In modes 1..3 the bus
// efficiency (words moved / cycles) must reach EFF_MIN; in mode 0 every
// corner listed under "coverage" must occur, or the run fails as untested.
// FAULT injects a failure the bench must catch (negative controls):
//   1 the FPGA drives D in the cycle the FX3 is still turning off,
//   2 one bit of one host -> FPGA word flipped,
//   3 a short rx packet of 512 words (a multiple of 1024 bytes).
// Read waits, cycle exact: within a read visit, from a strobe to the next
// strobe after a pause, or to SLOE# released, must be exactly PEEK =
// 3 + RD_LAT + MARGIN = 7 cycles (fx3_master's 2 and 2, its stated wait for
// READY after a read), one more after a strobe that leads into the burst
// state (the cycle in which WMARK low is seen). A longer wait costs bus time
// without failing anything else.
// Reset in a read: when thread 0 has a count, once all traffic is through
// the host commits one more full buffer on thread 0 and rst is asserted for
// 8 cycles in the middle of its burst, with SLOE# low on the pad: the
// master must not drive D in the cycle after (the FX3 is still turning
// off), which the model's bus check catches; then the sink is closed.
// The model's latencies are parameters: run with larger ones to measure
// the master's margin. Prints "RESULT: PASS" or "RESULT: FAIL".
`timescale 1ns/1ps
`default_nettype none

module tb_fx3_master;
  parameter SEED = 1, MODE = 0, N = 40, FAULT = 0;
  parameter ADDR_LAT = 2, RD_LAT = 2, WR_LAT = 3, WM_LAT = 1, SWITCH = 100;
  parameter EFF_MIN = 95;   // percent, modes 1 and 2
  localparam DATA = 4096, CTRL = 256;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // -- the design and the model ----------------------------------------------
  wire [31:0] d, dout, din, out_data;
  wire        slwr, slrd, sloe, pktend, flaga, flagb, ready, wmark;
  wire        wr, rd, oe, pkt_end, drive, out_last;
  wire [1:0]  a, thread, out_valid, in_take;
  reg  [1:0]  out_room = 0, in_avail = 0;
  wire [63:0] in_data;
  wire [1:0]  in_last;

  fx3_pads pads (.clk(clk), .d(d), .slwr(slwr), .slrd(slrd), .sloe(sloe), .pktend(pktend),
    .a(a), .flaga(flaga), .flagb(flagb), .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end),
    .thread(thread), .drive(drive), .dout(dout), .din(din), .ready(ready), .wmark(wmark));
  fx3_master #(.DATA(DATA), .CTRL(CTRL)) master (.clk(clk), .rst(rst),
    .wr(wr), .rd(rd), .oe(oe), .pkt_end(pkt_end), .drive(drive), .thread(thread), .dout(dout),
    .din(din), .ready(ready), .wmark(wmark),
    .out_room(out_room), .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
    .in_avail(in_avail), .in_data(in_data), .in_last(in_last), .in_take(in_take));
  wire fpga_drives = !pads.bit_[0].pad_t;
  fx3_model #(.DATA(DATA), .CTRL(CTRL), .ADDR_LAT(ADDR_LAT), .RD_LAT(RD_LAT), .WR_LAT(WR_LAT),
    .WM_LAT(WM_LAT), .SWITCH(SWITCH)) fx3 (.clk(clk), .d(d), .slwr(slwr), .slrd(slrd), .sloe(sloe),
    .pktend(pktend), .a(a), .fpga_drives(fpga_drives), .flaga(flaga), .flagb(flagb));

  // -- test data -------------------------------------------------------------
  integer errors = 0;
  localparam NCOV = 8;
  integer cov [0:NCOV-1];
  integer seed = SEED;
  function integer rnd(input integer m);   // uniform 0 .. m-1
    rnd = ($random(seed) & 32'h7fffffff) % m;
  endfunction
  function [31:0] pat(input integer t, input integer seq, input integer j);
    pat = {t[1:0], seq[13:0], j[15:0]};
  endfunction
  function integer size(input integer t); size = t[1] ? CTRL : DATA; endfunction
  // packets per thread: control threads idle in the streaming modes
  function integer count(input integer t);
    count = MODE == 0 ? N : t[1] ? 0 : MODE == 2 && t == 0 ? 0 : MODE == 3 && t == 1 ? 0 : N;
  endfunction
  function integer gap(input integer dummy);
    gap = MODE != 0 ? 0 : rnd(4) == 0 ? rnd(3000) : rnd(40);
  endfunction

  integer len [0:4*N-1];     // len[t*N + seq]: words in packet seq of thread t
  integer t, s, r, k;
  initial for (t = 0; t < 4; t = t + 1) for (s = 0; s < N; s = s + 1) begin
    r = rnd(4);
    k = MODE != 0 ? size(t) : r == 0 ? size(t) : r == 1 ? 1 + rnd(8) : r == 2 ? size(t) - 1 - rnd(8) : 1 + rnd(size(t));
    if (k < size(t) && k % 256 == 0) k = k - 1;       // the driver's transfer-size rule
    if (FAULT == 3 && t == 1 && s == 2) k = 512;
    len[t*N + s] = k;
  end

  // -- host -> FPGA: host commits buffers; sinks check them -------------------
  integer sent [0:3];
  initial begin sent[0] = 0; sent[2] = 0; end
  task automatic host_out(input integer t);
    integer sq, j, n;
    for (sq = 0; sq < count(t); sq = sq + 1) begin
      repeat (gap(0)) @(posedge clk);
      n = len[t*N + sq];
      for (j = 0; j < n; j = j + 1) fx3.send[t*DATA + j] = pat(t, sq, j);
      if (FAULT == 2 && t == 0 && sq == 3) fx3.send[t*DATA + n/2][7] = !fx3.send[t*DATA + n/2][7];
      sent[t] = sq + 1;
      fx3.host_send(t, n);
    end
  endtask
  initial begin wait (!rst); fork host_out(0); host_out(2); join end

  integer occ [0:1], oseq [0:1], oj [0:1];
  reg     closed [0:1];
  reg     shut = 0;                 // sink 0 closed for good (after the reset stretch)
  integer c;
  initial for (c = 0; c < 2; c = c + 1) begin occ[c] = 0; oseq[c] = 0; oj[c] = 0; closed[c] = 0; end
  always @(posedge clk) for (c = 0; c < 2; c = c + 1) begin
    t = 2 * c;
    if (out_valid[c]) begin
      if (occ[c] == 2 * size(t))         begin errors = errors + 1; $display("%0t sink %0d overflow", $time, c); end
      if (oseq[c] >= sent[t])            begin errors = errors + 1; $display("%0t sink %0d: data never sent", $time, c); end
      else begin
        if (out_data !== pat(t, oseq[c], oj[c])) begin
          errors = errors + 1;
          $display("%0t thread %0d packet %0d word %0d: %h, expected %h", $time, t, oseq[c], oj[c], out_data, pat(t, oseq[c], oj[c]));
        end
        if (oseq[c] < count(t) && out_last !== (oj[c] == len[t*N + oseq[c]] - 1)) begin   // the reset stretch's buffer: no length
          errors = errors + 1;
          $display("%0t thread %0d packet %0d: last at word %0d, length %0d", $time, t, oseq[c], oj[c], len[t*N + oseq[c]]);
        end
      end
      occ[c] = occ[c] + 1;
      if (out_last && oj[c] == 0) cov[7] = cov[7] + 1;
      if (out_last) begin oseq[c] = oseq[c] + 1; oj[c] = 0; end else oj[c] = oj[c] + 1;
    end
    if (occ[c] > 0 && (MODE != 0 || rnd(3) != 0)) occ[c] = occ[c] - 1;   // the sink drains
    if (MODE == 0 && rnd(2000) == 0) closed[c] = !closed[c];             // the sink stops taking now and then
    out_room[c] <= 2 * size(t) - occ[c] >= size(t) && !closed[c] && count(t) > 0 && !(shut && c == 0);
  end

  // -- FPGA -> host: sources offer packets; the host checks each buffer --------
  integer iseq [0:1], ij [0:1], due [0:1];
  initial for (c = 0; c < 2; c = c + 1) begin iseq[c] = 0; ij[c] = 0; due[c] = 0; end
  assign in_data[31:0]  = pat(1, iseq[0], ij[0]);
  assign in_data[63:32] = pat(3, iseq[1], ij[1]);
  assign in_last  = {ij[1] == len[3*N + iseq[1]] - 1, ij[0] == len[1*N + iseq[0]] - 1};
  always @(posedge clk) for (c = 0; c < 2; c = c + 1) begin
    t = 2 * c + 1;
    if (in_take[c]) begin
      if (!in_avail[c]) begin errors = errors + 1; $display("%0t source %0d taken while empty", $time, c); end
      if (in_last[c]) begin iseq[c] = iseq[c] + 1; ij[c] = 0; due[c] = cyc + gap(0); end
      else ij[c] = ij[c] + 1;
    end
    in_avail[c] <= !rst && iseq[c] < count(t) && cyc >= due[c];
  end

  integer got [0:3];
  initial begin got[1] = 0; got[3] = 0; end
  task automatic host_in(input integer t);
    integer sq, j, n;
    for (sq = 0; sq < count(t); sq = sq + 1) begin
      repeat (gap(0)) @(posedge clk);
      fx3.host_recv(t, n);
      if (n != len[t*N + sq]) begin
        errors = errors + 1; $display("%0t thread %0d buffer %0d: %0d words, expected %0d", $time, t, sq, n, len[t*N + sq]);
      end
      for (j = 0; j < n && j < len[t*N + sq]; j = j + 1)
        if (fx3.recv[t*DATA + j] !== pat(t, sq, j)) begin
          errors = errors + 1;
          $display("%0t thread %0d buffer %0d word %0d: %h, expected %h", $time, t, sq, j, fx3.recv[t*DATA + j], pat(t, sq, j));
        end
      got[t] = sq + 1;
    end
  endtask
  initial begin wait (!rst); fork host_in(1); host_in(3); join end

  // -- fault 1: FPGA drives D while the FX3 turns off --------------------------
  initial if (FAULT == 1) begin
    wait (oseq[0] == 1);
    @(posedge sloe); #1;
    force pads.bit_[0].pad_t = 0;
    @(posedge clk); #1;
    release pads.bit_[0].pad_t;
  end

  // -- throughput: words over the bus from the first to the last strobe ---------
  integer words = 0, first = -1, last = 0;
  always @(posedge clk) if (wr || rd) begin
    words = words + 1; last = cyc; if (first < 0) first = cyc;
  end

  // -- read waits: strobe to strobe after a pause, or to SLOE# released -----------
  localparam PEEK = 3 + 2 + 2;      // fx3_master: 3 + RD_LAT + MARGIN
  integer since = 0, gap_exp = 0, peeks = 0;
  reg     oe_d = 0;                 // oe decided in the previous cycle
  always @(posedge clk) begin
    if (!rst) begin
      since = since + 1;
      if ((rd && oe_d && since > 1) || (!oe && oe_d)) begin
        peeks = peeks + 1;
        if (since != gap_exp) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t thread %0d: %0s %0d cycles after the strobe before, %0d expected",
                                    $time, master.t, rd ? "strobe" : "SLOE# released", since, gap_exp);
        end
      end
      if (rd) begin since = 0; gap_exp = PEEK + (master.state_n == 3); end
    end
    oe_d = oe;
  end

  // -- coverage: the corners mode 0 must reach --------------------------------------
  reg [8*40-1:0] cov_name [0:NCOV-1];
  reg [1:0] prev_t = 0;
  initial begin
    for (k = 0; k < NCOV; k = k + 1) cov[k] = 0;
    cov_name[0] = "read starting with WMARK low";
    cov_name[1] = "burst read ended by WMARK";
    cov_name[2] = "single read (PEEK)";
    cov_name[3] = "visit finding READY low";
    cov_name[4] = "same thread visited back to back";
    cov_name[5] = "write of a full buffer (no PKTEND)";
    cov_name[6] = "write ended by PKTEND";
    cov_name[7] = "one-word buffer read";
  end
  always @(posedge clk) begin
    if (master.state == 1 && master.cnt == 0 && ready && !master.t[0] && !wmark) cov[0] = cov[0] + 1;
    if (master.state == 3 && !wmark) cov[1] = cov[1] + 1;
    if (master.state == 4 && rd) cov[2] = cov[2] + 1;
    if (master.state == 1 && master.cnt == 0 && !ready) cov[3] = cov[3] + 1;
    if (master.state == 0 && master.state_n == 1) begin
      if (thread == prev_t) cov[4] = cov[4] + 1;
      prev_t = thread;
    end
    if (wr && master.n_n == master.size) cov[5] = cov[5] + 1;
    if (wr && pkt_end) cov[6] = cov[6] + 1;
  end

  // -- run ------------------------------------------------------------------------
  integer limit, words0, first0, last0, j0;
  initial begin
    limit = 20000 + N * (MODE == 0 ? 60000 : 12000);
    repeat (10) @(posedge clk);
    rst = 0;
    while (!(oseq[0] == count(0) && oseq[1] == count(2) && got[1] == count(1) && got[3] == count(3))
           && cyc < limit) @(posedge clk);
    repeat (50) @(posedge clk);
    words0 = words; first0 = first; last0 = last;
    // reset in the middle of a read burst, SLOE# low
    if (count(0) > 0 && cyc < limit) begin
      for (j0 = 0; j0 < DATA; j0 = j0 + 1) fx3.send[j0] = pat(0, count(0), j0);
      sent[0] = count(0) + 1;
      fx3.host_send(0, DATA);          // a buffer is free: all traffic is through
      k = 0;
      while (!(master.state == 3 && !sloe && oj[0] > 100) && k < 100000) begin @(posedge clk); k = k + 1; end
      if (k == 100000) begin errors = errors + 1; $display("no read burst to reset in"); end
      #1 rst = 1; shut = 1;
      repeat (8) @(posedge clk);
      #1 rst = 0;
      repeat (50) @(posedge clk);
      $display("reset in a read burst after %0d words", oj[0]);
    end
    if (cyc >= limit) begin
      errors = errors + 1;
      $display("timeout: out %0d/%0d %0d/%0d, in %0d/%0d %0d/%0d", oseq[0], count(0), oseq[1], count(2),
               got[1], count(1), got[3], count(3));
    end
    if (MODE != 0) begin
      $display("bus: %0d words in %0d cycles = %0d.%0d %%", words0, last0 - first0 + 1,
               100 * words0 / (last0 - first0 + 1), (1000 * words0 / (last0 - first0 + 1)) % 10);
      if (100 * words0 < EFF_MIN * (last0 - first0 + 1)) begin
        errors = errors + 1; $display("bus efficiency below %0d %%", EFF_MIN);
      end
    end
    $write("coverage:");
    for (k = 0; k < NCOV; k = k + 1) $write(" %0d", cov[k]);
    $display("");
    if (MODE == 0) for (k = 0; k < NCOV; k = k + 1) if (cov[k] == 0) begin
      errors = errors + 1; $display("not exercised: %0s", cov_name[k]);
    end
    if (count(0) + count(2) > 0 && peeks == 0) begin errors = errors + 1; $display("no read wait measured"); end
    $display("%0d read waits measured", peeks);
    $display("model errors %0d, bench errors %0d", fx3.errors, errors);
    $display("RESULT: %0s", fx3.errors + errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
