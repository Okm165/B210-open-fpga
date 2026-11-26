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
// spp, timed, at) are scrambled at random: a stream must keep what it
// started with (the host's stop write rewrites rx_ctrl's bits).
// A start pulse while a stream runs must be ignored: the stream keeps its
// sequence and never sees a second START_OF_BURST.
//
// Every run plays, in this order:
//   invalid  six starts with an invalid configuration (format 0, 3, 4, 15;
//            channels 0). Each must do nothing: running stays low for 20
//            cycles, no word is written, nothing is latched.
//   edge     one stream per end-of-stream corner: stop while waiting for a
//            start time (no packet at all), stop at START before the first
//            header (one header-only packet, START_OF_BURST and
//            END_OF_BURST), count reached exactly at a packet boundary
//            (three of them: spp 32, a full-packet spp, and spp clamped
//            from 1 to 16, over sc12/sc16 and 1/2 channels), and a start
//            pulsed in mid-stream (ignored).
//   fill     the consumer stalls until the packet fifo is full: one stream
//            ending by count with a dropped packet just before its last
//            packet (END_OF_BURST + OVERFLOW on a data packet), one stream
//            stopped while dropping (header-only END_OF_BURST + OVERFLOW).
//   random   STREAMS streams with random format, channels, spp (1 .. beyond
//            a full packet, biased so both clamps are reached), count (0 =
//            until stopped, sometimes a multiple of the packet size), start
//            now or at a time (sometimes far enough to wait), stop in
//            mid-stream, and a start pulsed while the stream runs.
//
// For every packet: version, type, format, channels, length L and transfer
// size S(L), sequence, flags, time, every value, the padding bits zero.
// For every stream: the first sample is the first at or after the start
// time; times are contiguous except where OVERFLOW marks a gap; gaps add up
// to the framer's overflows count; sent + dropped = the count when the
// stream ran to its count; every sample taken inside a packet or a drop is
// either in a packet or in that count (the strobe accounting);
// START_OF_BURST on the first packet, END_OF_BURST on the last.
//
// Coverage: the counters below record that each corner above really
// happened. The run FAILS at the end if any is zero, so a bench that
// silently stops reaching a corner cannot pass.
// SLOW = 1: the reader stalls for long stretches, so packets must be
// dropped (and the run fails if none were).
// FAULT 1: one payload word corrupted for the checker (must be caught).
// FAULT 2: one packet's header length off by 4 bytes (must be caught).
// FAULT 3: the configuration check is defeated, so an invalid start runs:
//          the negative control for "an invalid start is ignored".
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
  reg         start = 0, stop = 0, timed = 0;
  reg  [63:0] at = 0;
  // the stream's configuration, as it was at start; the inputs above are
  // scrambled while it runs
  reg  [3:0]  sf = 1;
  reg  [1:0]  sc = 1;
  reg  [63:0] s_at = 0;
  reg         scramble = 0;
  reg  [31:0] count = 0;
  reg  [12:0] eff = 100;          // this stream's spp after clamping

  // -- source: the radio --------------------------------------------------------------------
  // One sample time every 100/61.44 cycles (1 channel) or 100/30.72 (2
  // channels), the AD9361's top rates against the 100 MHz bus clock, into a
  // 16-entry queue (the clock-crossing FIFO). The radio cannot wait: a
  // sample due while the queue is full is lost, which is an error.
  // st is the time of the sample at the queue's head, tail the next due.
  reg  [63:0] st = 0, tail = 0;
  reg         src_hold = 0, kick = 0;      // the directed test stops the radio
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
    if (rst) begin
      phase = 0; st = 0; tail = 0;
    end else begin
      if (s_take) begin
        if (!s_valid) begin errors = errors + 1; $display("%0t take without a sample", $time); end
        st <= st + 1;
      end
      if (kick) tail <= tail + 1;             // one sample now, whatever the phase
      else if (!src_hold) begin
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
    end
  end

  // -- design ---------------------------------------------------------------------------
  wire        w_room, w_valid, w_last, running, r_avail, r_last;
  wire [31:0] w_data, overflows, r_data;
  reg         r_take = 0;
  rx_framer dut (.clk(clk), .rst(rst), .s_valid(s_valid), .s_time(st), .s_data(s_data), .s_take(s_take),
    .format(format), .channels(channels), .spp(spp), .start(start), .stop(stop), .timed(timed),
    .at(at), .count(count), .w_room(w_room), .w_valid(w_valid), .w_last(w_last),
    .w_data(w_data), .running(running), .overflows(overflows));
  packet_fifo #(.AW(14), .MAX(4096)) ring (.clk(clk), .rst(rst), .w_room(w_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .r_avail(r_avail), .r_data(r_data),
    .r_last(r_last), .r_take(r_take));

  // -- reader: whole packets at 1 word per cycle, stalls when SLOW or stalled ----------------
  // r_data / r_last are meaningful only while r_avail: the take is gated on it
  integer    npackets = 0, gaps = 0, sent = 0, seq_next = 0, written = 0;
  integer    npkts = 0;           // packets of the current stream
  reg [31:0] pkt [0:4095];
  integer    pw = 0, hold = 0;
  reg        busy = 0, stall = 0, fault_done = 0;
  reg        directed = 0;        // a directed corner runs: no random SLOW holds
  always @(posedge clk) begin
    if (r_take && r_avail) begin
      pkt[pw] = r_data; pw = pw + 1;
      if (FAULT == 1 && !fault_done && npackets >= 3 && pw == 5) begin
        pkt[4] = pkt[4] ^ 32'h00000040; fault_done = 1;
        $display("%0t fault: payload word of packet %0d corrupted", $time, npackets + 1);
      end
      if (FAULT == 2 && !fault_done && npackets >= 5 && pw == 1) begin
        pkt[0] = pkt[0] + 32'd4; fault_done = 1;
        $display("%0t fault: length of packet %0d off by 4 bytes", $time, npackets + 1);
      end
      if (r_last) begin check_packet(pw); pw = 0; busy = 0; end
    end else if (!busy && r_avail) begin
      if (stall) ;                                              // consumer full
      else if (hold > 0) hold = hold - 1;
      else begin busy = 1; if (SLOW && !directed && rnd(8) == 0) hold = 2000 + rnd(30000); end
    end
    r_take <= busy && r_avail && !(r_take && r_last);
  end

  // -- checker ----------------------------------------------------------------------------
  // coverage counters: the corners every run must reach (checked at the end)
  integer cov_no_packet = 0, cov_start_stop = 0, cov_drop_stop = 0;
  integer cov_drop_last_data = 0, cov_drop_last_hdr = 0, cov_boundary = 0;
  integer cov_spp_full = 0, cov_spp_small = 0, cov_sc12 = 0, cov_sc16 = 0;
  integer cov_ch1 = 0, cov_ch2 = 0, cov_wait = 0, cov_start_busy = 0;
  integer cov_bad_cfg = 0, cov_fill = 0;

  reg [63:0] next_t = 0;          // time the next packet must start at (unless OVERFLOW)
  reg        expect_first = 0, ended = 1, timed_s = 0, t0_seen = 0;
  integer    overflows0 = 0, tooks0 = 0;    // framer's counts before this stream
  // samples the framer took inside a packet or a drop: each one is either
  // in a packet the checker saw or in `overflows`
  integer    tooks = 0;
  always @(posedge clk) if (s_take && (dut.state == 4 || dut.state == 5)) tooks = tooks + 1;
  always @(posedge clk) if (w_valid && w_last) written = written + 1;
  // the stream's first sample: the head when the framer first reaches START
  always @(posedge clk) if (!rst && !t0_seen && dut.state == 2) begin
    t0_seen = 1; next_t = st;
    if (timed_s && st != s_at) begin
      errors = errors + 1; $display("%0t stream starts at %0d, start time %0d", $time, st, s_at);
    end
  end

  task check_packet(input integer words);
    integer L, B, vb, nv, n, k, v, bit0, j, expw;
    reg [63:0] t;
    reg [15:0] raw;
    reg [11:0] got, exp;
    reg        bad;
    begin
      npackets = npackets + 1;
      npkts = npkts + 1;
      bad = 0;
      L = pkt[0][15:0];
      t = {pkt[3], pkt[2]};
      vb = sf == 2 ? 12 : 16;
      nv = sc == 3 ? 4 : 2;
      B = nv * vb / 8;
      n = (L - 16) / B;
      expw = (L + 3) / 4; if (expw % 256 == 0 && expw != 4096) expw = expw + 1;
      if (pkt[0][31:16] !== {4'd1, 2'd0, sc, sf, 4'd0} || (L - 16) % B != 0 || words != expw) begin
        bad = 1; $display("%0t packet %0d: header %h, %0d words for L = %0d", $time, npackets, pkt[0], words, L);
      end
      if (pkt[1][15:0] !== seq_next[15:0] || pkt[1][31:20] != 0 || !pkt[1][16]) begin
        bad = 1; $display("%0t packet %0d: word 1 %h, sequence expected %0d", $time, npackets, pkt[1], seq_next);
      end
      if (pkt[1][17] !== expect_first) begin bad = 1; $display("%0t packet %0d: START_OF_BURST %b", $time, npackets, pkt[1][17]); end
      if (pkt[1][19]) begin
        if (t <= next_t) begin bad = 1; $display("%0t packet %0d: OVERFLOW without a gap", $time, npackets); end
        gaps = gaps + (t - next_t);
      end else if (n == 0 && pkt[1][17]) begin
        // the only packet of a stream that never sent a sample: the time
        // after the stream's last sample does not exist (PROTOCOL.md leaves
        // it undefined, the framer sends t_end: 0 after reset, else the
        // previous stream's end)
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
      // the corners, as seen on the wire
      if (pkt[1][18] && n == 0 && pkt[1][17] && !pkt[1][19]) cov_start_stop = cov_start_stop + 1;
      if (pkt[1][18] && n > 0 && pkt[1][19]) cov_drop_last_data = cov_drop_last_data + 1;
      if (pkt[1][18] && n == 0 && pkt[1][19]) cov_drop_last_hdr = cov_drop_last_hdr + 1;
      if (pkt[1][18] && count != 0 && n == eff) cov_boundary = cov_boundary + 1;
      if (bad) errors = errors + 1;
      seq_next = seq_next + 1;
      expect_first = 0;
      sent = sent + n;
      next_t = t + n;
      if (pkt[1][18]) ended = 1;
    end
  endtask

  // -- coverage counters ------------------------------------------------------------------
  always @(posedge clk) if (dut.state == 1 && dut.run_timed && s_valid && dut.s_time < dut.run_at)
    cov_wait = cov_wait + 1;
  always @(posedge clk) if (stop && dut.state == 5) cov_drop_stop = cov_drop_stop + 1;

  task cover(input integer n, input [8*56-1:0] what);
    begin
      if (n == 0) begin
        errors = errors + 1;
        $display("coverage: never reached: %0s", what);
      end
    end
  endtask

  // -- stream bookkeeping -----------------------------------------------------------------
  function [12:0] full_pkt(input [3:0] f, input [1:0] c);
    full_pkt = f == 2 ? (c == 3 ? 13'd2728 : 13'd5456) : (c == 3 ? 13'd2046 : 13'd4092);
  endfunction
  function [12:0] clamp_spp(input [12:0] s, input [3:0] f, input [1:0] c);
    begin
      if (s < 16) clamp_spp = 16;
      else if (s > full_pkt(f, c)) clamp_spp = full_pkt(f, c);
      else clamp_spp = s;
    end
  endfunction

  task begin_stream(input [3:0] f, input [1:0] c, input [12:0] sp, input [31:0] cnt,
                    input tmd, input [63:0] at_time);
    begin
      scramble = 0;
      format = f; channels = c; spp = sp; count = cnt;
      timed = tmd; at = at_time;
      sf = f; sc = c; s_at = at_time; timed_s = tmd; t0_seen = 0;
      seq_next = 0; expect_first = 1; ended = 0; sent = 0; gaps = 0;
      npkts = 0; eff = clamp_spp(sp, f, c);
      overflows0 = overflows; tooks0 = tooks;
      if (sp < 16) cov_spp_small = cov_spp_small + 1;
      if (sp > full_pkt(f, c)) cov_spp_full = cov_spp_full + 1;
      if (f == 2) cov_sc12 = cov_sc12 + 1; else cov_sc16 = cov_sc16 + 1;
      if (c == 3) cov_ch2 = cov_ch2 + 1; else cov_ch1 = cov_ch1 + 1;
      start <= 1; @(posedge clk); start <= 0;
      @(posedge clk);
      if (!running) begin
        errors = errors + 1;
        $display("start ignored: format %0d channels %0d", f, c);
      end
    end
  endtask

  task end_stream(input integer id, input integer by_count);
    integer k, quiet;
    begin
      if (!ended) begin stop <= 1; @(posedge clk); stop <= 0; end
      // drained: the framer idle, no word in flight, every packet it wrote
      // read and checked. Two quiet cycles in a row: `written`, w_valid and
      // r_avail are updated by other always blocks at the same edge this
      // loop samples them, so one sample can still be stale.
      k = 0; quiet = 0;
      while (k < 2000000 && quiet < 2) begin
        @(posedge clk); k = k + 1;
        if (!running && !w_valid && !r_avail && pw == 0 && npackets == written) quiet = quiet + 1;
        else quiet = 0;
      end
      if (quiet < 2) begin
        errors = errors + 1;
        $display("stream %0d: not drained: running %b w_valid %b r_avail %b pw %0d state %0d written %0d read %0d",
          id, running, w_valid, r_avail, pw, dut.state, written, npackets);
      end
      scramble = 0;
      // a stream stopped while waiting for its start time sends nothing
      if (!ended) begin
        if (seq_next != 0 || t0_seen) begin
          errors = errors + 1; $display("stream %0d: no END_OF_BURST", id);
        end else cov_no_packet = cov_no_packet + 1;
      end
      if (gaps != overflows - overflows0) begin
        errors = errors + 1; $display("stream %0d: gaps %0d, dropped %0d", id, gaps, overflows - overflows0);
      end
      if (by_count && sent + (overflows - overflows0) != count) begin
        errors = errors + 1; $display("stream %0d: %0d sent + %0d dropped != count %0d",
          id, sent, overflows - overflows0, count);
      end
      // every strobe taken inside a packet or a drop is in a packet or counted
      if (tooks - tooks0 != sent + (overflows - overflows0)) begin
        errors = errors + 1; $display("stream %0d: took %0d, %0d sent + %0d dropped", id,
          tooks - tooks0, sent, overflows - overflows0);
      end
    end
  endtask

  // -- directed: invalid configuration, then the end-of-stream corners ---------------------
  task bad_start(input [3:0] f, input [1:0] c);
    integer k, bad;
    begin
      bad = 0;
      scramble = 0;
      format = f; channels = c; spp = 100; count = 10; timed = 0; at = 0;
      start <= 1; @(posedge clk); start <= 0;
      for (k = 0; k < 20; k = k + 1) begin
        @(posedge clk);
        if (running || w_valid) bad = 1;
      end
      if (bad) begin
        errors = errors + 1;
        $display("start with format %0d channels %0d was taken (running %b)", f, c, running);
      end
      cov_bad_cfg = cov_bad_cfg + 1;
    end
  endtask

  // stop in the cycle the first sample arrives: the framer goes
  // ARMED -> START with stopping already set, and the stream ends with a
  // header-only END_OF_BURST (nothing was sent). The radio is held for the
  // attempt so the arrival is exact: a stop one cycle earlier ends in ARMED
  // (no packet at all), which the stream check also covers.
  task stop_at_start(input integer id);
    integer tries, got, k;
    begin
      got = 0; tries = 0;
      while (!got && tries < 20) begin
        k = 0;
        while (s_valid && k < 1000) begin @(posedge clk); k = k + 1; end   // queue empty
        src_hold <= 1; @(posedge clk);
        begin_stream(1, 1, 64, 0, 0, 0);                // ARMED, nothing to send
        repeat (10) @(posedge clk);
        kick <= 1; @(posedge clk);                      // this edge: one sample
        kick <= 0; stop <= 1; @(posedge clk);           // stop and sample together
        stop <= 0; src_hold <= 0;
        end_stream(id, 0);
        if (npkts == 1 && sent == 0) got = 1;
        tries = tries + 1;
      end
      if (!got) begin errors = errors + 1; $display("never stopped at START"); end
      for (k = 0; k < 3; k = k + 1) @(posedge clk);    // let the source refill
    end
  endtask

  // one counted stream that must end at a packet boundary
  task counted(input [3:0] f, input [1:0] c, input [12:0] sp, input [31:0] cnt, input integer id);
    integer k;
    begin
      begin_stream(f, c, sp, cnt, 0, 0);
      k = 0;
      while (!ended && k < 1000000) begin @(posedge clk); k = k + 1; end
      end_stream(id, 1);
    end
  endtask

  // the consumer stalls until the fifo is full, then one of two ends
  task fill(input integer stopit, input integer id);
    integer k, ok;
    begin
      // the corner depends on when the reader resumes: a random SLOW hold
      // after `stall` drops would drop the next packet too and turn the
      // data END_OF_BURST into a header-only one
      directed = 1; hold = 0;
      begin_stream(1, 3, 2046, stopit ? 0 : 20560, 0, 0);   // sc16 2ch, 4096-word packets
      ok = 0; k = 0;
      if (stopit) begin
        stall = 1;
        while (!ok && k < 1000000) begin
          @(posedge clk); k = k + 1;
          if (overflows > overflows0 && dut.state == 5) ok = 1;
        end
        if (ok) begin stop <= 1; @(posedge clk); stop <= 0; end    // stop in DROP
        repeat (200) @(posedge clk);
        stall = 0;
      end else begin
        // the last packet is dropped, the one after it ends the stream
        stall = 1;
        while (!ok && k < 1000000) begin
          @(posedge clk); k = k + 1;
          if (overflows > overflows0 && dut.state == 5 && dut.left <= eff && dut.left > 0) ok = 1;
        end
        stall = 0;
      end
      if (!ok) begin errors = errors + 1; $display("fill stream %0d: never dropped with the fifo full", id); end
      k = 0;
      while (!ended && k < 400000) begin @(posedge clk); k = k + 1; end
      stall = 0;
      end_stream(id, !stopit);
      if (overflows - overflows0 == 0) begin
        errors = errors + 1; $display("fill stream %0d: the fifo never filled", id);
      end
      cov_fill = cov_fill + 1;
      directed = 0;
    end
  endtask

  // -- streams --------------------------------------------------------------------------
  integer s_i, life, k, by_count, overflows_fill;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;

    // an invalid configuration must not start a stream
    bad_start(0, 1); bad_start(3, 3); bad_start(4, 2); bad_start(15, 1);
    bad_start(1, 0); bad_start(2, 0);

    // stop while waiting for a start time: no packet at all
    begin_stream(1, 1, 64, 0, 1, st + 100000);
    repeat (30) @(posedge clk);
    if (!running) begin errors = errors + 1; $display("a timed start did not arm"); end
    end_stream(0, 0);
    if (ended) begin errors = errors + 1; $display("a stream stopped before its start time sent a packet"); end

    // stop at START, before the first header: one header-only END_OF_BURST
    stop_at_start(1);

    // count reached exactly at a packet boundary, over both formats,
    // both channel counts, and both spp clamps
    counted(2, 1, 13'd32, 32'd96, 2);         // sc12 1ch
    counted(1, 3, 13'd8191, 32'd4092, 3);     // sc16 2ch, spp clamped to a full packet
    counted(2, 2, 13'd1, 32'd48, 4);          // sc12, one channel, spp clamped up to 16

    // a start while a stream runs is ignored: no second START_OF_BURST, no
    // sequence restart (the checker would flag either)
    begin_stream(1, 1, 13'd64, 0, 0, 0);
    k = 0;
    while (npkts < 2 && k < 100000) begin @(posedge clk); k = k + 1; end
    if (!running) begin errors = errors + 1; $display("stream 5: not running before the start pulse"); end
    start <= 1; @(posedge clk); start <= 0;
    cov_start_busy = cov_start_busy + 1;
    repeat (100) @(posedge clk);
    end_stream(5, 0);

    // the fifo fills: the packet after the last drop is a data packet with
    // END_OF_BURST and OVERFLOW; a stop in DROP gives the same in a
    // header-only packet
    fill(0, 6);
    fill(1, 7);
    stall = 0;

    overflows_fill = overflows;

    // -- random streams -----------------------------------------------------------------
    for (s_i = 0; s_i < STREAMS; s_i = s_i + 1) begin
      format   = s_i % 2 ? 1 : 2;
      channels = s_i % 3 == 0 ? 3 : 1 + rnd(3);
      case (s_i % 4)
        0: spp = 8191;                          // above a full packet
        1: spp = 1 + rnd(4);                    // below the 16 clamp
        default: spp = 1 + rnd(3000);
      endcase
      eff = clamp_spp(spp, format, channels);
      begin_stream(format, channels, spp,
        (s_i % 4 == 2) ? eff * (1 + rnd(4)) : (rnd(4) == 0 ? 0 : 1 + rnd(20000)),
        (s_i % 3 == 0) ? 1 : rnd(2),
        st + (s_i % 3 == 0 ? 1 + rnd(3000) : rnd(3000)));
      scramble = 1;
      if (s_i % 2 == 1) begin
        // a start while the stream runs must be ignored (if the stream has
        // already ended there is nothing to test: skip it)
        k = 0;
        while (npkts < 1 && running && k < 200000) begin @(posedge clk); k = k + 1; end
        if (running) begin
          start <= 1; @(posedge clk); start <= 0;
          cov_start_busy = cov_start_busy + 1;
        end
      end
      life = count == 0 || rnd(4) == 0 ? 2000 + rnd(40000) : -1;     // stop after `life` cycles
      while (!ended && (life != 0)) begin @(posedge clk); if (life > 0) life = life - 1; end
      by_count = count != 0 && life < 0;
      end_stream(100 + s_i, by_count);
    end

    // -- coverage -----------------------------------------------------------------------
    cover(cov_no_packet,      "stop in ARMED with no packet");
    cover(cov_start_stop,     "stop at START with a header-only END_OF_BURST");
    cover(cov_drop_stop,      "stop in DROP");
    cover(cov_drop_last_data, "OVERFLOW on the last packet (data END_OF_BURST)");
    cover(cov_drop_last_hdr,  "OVERFLOW on the last packet (header-only END_OF_BURST)");
    cover(cov_boundary,       "count reached exactly at a packet boundary");
    cover(cov_spp_full,       "spp clamped down to a full packet");
    cover(cov_spp_small,      "spp clamped up to 16");
    cover(cov_sc12,           "sc12");
    cover(cov_sc16,           "sc16");
    cover(cov_ch1,            "one channel");
    cover(cov_ch2,            "two channels");
    cover(cov_wait,           "a timed start that waits");
    cover(cov_start_busy,     "a start while a stream runs");
    cover(cov_bad_cfg,        "an invalid configuration that must not start");
    cover(cov_fill,           "a stream that overflows the full fifo");
    if (SLOW && overflows == overflows_fill) begin errors = errors + 1; $display("SLOW run without a dropped packet"); end
    if (!SLOW && overflows != overflows_fill) begin errors = errors + 1; $display("%0d samples dropped with a fast reader", overflows - overflows_fill); end
    if (npackets != written) begin errors = errors + 1; $display("%0d packets written, %0d read", written, npackets); end
    $display("%0d streams, %0d packets, %0d samples dropped, %0d samples taken", STREAMS, npackets, overflows, tooks);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  // the configuration inputs change at random while a stream runs (on the
  // falling edge, so a change can never land in the same edge as a start
  // strobe: the framer would then latch the scrambled values)
  always @(negedge clk) if (scramble && rnd(50) == 0) begin
    format <= rnd(4); channels <= rnd(4); spp <= rnd(8192);
    timed <= rnd(2); at <= {$random(seed), $random(seed)};
  end

  // a broken design floods: stop at 20 errors
  always @(posedge clk) if (errors > 20) begin
    $display("RESULT: FAIL (stopped after 20 errors)"); $finish;
  end

  // -- faults ---------------------------------------------------------------------------
  // an invalid start must not be taken; with this fault the check is off
  initial if (FAULT == 3) force dut.cfg_ok = 1'b1;
endmodule

`default_nettype wire
