// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_packet_fifo - packet_fifo between two unrelated clocks.
//
// The writer starts a packet only when w_room says so and writes its words
// with random gaps (GAPS = 1) or back to back. The reader behaves like
// fx3_master: it waits for r_avail, then takes the packet one word per
// cycle without a pause. Word j of packet s is {s, j}, so a gap in the
// read-ahead (a word repeated), a lost or reordered word, or a wrong
// `last` is a mismatch. Also checked: a packet is never visible before its
// last word is written; the FIFO never holds more than its depth + the 4
// words of its read-ahead; with the reader stalled the writer fills it to
// within MAX words of that.
//
// WCLK/RCLK are half-periods in ps: faster writer, faster reader, equal.
// FAULT 1 flips one bit of an unread word (must be caught); FAULT 2 makes
// the reader ignore r_avail (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_packet_fifo;
  parameter AW = 8, MAX = 100, N = 400, SEED = 1, GAPS = 1, FAULT = 0;
  parameter WCLK = 5000, RCLK = 8138;
  localparam DEPTH = 1 << AW;

  reg wclk = 0, rclk = 0;
  always #(WCLK / 1000.0) wclk = ~wclk;
  always #(RCLK / 1000.0) rclk = ~rclk;
  reg w_rst = 1, r_rst = 1;

  wire        w_room, r_avail, r_last;
  wire [31:0] r_data;
  reg         w_valid = 0, w_last = 0, r_take = 0;
  reg  [31:0] w_data = 0;
  packet_fifo #(.AW(AW), .MAX(MAX)) dut (.wclk(wclk), .w_rst(w_rst), .w_room(w_room),
    .w_valid(w_valid), .w_last(w_last), .w_data(w_data), .rclk(rclk), .r_rst(r_rst),
    .r_avail(r_avail), .r_data(r_data), .r_last(r_last), .r_take(r_take));

  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction
  integer len [0:N-1];
  integer s;
  initial for (s = 0; s < N; s = s + 1)
    len[s] = rnd(4) == 0 ? MAX : rnd(4) == 0 ? 1 + rnd(3) : 1 + rnd(MAX);

  // -- writer -----------------------------------------------------------------
  integer written = 0, wseq = 0, wj = 0, held = 0, held_max = 0;
  integer stall = 1;                 // reader holds off until the FIFO has filled once
  integer done_seq = -1;             // last packet whose last word is written
  always @(posedge wclk) if (!w_rst) begin
    w_valid <= 0; w_last <= 0;
    if (wseq < N && (wj > 0 || w_room) && (!GAPS || rnd(3) != 0)) begin
      w_valid <= 1; w_data <= {wseq[15:0], wj[15:0]}; w_last <= wj == len[wseq] - 1;
      if (wj == len[wseq] - 1) begin done_seq = wseq; wseq = wseq + 1; wj = 0; end
      else wj = wj + 1;
      written = written + 1;
    end
  end

  // -- reader -----------------------------------------------------------------
  // r_take is a register: the word shown while it is 1 is consumed at the
  // next rising edge, where it is checked. A packet starts only after a
  // cycle without a take (r_avail then describes the next packet).
  integer rseq = 0, rj = 0, nread = 0;
  reg     busy = 0;
  always @(posedge rclk) if (!r_rst) begin
    if (r_take) begin
      if (r_data !== {rseq[15:0], rj[15:0]} || r_last !== (rj == len[rseq] - 1)) begin
        errors = errors + 1;
        if (errors < 10) $display("%0t packet %0d word %0d: %h last %b, expected %h last %b", $time,
          rseq, rj, r_data, r_last, {rseq[15:0], rj[15:0]}, rj == len[rseq] - 1);
      end
      nread = nread + 1;
      if (rj == len[rseq] - 1) begin rseq = rseq + 1; rj = 0; busy = 0; end else rj = rj + 1;
    end else if (!stall && !busy && rseq < N && (r_avail || FAULT == 2)) begin
      if (done_seq < rseq) begin
        errors = errors + 1; $display("%0t packet %0d visible before its last word", $time, rseq);
      end
      busy = 1;
    end
    r_take <= busy;
  end
  always @(negedge rclk) if (busy && !r_avail && FAULT != 2) begin
    errors = errors + 1; $display("%0t read-ahead ran dry inside packet %0d", $time, rseq);
  end

  // -- occupancy ---------------------------------------------------------------
  always @(posedge wclk) begin
    held = written - nread;
    if (held > held_max) held_max = held;
    // the memory holds DEPTH words, the read-ahead queue 4 more
    if (held > DEPTH + 4) begin errors = errors + 1; $display("%0t %0d words held > depth + 4", $time, held); end
  end

  initial begin
    if (FAULT == 1) begin
      wait (written > DEPTH / 2);
      dut.mem[DEPTH/4][5] = !dut.mem[DEPTH/4][5];   // unread: the reader is stalled
    end
  end

  reg timeout = 0;
  initial begin
    repeat (DEPTH * 8 + N * MAX * 20) @(posedge rclk);
    errors = errors + 1; $display("timeout at packet %0d", rseq); timeout = 1;
  end

  initial begin
    repeat (4) @(posedge wclk);
    w_rst = 0; r_rst = 0;
    // fill with the reader stalled: the writer must get within MAX of the depth
    wait (written > 0);
    repeat (DEPTH * 4) @(posedge wclk);
    if (written < DEPTH - MAX) begin
      errors = errors + 1; $display("filled only %0d of %0d words", written, DEPTH);
    end
    stall = 0;
    wait (rseq == N || timeout);
    $display("%0d packets, %0d words, most held %0d of %0d", rseq, nread, held_max, DEPTH);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
