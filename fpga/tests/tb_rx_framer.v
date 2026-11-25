// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_rx_framer - rx_framer -> packet_fifo -> a master-like reader, every
// packet parsed and checked against docs/PROTOCOL.md.
//
// The source is the radio at its top rate (61.44 MS/s on 1 channel, 2 x
// 30.72 on 2) behind a 16-entry queue: it never waits, a sample lost to a
// full queue is an error. The sample of time t is known to the checker:
//   I0 = t, Q0 = ~t, I1 = 7 t, Q1 = 13 t + 5   (12 bits each)
// While a stream runs, the framer's configuration inputs (format, channels,
// spp, start_at, start_time) are scrambled at random: a stream must keep
// what it started with (the host's stop write rewrites rx_ctrl's bits).
// Each run plays STREAMS streams with random format, channels, spp (1 ..
// beyond a full packet), count (0 = until stopped), start now or at a time,
// stop in mid-stream. For every packet: version, type, format, channels,
// length L and transfer size S(L), sequence, flags, time, every value, the
// padding bits zero. For every stream: the first sample is the first at or
// after the start time; times are contiguous except where OVERFLOW marks a
// gap; gaps add up to the framer's dropped count; sent + dropped = count;
// START_OF_BURST on the first packet, END_OF_BURST on the last.
// SLOW = 1: the reader stalls for long stretches, so packets must be
// dropped (and the run fails if none were).
// FAULT 1: one payload word corrupted in the FIFO memory (must be caught).
// FAULT 2: one packet's header length off by 4 bytes (must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_rx_framer;
  parameter STREAMS = 40, SEED = 1, SLOW = 0, FAULT = 0;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  // stream configuration
  reg  [3:0]  format = 1;
  reg  [1:0]  channels = 1;
  reg  [12:0] spp = 100;
  reg         start = 0, stop = 0, start_at = 0;
  reg  [63:0] start_time = 0;
  // the stream's configuration, as it was at start; the inputs above are
  // scrambled while it runs
  reg  [3:0]  sf = 1;
  reg  [1:0]  sc = 1;
  reg  [63:0] s_at = 0;
  reg         scramble = 0;
  reg  [31:0] count = 0;

  // -- source: the radio --------------------------------------------------------------------
  // One sample time every 100/61.44 cycles (1 channel) or 100/30.72 (2
  // channels), the AD9361's top rates against the 100 MHz bus clock, into a
  // 16-entry queue (the clock-crossing FIFO). The radio cannot wait: a
  // sample due while the queue is full is lost, which is an error.
  // st is the time of the sample at the queue's head, tail the next due.
  reg  [63:0] st = 0, tail = 0;
  wire        s_take;
  wire        s_valid = tail != st;
  integer     phase = 0, lost = 0;
  function [11:0] val(input [63:0] t, input integer k);
    case (k)
      0: val = t[11:0];
      1: val = ~t[11:0];
      2: val = t[11:0] * 7;
      default: val = t[11:0] * 13 + 5;
    endcase
  endfunction
  wire [47:0] s_data = {val(st, 3), val(st, 2), val(st, 1), val(st, 0)};
  always @(posedge clk) begin
    if (s_take) begin
      if (!s_valid) begin errors = errors + 1; $display("%0t take without a sample", $time); end
      st <= st + 1;
    end
    // phase advances by the rate in units of 1/10000 sample per cycle
    phase = phase + (sc == 3 ? 3072 : 6144);
    if (phase >= 10000) begin
      phase = phase - 10000;
      if (tail - st - s_take >= 16) begin
        lost = lost + 1;
        if (lost < 5) $display("%0t radio sample %0d lost: the framer fell behind", $time, tail);
        errors = errors + 1;
      end else tail <= tail + 1;
    end
  end

  // -- design ---------------------------------------------------------------------------
  wire        w_room, w_valid, w_last, running, r_avail, r_last;
  wire [31:0] w_data, dropped, r_data;
  reg         r_take = 0;
  rx_framer dut (.clk(clk), .rst(rst), .s_valid(s_valid), .s_time(st), .s_data(s_data), .s_take(s_take),
    .format(format), .channels(channels), .spp(spp), .start(start), .stop(stop), .start_at(start_at),
    .start_time(start_time), .count(count), .w_room(w_room), .w_valid(w_valid), .w_last(w_last),
    .w_data(w_data), .running(running), .dropped(dropped));
  packet_fifo #(.AW(14), .MAX(4096)) ring (.wclk(clk), .w_rst(rst), .w_room(w_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .rclk(clk), .r_rst(rst), .r_avail(r_avail), .r_data(r_data),
    .r_last(r_last), .r_take(r_take));

  // -- reader: whole packets at 1 word per cycle, stalls when SLOW ----------------------------
  reg [31:0] pkt [0:4095];
  integer    pw = 0, hold = 0;
  reg        busy = 0;
  always @(posedge clk) begin
    if (r_take) begin
      pkt[pw] = r_data; pw = pw + 1;
      if (r_last) begin check_packet(pw); pw = 0; busy = 0; end
    end else if (!busy && r_avail) begin
      if (hold > 0) hold = hold - 1;
      else begin busy = 1; if (SLOW && rnd(8) == 0) hold = 2000 + rnd(30000); end
    end
    r_take <= busy && !(r_take && r_last);
  end

  // -- checker ----------------------------------------------------------------------------
  integer    npackets = 0, gaps = 0, sent = 0, seq_next = 0, written = 0;
  always @(posedge clk) if (w_valid && w_last) written = written + 1;
  reg [63:0] next_t = 0;          // time the next packet must start at (unless OVERFLOW)
  reg        expect_first = 0, ended = 1, start_at_s = 0, t0_seen = 0;
  integer    dropped0 = 0;        // framer's dropped count before this stream
  // the stream's first sample: the head when the framer first reaches START
  always @(posedge clk) if (!t0_seen && dut.state == 2) begin
    t0_seen = 1; next_t = st;
    if (start_at_s && st != s_at) begin
      errors = errors + 1; $display("%0t stream starts at %0d, start time %0d", $time, st, s_at);
    end
  end

  task check_packet(input integer words);
    integer L, B, vb, nv, n, k, v, bit0, j, expw, seq_exp, flags;
    reg [63:0] t;
    reg [15:0] raw;
    reg [11:0] got, exp;
    reg        bad;
    begin
      npackets = npackets + 1;
      bad = 0;
      L = pkt[0][15:0];
      flags = pkt[1][31:16];
      t = {pkt[3], pkt[2]};
      vb = sf == 2 ? 12 : 16;
      nv = sc == 3 ? 4 : 2;
      B = nv * vb / 8;
      n = (L - 16) / B;
      expw = (L + 3) / 4; if (expw % 256 == 0 && expw != 4096) expw = expw + 1;
      if (pkt[0][31:16] !== {4'd1, 2'd0, sc, sf, 4'd0} || (L - 16) % B != 0 || words != expw) begin
        bad = 1; $display("%0t packet %0d: header %h, %0d words for L = %0d", $time, npackets, pkt[0], words, L);
      end
      if (pkt[1][15:0] !== seq_next[15:0] || flags[15:4] != 0 || !flags[0]) begin
        bad = 1; $display("%0t packet %0d: word 1 %h, sequence expected %0d", $time, npackets, pkt[1], seq_next);
      end
      if (flags[1] !== expect_first) begin bad = 1; $display("%0t packet %0d: START_OF_BURST %b", $time, npackets, flags[1]); end
      if (flags[3]) begin
        if (t <= next_t) begin bad = 1; $display("%0t packet %0d: OVERFLOW without a gap", $time, npackets); end
        gaps = gaps + (t - next_t);
      end else if (t != next_t) begin
        bad = 1; $display("%0t packet %0d: time %0d, expected %0d", $time, npackets, t, next_t);
      end
      // values: the payload as one little-endian bit stream
      for (k = 0; k < n && !bad; k = k + 1)
        for (v = 0; v < nv; v = v + 1) begin
          bit0 = 128 + (k * nv + v) * vb;
          raw = 0;
          for (j = 0; j < vb; j = j + 1) raw[j] = pkt[(bit0 + j) / 32][(bit0 + j) % 32];
          got = vb == 16 ? raw[15:4] : raw[11:0];
          exp = val(t + k, sc == 3 ? v : (sc == 2 ? v + 2 : v));
          if (got !== exp || (vb == 16 && raw[3:0] != 0)) begin
            bad = 1; $display("%0t packet %0d sample %0d value %0d: %h, expected %h", $time, npackets, k, v, raw, exp);
          end
        end
      for (j = 128 + n * nv * vb; j < 32 * words && !bad; j = j + 1)
        if (pkt[j / 32][j % 32] !== 1'b0) begin bad = 1; $display("%0t packet %0d: padding bit %0d set", $time, npackets, j); end
      if (bad) errors = errors + 1;
      seq_next = seq_next + 1;
      expect_first = 0;
      sent = sent + n;
      next_t = t + n;
      if (flags[2]) ended = 1;
    end
  endtask

  // -- streams --------------------------------------------------------------------------
  integer s_i, life;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    for (s_i = 0; s_i < STREAMS; s_i = s_i + 1) begin
      @(posedge clk);
      format   = rnd(2) ? 1 : 2;
      channels = 1 + rnd(3);
      case (rnd(4)) 0: spp = 1 + rnd(4); 1: spp = 8191; 2: spp = 1 + rnd(3000); default: spp = 1 + rnd(200); endcase
      count    = rnd(4) == 0 ? 0 : 1 + rnd(20000);
      start_at = rnd(2);
      start_time = st + rnd(3000);
      start_at_s = start_at; t0_seen = 0;
      sf = format; sc = channels; s_at = start_time;
      seq_next = 0; expect_first = 1; ended = 0; sent = 0; gaps = 0; dropped0 = dropped;
      start <= 1; @(posedge clk); start <= 0;
      scramble = 1;
      life = count == 0 || rnd(4) == 0 ? 2000 + rnd(40000) : -1;     // stop after `life` cycles
      while (!ended && (life != 0)) begin @(posedge clk); if (life > 0) life = life - 1; end
      if (!ended) begin stop <= 1; @(posedge clk); stop <= 0; end
      while (!ended && running) @(posedge clk);
      // drained: the framer idle and every packet it wrote checked
      while (running || npackets != written) @(posedge clk);
      scramble = 0;
      // a stream stopped while waiting for its start time sends nothing
      if (!ended && (seq_next != 0 || t0_seen)) begin errors = errors + 1; $display("stream %0d: no END_OF_BURST", s_i); end
      if (gaps != dropped - dropped0) begin
        errors = errors + 1; $display("stream %0d: gaps %0d, dropped %0d", s_i, gaps, dropped - dropped0);
      end
      if (count != 0 && life < 0 && sent + (dropped - dropped0) != count) begin
        errors = errors + 1; $display("stream %0d: %0d sent + %0d dropped != count %0d", s_i, sent, dropped - dropped0, count);
      end
    end
    if (SLOW && dropped == 0) begin errors = errors + 1; $display("SLOW run without a dropped packet"); end
    if (!SLOW && dropped != 0) begin errors = errors + 1; $display("%0d samples dropped with a fast reader", dropped); end
    $display("%0d streams, %0d packets, %0d samples dropped", STREAMS, npackets, dropped);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  // the configuration inputs change at random while a stream runs
  always @(posedge clk) if (scramble && rnd(50) == 0) begin
    format <= rnd(4); channels <= rnd(4); spp <= rnd(8192);
    start_at <= rnd(2); start_time <= {$random(seed), $random(seed)};
  end

  // a broken design floods: stop at 20 errors
  always @(posedge clk) if (errors > 20) begin
    $display("RESULT: FAIL (stopped after 20 errors)"); $finish;
  end

  // -- faults ---------------------------------------------------------------------------
  initial if (FAULT == 1) begin
    wait (npackets == 3); @(posedge clk);
    wait (ring.wp - ring.rp > 20);
    ring.mem[(ring.rp + 10) % 16384] = ring.mem[(ring.rp + 10) % 16384] ^ 33'h40;
  end
  initial if (FAULT == 2) begin
    wait (npackets == 5);
    wait (dut.state == 3 && dut.hw == 0);
    force dut.h0[15:0] = dut.h0[15:0] + 4;
    @(posedge clk); @(posedge clk); release dut.h0[15:0];
  end
endmodule

`default_nettype wire
