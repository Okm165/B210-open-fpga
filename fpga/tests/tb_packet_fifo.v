// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_packet_fifo - packet_fifo against a reference queue, one clock.
//
// The bench keeps the stream of words it offered, {last, data}, in a software
// queue and compares it with the module every cycle:
//   w_room   with "fewer than MAX words in"
//   w_used, r_used with the queue's length
//   r_avail  with "a complete packet is in and its words are not all read"
//   r_data, r_last with the oldest unread word of a complete packet
// Nothing of the module's pointers, memory or read path enters the
// expectation: the reference queue counts the words offered and the packets
// closed by a `last` mark.
//
// The writer never presents a word for a packet that does not fit whole
// (queue length + packet length <= MAX), so the queue never holds more than
// MAX words; if a word is presented at MAX the bench fails, which is the
// writer's side of the room promise. The reader behaves like fx3_master: it
// starts only on r_avail, then takes a packet one word per cycle to its
// `last`, never pausing inside one - a packet whose words are not all there
// when it starts, or that runs out mid-way, is a failure of the whole-packet
// promise.
//
// Corners first, once: r_take held high while empty; MAX words written back
// to back with only the last one marked last (w_room high before each of the
// MAX, low right after the MAX-th; r_avail low for every one of them but the
// last); w_room back in the cycle after one read; the rest drained back to
// back and compared word by word; empty again with r_take high (ignored).
// Then N random packets of 1..MAX words, words and packets separated by
// gaps, and long random read stalls, so the FIFO fills and empties
// throughout while packets arrive in pieces.
//
// GAPS = 1 gives the writer gaps inside and between packets and the reader
// random long stalls; GAPS = 0 runs both back to back.
//
// FAULT 1 flips a data bit of an unread word in the memory     (data)
// FAULT 2 clears the last bit of a packet's last word           (last)
// FAULT 3 makes the module believe one more word fits           (room off by one)
// FAULT 4 makes r_avail high with no packet in the FIFO and takes (read when empty)
// Each must make the bench FAIL.
`timescale 1ns/1ps
`default_nettype none

module tb_packet_fifo;
  parameter AW = 9, MAX = 256, N = 300, SEED = 1, GAPS = 1, FAULT = 0;
  localparam DEPTH = 1 << AW;
  localparam ROOM  = (DEPTH - MAX) > MAX ? (DEPTH - MAX) : MAX;   // as the module
  localparam QN    = 1 << 16;         // reference queue, more than 2 * depth

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;

  reg         w_valid = 0, w_last = 0, r_take = 0;
  reg  [31:0] w_data = 0;
  wire        w_room, r_avail, r_last;
  wire [31:0] r_data;
  wire [AW:0] w_used, r_used;

  packet_fifo #(.AW(AW), .MAX(MAX)) dut (.clk(clk), .rst(rst),
    .w_valid(w_valid), .w_last(w_last), .w_data(w_data), .w_room(w_room), .w_used(w_used),
    .r_take(r_take), .r_avail(r_avail), .r_last(r_last), .r_data(r_data), .r_used(r_used));

  integer errors = 0, seed = SEED, rseed = SEED + 1000;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction
  function integer rrnd(input integer m); rrnd = ($random(rseed) & 32'h7fffffff) % m; endfunction

  task err(input [8*48-1:0] msg);
    begin
      errors = errors + 1;
      if (errors < 12) $display("%0t %0s", $time, msg);
    end
  endtask

  // -- the reference queue ------------------------------------------------------
  reg [32:0] mq [0:QN-1];             // {last, data}, as offered
  integer    mw = 0, mr = 0, mn = 0;  // words written, read, in the queue
  integer    mc = 0;                  // words of complete packets
  integer    held_max = 0;
  integer    phase = 0;               // 0 corners, 1 random packets, 2 done
  reg        busy = 0;                // the reader is inside a packet

  always @(posedge clk) if (!rst) begin
    // what the module must show in this cycle, before this edge's transfers
    if (w_room !== (mn < ROOM)) begin err("w_room"); $display("  %0d words in, w_room %b", mn, w_room); end
    if (w_used !== mn)         begin err("w_used"); $display("  w_used %0d, %0d expected", w_used, mn); end
    if (r_used !== mn)         begin err("r_used"); $display("  r_used %0d, %0d expected", r_used, mn); end
    if (r_avail !== (mc != mr)) begin err("r_avail"); $display("  %0d words of complete packets, r_avail %b", mc - mr, r_avail); end
    if (r_avail) begin
      if (r_data !== mq[mr % QN][31:0]) begin
        err("r_data"); $display("  word %0d: %h, expected %h", mr, r_data, mq[mr % QN][31:0]);
      end
      if (r_last !== mq[mr % QN][32]) begin
        err("r_last"); $display("  word %0d: last %b, expected %b", mr, r_last, mq[mr % QN][32]);
      end
    end
    if (busy && !r_avail) err("the reader ran out of words inside a packet");
    // the transfers at this edge
    if (w_valid && mn >= ROOM) err("a word was written with no room left for it");
    if (w_valid && mn < DEPTH) begin
      mq[mw % QN] = {w_last, w_data}; mw = mw + 1; mn = mn + 1;
      if (w_last) mc = mw;
    end
    if (r_take && r_avail) begin
      if (mr == mc) begin err("a read was taken with no word of a complete packet"); end
      else begin mr = mr + 1; mn = mn - 1; end
    end
    if (mn > held_max) held_max = mn;
  end

  // -- reader: whole packets, one word per cycle, with random long stalls ------
  integer pause = 0;
  always @(negedge clk) if (!rst && phase == 1) begin
    if (pause != 0) begin pause = pause - 1; r_take = 0; end
    else if (busy) begin
      r_take = 1;
      if (r_last) busy = 0;                 // this take ends the packet
    end else if (r_avail) begin
      if (GAPS && rrnd(8) == 0) begin pause = 50 + rrnd(200); r_take = 0; end
      else begin busy = !r_last; r_take = 1; end     // a one-word packet ends here
    end else r_take = 0;
  end

  // -- stimulus -----------------------------------------------------------------
  integer i, j, sent, w, len, pseq = 0, filled = 0, wordn = 0;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 0;

    // empty: a take with no word must do nothing
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk);
      r_take = 1;
      if (w_used !== 0 || w_room !== 1 || r_avail !== 0) err("empty FIFO corner");
    end
    r_take = 0;

    // fill until the room is used up: whole packets of MAX words, then
    // single words, every one checked against the model; the first packet
    // stays invisible until its last word. A depth of MAX or 2*MAX fills
    // with exactly one packet of MAX words, so w_room goes low on the
    // MAX-th word; a deeper one holds several packets.
    filled = 0;
    while (mn + MAX <= ROOM) begin
      for (j = 0; j < MAX; j = j + 1) begin
        @(negedge clk);
        if (w_room !== 1) begin err("w_room low inside a packet that fit"); $display("  word %0d", filled + j); end
        if (filled == 0 && r_avail !== 0) begin err("a packet is visible before its last word"); $display("  word %0d of %0d", j + 1, MAX); end
        wordn = filled + j;
        w_valid = 1; w_last = j == MAX - 1; w_data = {16'hF100, wordn[15:0]};
      end
      @(negedge clk);                   // the packet's last word is in
      w_valid = 0; w_last = 0;          // and a gap before the next packet
      filled = filled + MAX;
    end
    w_valid = 0; w_last = 0; w_data = 0;
    while (w_room === 1) begin          // the room's last words, one-word packets
      @(negedge clk);
      if (w_room !== 1) begin err("w_room low before a word that fit"); $display("  word %0d", filled); end
      w_valid = 1; w_last = 1; w_data = {16'hF100, filled[15:0]};
      filled = filled + 1;
      @(negedge clk);
      w_valid = 0; w_last = 0;
    end
    if (w_room !== 0) err("w_room still high with the room used up");
    if (w_used !== filled || r_used !== filled) begin err("used after filling"); $display("  %0d, %0d expected", w_used, filled); end
    if (r_avail !== 1) err("r_avail low with a complete packet in");

    // break one unread word: the read path must not repair it
    if (FAULT == 1) dut.mem[3][7] = !dut.mem[3][7];
    if (FAULT == 2) dut.mem[3][32] = 1'b1;      // word 3 claims to end the packet
    if (FAULT == 3) begin               // the room says one more word fits
      force w_room = 1'b1;
      @(negedge clk);
      release w_room;
    end

    // one read: w_room must be back in the next cycle
    r_take = 1;
    @(negedge clk);
    r_take = 0;
    if (w_room !== 1) err("w_room did not come back after one read");
    if (w_used !== filled - 1) begin err("w_used after one read"); $display("  %0d, %0d expected", w_used, filled - 1); end

    // drain back to back
    for (j = 1; j < filled; j = j + 1) begin
      if (r_avail !== 1) err("r_avail low while draining");
      r_take = 1;
      @(negedge clk);
    end
    r_take = 0;
    if (w_used !== 0 || r_avail !== 0) err("not empty after draining");
    if (w_room !== 1) err("w_room low after draining");

    // empty again: a take with no word must do nothing
    r_take = 1;
    @(negedge clk);
    if (w_used !== 0 || r_avail !== 0) err("empty FIFO corner after draining");
    if (FAULT == 4) begin               // avail says a packet is there
      force r_avail = 1'b1;
      @(negedge clk);
      release r_avail;
    end
    r_take = 0;

    // -- random packets ---------------------------------------------------------
    phase = 1;
    for (sent = 0; sent < N; sent = sent + 1) begin
      len = rnd(4) == 0 ? MAX : rnd(4) == 0 ? 1 + rnd(3) : 1 + rnd(MAX);
      @(negedge clk);
      while (mn + len > ROOM) @(negedge clk);     // the whole packet must fit
      for (w = 0; w < len; w = w + 1) begin
        if (GAPS && rnd(3) == 0) begin
          w_valid = 0;
          repeat (1 + rnd(3)) @(negedge clk);
        end
        w_valid = 1; w_last = w == len - 1; w_data = {pseq[15:0], w[15:0]};
        @(negedge clk);
      end
      w_valid = 0; w_last = 0;
      if (GAPS) repeat (rnd(8)) @(negedge clk);
      pseq = pseq + 1;
    end
    while (mn != 0) @(negedge clk);               // the reader drains the rest
    repeat (20) @(negedge clk);
    r_take = 0;
    phase = 2;

    if (mn != 0) err("words left in the FIFO");
    if (mw != mr) err("words written and read differ");
    $display("%0d packets, %0d words, most held %0d of %0d", sent, mw, held_max, MAX);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  // -- timeout ------------------------------------------------------------------
  initial begin
    repeat (N * (MAX + 40) * 8 + 20000) @(posedge clk);
    errors = errors + 1; $display("%0t timeout at word %0d", $time, mw);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
