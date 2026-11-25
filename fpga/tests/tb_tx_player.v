// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_tx_player - random tx packets -> packet_fifo -> tx_player, every
// output entry compared with the one the packet must produce.
//
// Packets: random format, channels, n (0 .. full), START/END_OF_BURST,
// HAS_TIME; random 12-bit values, and in sc16 random bits in the 4 low
// bits of each field (they must be ignored). Mixed in: header-only
// END_OF_BURST packets, sequence jumps, padding words after S(L), buffers
// cut short (only the sample times whose bits all arrived may come out, no
// END_OF_BURST), and malformed headers (version, type, format, channels,
// length not a whole number of sample times, above 16384, below 16, a
// buffer shorter than a header) that must come out as nothing. The
// output is stalled at random. The counters bad / seq_errors / short must
// match the packets sent.
// FAULT 1: one payload bit flipped in the ring (must be caught).
// FAULT 2: START_OF_BURST lost on one packet (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_tx_player;
  parameter N = 600, SEED = 1, FAULT = 0;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  // -- design ---------------------------------------------------------------------------
  wire        w_room, r_avail, r_last, r_take, o_valid, o_present, o_sob, o_eob, o_timed;
  wire [31:0] r_data, bad, seq_errors, short;
  wire [63:0] o_time;
  wire [47:0] o_data;
  reg         w_valid = 0, w_last = 0, o_ready = 0;
  reg  [31:0] w_data = 0;
  packet_fifo #(.AW(14), .MAX(4096)) ring (.wclk(clk), .w_rst(rst), .w_room(w_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .rclk(clk), .r_rst(rst), .r_avail(r_avail), .r_data(r_data),
    .r_last(r_last), .r_take(r_take));
  tx_player dut (.clk(clk), .rst(rst), .r_avail(r_avail), .r_data(r_data), .r_last(r_last), .r_take(r_take),
    .o_valid(o_valid), .o_ready(o_ready), .o_present(o_present), .o_sob(o_sob), .o_eob(o_eob),
    .o_timed(o_timed), .o_time(o_time), .o_data(o_data), .bad(bad), .seq_errors(seq_errors), .short(short));

  // -- expected entries: {present, sob, eob, timed, time, data} ---------------------------
  localparam QN = 1 << 20;
  reg [115:0] q [0:QN-1];
  integer     qw = 0, qr = 0;
  integer     exp_bad = 0, exp_seq = 0, exp_short = 0;
  task expect(input p, input sob, input eob, input timed, input [63:0] t, input [47:0] dat);
    begin q[qw % QN] = {p, sob, eob, timed, t, dat}; qw = qw + 1; end
  endtask

  // -- one packet: words into pkt[], expectations into q ------------------------------------
  reg [31:0] pkt [0:4200];
  integer    words;
  reg [15:0] seq = 0;
  reg        any_good = 0;
  task gen;
    integer kind, fmt, ch, vb, nv, n, full, L, k, v, j, bit0, wexp, given, kmax;
    reg [11:0] val [0:3];
    reg [15:0] field;
    reg [3:0]  junk;
    reg [63:0] t;
    reg        sob, eob, ht, timed;
    reg [47:0] dat;
    begin
      kind = rnd(16);        // 0 malformed, 1 cut short, 2 header-only EOB, 3 seq jump, 4 padding, else normal
      fmt = 1 + rnd(2); ch = 1 + rnd(3);
      vb = fmt == 2 ? 12 : 16; nv = ch == 3 ? 4 : 2;
      full = 16368 * 8 / (vb * nv);
      n = kind == 2 ? 0 : rnd(4) == 0 ? full : rnd(3) == 0 ? rnd(8) : rnd(full + 1);
      L = 16 + n * nv * vb / 8;
      sob = rnd(3) == 0; eob = kind == 2 || rnd(3) == 0; ht = rnd(2);
      t = {$random(seed), $random(seed)};
      if (kind == 3) seq = seq + 1 + rnd(100);
      for (j = 0; j < 4200; j = j + 1) pkt[j] = 0;
      pkt[0] = {4'd1, 2'd0, ch[1:0], fmt[3:0], 4'd1, L[15:0]};
      pkt[1] = {12'd0, 1'b0, eob, sob, ht, seq};
      pkt[2] = t[31:0]; pkt[3] = t[63:32];
      wexp = (L + 3) / 4; if (wexp % 256 == 0 && wexp != 4096) wexp = wexp + 1;
      words = wexp;
      given = kind == 1 ? 4 + rnd(wexp - 3) : wexp;    // a cut buffer: 4 .. wexp words
      kmax = (given - 4) * 32 / (vb * nv); if (kmax > n) kmax = n;
      for (k = 0; k < n; k = k + 1) begin
        for (v = 0; v < 4; v = v + 1) val[v] = $random(seed);
        for (v = 0; v < nv; v = v + 1) begin
          junk = rnd(16);
          field = vb == 16 ? {val[v], junk} : {4'd0, val[v]};
          bit0 = 128 + (k * nv + v) * vb;
          for (j = 0; j < vb; j = j + 1) pkt[(bit0 + j) / 32][(bit0 + j) % 32] = field[j];
        end
        dat = ch == 3 ? {val[3], val[2], val[1], val[0]} : ch == 1 ? {24'd0, val[1], val[0]} : {val[1], val[0], 24'd0};
        timed = k == 0 && sob && ht;
        if (kind != 0 && k < kmax) expect(1, k == 0 && sob, k == n - 1 && eob && kind != 1 ? 1'b1 : 1'b0, timed, timed ? t : 64'd0, dat);
      end
      if (kind == 1 && given < wexp && kmax < n) exp_short = exp_short + 1;
      if (kind == 1 && kmax == n && eob && n > 0) begin
        // every sample arrived (only padding was cut): the last one carries EOB
        q[(qw - 1) % QN][113] = 1'b1;
      end
      if (kind == 2 || (n == 0 && eob && kind != 0)) expect(0, 0, 1, 0, 0, 0);
      if (kind == 4) for (j = 0; j < 1 + rnd(6); j = j + 1) begin pkt[words] = 32'hFFFF_FFFF; words = words + 1; end
      if (kind == 1) words = given;
      if (kind == 0) begin
        case (rnd(8))
          0: pkt[0][31:28] = 2;
          1: pkt[0][19:16] = 0;
          2: pkt[0][23:20] = 3;
          3: pkt[0][25:24] = 0;
          4: if (n > 0 && nv * vb != 32) pkt[0][15:0] = L - 1; else pkt[0][15:0] = 16384 + 4;
          5: pkt[0][15:0] = 16384 + nv * vb / 8;
          6: pkt[0][15:0] = 12;
          default: words = 1 + rnd(3);
        endcase
        exp_bad = exp_bad + 1;
      end else begin
        if (kind == 3 && any_good) exp_seq = exp_seq + 1;   // the first packet has no predecessor
        any_good = 1;
        seq = seq + 1;
      end
      if (words > 4096) words = 4096;
    end
  endtask

  // -- send -----------------------------------------------------------------------------
  integer sent = 0, w;
  initial begin
    wait (!rst);
    for (sent = 0; sent < N; sent = sent + 1) begin
      gen;
      @(posedge clk);
      while (!w_room) @(posedge clk);
      for (w = 0; w < words; w = w + 1) begin
        w_valid <= 1; w_data <= pkt[w]; w_last <= w == words - 1;
        @(posedge clk);
      end
      w_valid <= 0; w_last <= 0;
      repeat (rnd(20)) @(posedge clk);
    end
  end

  // -- check the output -------------------------------------------------------------------
  reg [115:0] e, got;
  integer nout = 0;
  always @(posedge clk) begin
    if (o_valid && o_ready) begin
      got = {o_present, o_sob, o_eob, o_timed, o_timed ? o_time : 64'd0, o_data};
      if (qr == qw) begin errors = errors + 1; $display("%0t entry %0d not expected", $time, nout); end
      else begin
        e = q[qr % QN]; qr = qr + 1;
        if (got !== e) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t entry %0d: p%b s%b e%b t%b %h %h, expected p%b s%b e%b t%b %h %h", $time, nout,
            got[115], got[114], got[113], got[112], got[111:48], got[47:0], e[115], e[114], e[113], e[112], e[111:48], e[47:0]);
        end
      end
      nout = nout + 1;
    end
    o_ready <= rnd(4) != 0;
  end

  // -- faults ---------------------------------------------------------------------------
  initial if (FAULT == 1) begin
    wait (sent == 20); wait (ring.wp - ring.rp > 40);
    ring.mem[(ring.rp + 30) % 16384] = ring.mem[(ring.rp + 30) % 16384] ^ 33'h100;
  end
  initial if (FAULT == 2) begin
    wait (nout > 100); wait (dut.state == 2 && dut.h1[17] && dut.good && dut.n_hdr != 0);
    @(posedge clk); #1 force dut.first = 0;
    @(posedge clk); @(posedge clk); release dut.first;
  end

  integer idle;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    wait (sent == N);
    // drained: every expected entry out, or none for 100 000 cycles
    idle = 0;
    while (qr != qw && idle < 100000) begin
      @(posedge clk); idle = (o_valid && o_ready) ? 0 : idle + 1;
    end
    repeat (1000) @(posedge clk);       // and nothing extra after that
    if (qr != qw) begin errors = errors + 1; $display("%0d entries expected, %0d came", qw, qr); end
    if (bad != exp_bad || seq_errors != exp_seq || short != exp_short) begin
      errors = errors + 1;
      $display("bad %0d seq_errors %0d short %0d, expected %0d %0d %0d", bad, seq_errors, short, exp_bad, exp_seq, exp_short);
    end
    $display("%0d packets, %0d entries; bad %0d, seq jumps %0d, short %0d", N, nout, bad, seq_errors, short);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
