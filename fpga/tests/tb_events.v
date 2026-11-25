// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_events - events + packet_mux: counters -> event packets, merged with
// a result stream, read like fx3_master reads the control IN thread.
//
// Six counters rise at random, now and then by thousands at once. A
// result source offers packets {seq, word} all the time. Checked on every
// packet read: results intact and in order (never interleaved with an
// event packet); event packets: version, type 4, length 16 + 16 m,
// HAS_TIME, sequence +1, codes ascending and distinct, counts > 0, each
// event's time = the header's, packets at least INTERVAL cycles apart.
// At the end the counts reported per code add up to the counter exactly.
// SLOW = 1: the reader stalls for long stretches (events must coalesce,
// none lost). Both sources must get through: fairness.
// FAULT 1: one event count corrupted in the FIFO (must be caught).
// FAULT 2: the mux lets go of a packet in the middle (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_events;
  parameter SEED = 1, SLOW = 0, FAULT = 0, CYCLES = 400000, INTERVAL = 500;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction
  reg [63:0] now = 0;
  always @(posedge clk) now <= now + 1;

  // -- counters ----------------------------------------------------------------------
  reg [31:0] cnt [0:5];
  reg        rising = 1;
  integer i;
  initial for (i = 0; i < 6; i = i + 1) cnt[i] = 32'hFFFF_FF00 + i;   // wrap through 2^32
  always @(posedge clk) if (rising) for (i = 0; i < 6; i = i + 1)
    if (rnd(3000) == 0) cnt[i] <= cnt[i] + (rnd(5) == 0 ? 1 + rnd(5000) : 1);
  wire [191:0] counts = {cnt[5], cnt[4], cnt[3], cnt[2], cnt[1], cnt[0]};

  // -- design ------------------------------------------------------------------------
  wire e_room, e_valid, e_last, ea, el, eta, ra, rl, rta, o_avail, o_last;
  wire [31:0] e_data, ed, rd, o_data;
  reg  r_valid = 0, r_last = 0, o_take = 0;
  reg  [31:0] r_data = 0;
  wire r_room;
  events #(.INTERVAL(INTERVAL)) dut (.clk(clk), .rst(rst), .counts(counts), .now(now),
    .w_room(e_room), .w_valid(e_valid), .w_last(e_last), .w_data(e_data));
  packet_fifo #(.AW(7), .MAX(32)) ef (.wclk(clk), .w_rst(rst), .w_room(e_room), .w_valid(e_valid), .w_last(e_last),
    .w_data(e_data), .rclk(clk), .r_rst(rst), .r_avail(ea), .r_data(ed), .r_last(el), .r_take(eta));
  packet_fifo #(.AW(9), .MAX(256)) rf (.wclk(clk), .w_rst(rst), .w_room(r_room), .w_valid(r_valid), .w_last(r_last),
    .w_data(r_data), .rclk(clk), .r_rst(rst), .r_avail(ra), .r_data(rd), .r_last(rl), .r_take(rta));
  packet_mux mux (.clk(clk), .rst(rst), .a_avail(ra), .a_last(rl), .a_data(rd), .a_take(rta),
    .b_avail(ea), .b_last(el), .b_data(ed), .b_take(eta), .o_avail(o_avail), .o_last(o_last), .o_data(o_data), .o_take(o_take));

  // -- result source: packets of 4 + 2 n words, word 0 = {3, seq}, then {seq, j} -------------
  integer rseq = 0, rj = 0, rlen = 0;
  always @(posedge clk) begin
    r_valid <= 0; r_last <= 0;
    if (!rst && rising) begin
      if (rj == 0 && rlen == 0 && r_room) rlen = 4 + 2 * rnd(127);
      if (rlen != 0) begin
        r_valid <= 1; r_data <= rj == 0 ? {16'h3000, rseq[15:0]} : {rseq[15:0], rj[15:0]};
        r_last <= rj == rlen - 1;
        if (rj == rlen - 1) begin rj = 0; rlen = 0; rseq = rseq + 1; end else rj = rj + 1;
      end
    end
  end

  // -- reader -------------------------------------------------------------------------
  reg [31:0] pkt [0:300];
  integer pw = 0, hold = 0, got_r = 0, got_e = 0, eseq = 0;
  reg     busy = 0;
  reg [63:0] last_t = 0, sum [0:5];
  initial for (i = 0; i < 6; i = i + 1) sum[i] = 0;
  always @(posedge clk) begin
    if (o_take) begin
      pkt[pw] = o_data; pw = pw + 1;
      if (o_last) begin check(pw); pw = 0; busy = 0; end
    end else if (!busy && o_avail) begin
      if (hold > 0) hold = hold - 1;
      else begin busy = 1; if (SLOW && rnd(10) == 0) hold = 5000 + rnd(50000); end
    end
    o_take <= busy && !(o_take && o_last);
  end

  task check(input integer n);
    integer j, m, code, prev;
    reg [15:0] elen;
    reg [63:0] t;
    begin
      if (pkt[0][31:16] == 16'h3000) begin            // a result packet
        if (pkt[0][15:0] != got_r[15:0]) begin errors = errors + 1; $display("%0t result %0d out of order (%h)", $time, got_r, pkt[0]); end
        for (j = 1; j < n; j = j + 1) if (pkt[j] !== {got_r[15:0], j[15:0]}) begin
          errors = errors + 1; if (errors < 10) $display("%0t result %0d word %0d: %h", $time, got_r, j, pkt[j]);
        end
        if (n % 2 != 0 || n < 4) begin errors = errors + 1; $display("%0t result %0d of %0d words", $time, got_r, n); end
        got_r = got_r + 1;
      end else begin                                  // an event packet
        m = (n - 4) / 4;
        t = {pkt[3], pkt[2]};
        elen = 16 + 16 * m;
        if (pkt[0] !== {4'd1, 8'd0, 4'd4, elen} || n != 4 + 4 * m || m < 1 || m > 6 ||
            pkt[1] !== {15'd0, 1'b1, eseq[15:0]}) begin
          errors = errors + 1; $display("%0t event packet %0d: %h %h, %0d words", $time, eseq, pkt[0], pkt[1], n);
        end
        if (got_e > 0 && t - last_t < INTERVAL) begin
          errors = errors + 1; $display("%0t event packets %0d cycles apart", $time, t - last_t);
        end
        prev = 0;
        for (j = 0; j < m; j = j + 1) begin
          code = pkt[4 + 4*j];
          if (code <= prev || code > 6 || pkt[5 + 4*j] == 0 || {pkt[7 + 4*j], pkt[6 + 4*j]} !== t) begin
            errors = errors + 1; $display("%0t event packet %0d event %0d: %h %h %h %h", $time, eseq, j,
              pkt[4+4*j], pkt[5+4*j], pkt[6+4*j], pkt[7+4*j]);
          end else sum[code - 1] = sum[code - 1] + pkt[5 + 4*j];
          prev = code;
        end
        last_t = t; eseq = eseq + 1; got_e = got_e + 1;
      end
    end
  endtask

  // -- faults ----------------------------------------------------------------------------
  initial if (FAULT == 1) begin
    wait (got_e == 5); wait (dut.state == 2 && dut.w == 2);   // the count word is on w_data now
    #1 force dut.w_data = dut.w_data + 1; @(posedge clk); #1 release dut.w_data;
  end
  initial if (FAULT == 2) begin
    wait (got_r == 20); wait (mux.locked && ea && ra);
    @(posedge clk); #1 force mux.locked = 0; force mux.last_served = mux.cur;   // pick the other source
    @(posedge clk); #1 release mux.locked; release mux.last_served;
  end

  integer r0, e0;
  reg [31:0] rose;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    repeat (CYCLES / 2) @(posedge clk);
    r0 = got_r; e0 = got_e;
    repeat (CYCLES / 2) @(posedge clk);
    if (got_r == r0 || got_e == e0) begin errors = errors + 1; $display("starved: results %0d -> %0d, events %0d -> %0d", r0, got_r, e0, got_e); end
    rising = 0;
    repeat (200000) @(posedge clk);
    for (i = 0; i < 6; i = i + 1) begin
      rose = cnt[i] - (32'hFFFF_FF00 + i);          // modulo 2^32: the counters wrapped
      if (sum[i] != rose) begin
        errors = errors + 1; $display("code %0d: events add up to %0d, counter rose by %0d", i + 1, sum[i], rose);
      end
    end
    $display("%0d result packets, %0d event packets; increases %0d %0d %0d %0d %0d %0d", got_r, got_e,
             sum[0], sum[1], sum[2], sum[3], sum[4], sum[5]);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
