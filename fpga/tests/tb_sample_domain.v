// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_sample_domain - sample_domain on a 61.44 MHz clock with its two
// cdc_fifos and gray_syncs to a 100 MHz bus clock.
//
// Phase 1, rx_source pattern: every rx value must be f(time) and times
// contiguous; a bus-side stall must lose samples, the time gap must equal
// the cdc_lost count; a time set must step the stream from the old time to
// exactly the new one. The bus-side copy of `now` must never run ahead of
// the counter and lag it by at most a few ticks.
// Phase 2, rx_source loopback: bursts of samples {0xABC, burst, index} go out on
// tx and come back on rx with the tick they played at. Checked: a timed
// burst's first sample at exactly its time and nothing of it earlier;
// late bursts (time passed) never play and count as LATE; samples of a
// burst contiguous except across an intended pause (counted UNDERFLOW,
// once, and then no BURST_ACK: the samples after the gap played shifted);
// an END_OF_BURST without a sample ends a burst; only a burst that played
// without a gap counts one BURST_ACK; a header-only END_OF_BURST in idle
// counts nothing; a discarded (LATE) burst that never sends its
// END_OF_BURST does not swallow the next burst (the next START_OF_BURST
// resyncs); tx_active is low while the DAC is silent in a gap.
// Phase 3, directed burst rules, each checked by its own counter deltas
// (ack, underflow, late) and named on failure; `d_cases` counts the cases
// that ran and must equal D_CASES:
//   d1 untimed START_OF_BURST during a gapped burst: new burst acked
//   d2 timed START_OF_BURST during a gapped burst, reaching the head at
//      exactly its time: plays at its time, acked
//   d3 timed START_OF_BURST during a gapped burst, time ahead: waits with
//      DAC 0 and tx_active low, plays at its time, acked
//   d4 timed START_OF_BURST during a gapped burst, time passed: LATE
//   d5 untimed START_OF_BURST during a clean burst: one ack (the new one)
//   d6 abort entry after a clean burst: burst ends, no ack, no underflow
//   d7 abort entry in idle: nothing
//   d8 abort entry while discarding a LATE burst: idle, next burst acked
//   d9 single-sample burst (START_ and END_OF_BURST on one entry) in idle:
//      acked; d10 the same during a gapped burst: acked
//   d11 reset (srst and rst) in a burst's underflow gap, d12 reset while a
//      burst plays: the edge after shows the reset values (idle, tx_active
//      0, dac 0, now_gray 0, event counts kept); the cut-off burst gets no
//      ack, and traffic after the reset is checked as before
// Throughout phases 1-3 the DAC is checked after every strobe: it must hold
// the sample that strobe played (the loopback's value; 0 in phase 1), and 0
// in idle, in gaps, while a timed burst waits and during LATE discards
// (each of those seen at least once).
// STB = 1: a strobe every cycle (1 channel); 2: every other cycle.
// FAULT 1: the rx FIFO drops one entry silently (must be caught).
// FAULT 2: one timed burst plays one tick early (must be caught).
// FAULT 3: the model counts an ACK for a burst it paused (a wrong model;
// there is none, and the bench must say so).
// FAULT 4: the feeder clears sob on the abort entry, so sample_domain
// sees a plain header-only END_OF_BURST (abort handling lost; must be
// caught).
// FAULT 5: `fresh` forced to "not in a burst": a START_OF_BURST during a
// burst no longer clears the old burst's gap, and the abort entry acks
// (rule 1 and abort handling lost in the RTL; must be caught).
`timescale 1ns/1ps
`default_nettype none

module tb_sample_domain;
  parameter SEED = 1, STB = 1, BURSTS = 120, FAULT = 0;

  reg clk = 0, sclk = 0;
  always #5 clk = ~clk;
  always #8.138 sclk = ~sclk;          // 61.44 MHz
  reg rst = 1, srst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  // -- strobe ------------------------------------------------------------------------------
  reg stb = 0;
  always @(posedge sclk) stb <= srst ? 1'b0 : STB == 1 ? 1'b1 : !stb;   // held off in reset, as the top does

  // -- design -------------------------------------------------------------------------------
  reg  [1:0]   rx_source = 1;
  reg  [63:0]  time_set = 0;
  reg          time_req = 0;
  wire         time_ack, rx_valid_s, rx_full, tx_valid_s, tx_take, tx_active;
  wire [111:0] rx_entry_s, rx_entry;
  wire [115:0] tx_entry_s;
  wire [63:0]  now_gray, now_b;
  wire [15:0]  cdc_lost_g, underflow_g, late_g, burst_ack_g;
  wire [47:0]  dac;
  sample_domain dut (.sclk(sclk), .srst(srst), .stb(stb), .adc(48'hBAD_BAD_BAD_BAD), .dac(dac), .rx_source_async(rx_source),
    .time_set(time_set), .time_req(time_req), .time_ack(time_ack), .now_gray(now_gray),
    .rx_valid(rx_valid_s), .rx_entry(rx_entry_s), .rx_full(rx_full),
    .tx_valid(tx_valid_s), .tx_entry(tx_entry_s), .tx_take(tx_take),
    .cdc_lost_gray(cdc_lost_g), .underflow_gray(underflow_g), .late_gray(late_g), .burst_ack_gray(burst_ack_g), .tx_active(tx_active));

  reg          fault_drop = 0;
  wire         rx_valid;
  reg          rx_take = 0;
  cdc_fifo #(.W(112), .AW(4)) rxf (.wclk(sclk), .w_rst(srst), .w_valid(rx_valid_s && !fault_drop), .w_data(rx_entry_s),
    .w_full(rx_full), .rclk(clk), .r_rst(rst), .r_valid(rx_valid), .r_data(rx_entry), .r_take(rx_take));
  // the bus side's feeder: one entry per bus cycle from a queue, as fast as
  // tx_deframer (100 M/s > 61.44 M/s)
  reg  [115:0] txq [0:1023];
  integer      txq_w = 0, txq_r = 0;
  wire         tx_valid = txq_r != txq_w;
  wire [115:0] tx_entry = txq[txq_r % 1024];
  wire         tx_full;
  always @(posedge clk) if (tx_valid && !tx_full) txq_r <= txq_r + 1;   // after the FIFO sampled w_data
  cdc_fifo #(.W(116), .AW(4)) txf (.wclk(clk), .w_rst(rst), .w_valid(tx_valid), .w_data(tx_entry), .w_full(tx_full),
    .rclk(sclk), .r_rst(srst), .r_valid(tx_valid_s), .r_data(tx_entry_s), .r_take(tx_take));
  gray_sync #(.W(64)) g_now (.clk(clk), .g_in(now_gray), .b(now_b));
  // four independent 16-bit Gray counters: each converted on its own
  function [15:0] gray16(input [15:0] b); gray16 = b ^ (b >> 1); endfunction
  function [15:0] bin16(input [15:0] g); integer i; begin bin16[15] = g[15]; for (i = 14; i >= 0; i = i - 1) bin16[i] = bin16[i+1] ^ g[i]; end endfunction
  reg [63:0] cg1, cg2;
  always @(posedge clk) begin cg1 <= {cdc_lost_g, underflow_g, late_g, burst_ack_g}; cg2 <= cg1; end
  wire [15:0] cdc_lost = bin16(cg2[63:48]), unders = bin16(cg2[47:32]), lates = bin16(cg2[31:16]), burst_acks = bin16(cg2[15:0]);

  function [11:0] f(input [63:0] t, input integer k);
    case (k) 0: f = t[11:0]; 1: f = ~t[11:0]; 2: f = t[11:0] * 7; default: f = t[11:0] * 13 + 5; endcase
  endfunction

  // -- the bus-side copy of now: never ahead, never far behind --------------------------------------
  integer settled = 0;
  always @(posedge clk) if (!rst && settled > 8) begin
    if (now_b > dut.now || dut.now - now_b > 8) begin
      errors = errors + 1; if (errors < 10) $display("%0t now copy %0d, now %0d", $time, now_b, dut.now);
    end
  end
  always @(posedge clk) settled = time_ack != time_req || rst ? 0 : settled + 1;

  // -- rx side: take every entry; phase 1 checks the pattern, phase 2 the bursts ---------------------
  reg [63:0] next_t = 0;
  reg        have_t = 0, stall = 0, allow_gap = 0;
  integer    phase = 1, gap_total = 0;
  reg [63:0] jump_to = 0;
  reg        jump = 0;
  always @(posedge clk) begin
    if (!rst && rx_take && rx_valid) rx_entry_check(rx_entry);
    rx_take <= !stall;
  end
  task rx_entry_check(input [111:0] e);
    reg [63:0] t;
    reg [47:0] s;
    begin
      t = e[111:48]; s = e[47:0];
      if (have_t && t != next_t) begin
        if (jump && t == jump_to) jump = 0;
        else if (t > next_t && allow_gap) gap_total = gap_total + (t - next_t);
        else begin errors = errors + 1; if (errors < 10) $display("%0t rx time %0d, expected %0d", $time, t, next_t); end
      end
      have_t = 1; next_t = t + 1;
      if (phase == 1 && s !== {f(t, 3), f(t, 2), f(t, 1), f(t, 0)}) begin
        errors = errors + 1; if (errors < 10) $display("%0t rx at %0d: %h", $time, t, s);
      end
      if (phase == 2) burst_check(t, s);
    end
  endtask

  // -- the DAC: after every strobe it holds what that strobe played -------------------------------------
  // In loopback (phases 2, 3) the rx entry of a strobe carries the sample
  // played at it (0 if none), and the burst checks prove those values; dac
  // must then equal that value from the edge on. Phase 1 plays nothing: 0.
  // Classified from ports (and dut.state) at the strobe, the value must also
  // be 0 in idle with nothing queued, in an underflow gap, while a timed
  // START_OF_BURST waits, and while a LATE burst is discarded; each class
  // must have been seen (dac_zero), and played samples too (dac_play).
  reg [47:0] dac_exp = 0;
  reg        dac_chk = 0;
  integer    dac_play = 0, dac_zero [0:3];
  initial begin dac_zero[0] = 0; dac_zero[1] = 0; dac_zero[2] = 0; dac_zero[3] = 0; end
  wire [63:0] now_s  = rx_entry_s[111:48];
  wire        h_wait = tx_valid_s && tx_entry_s[114] && tx_entry_s[112] && tx_entry_s[111:48] > now_s;
  always @(posedge sclk) begin
    if (dac_chk && dac !== dac_exp) begin
      errors = errors + 1; if (errors < 10) $display("%0t dac %h, expected %h", $time, dac, dac_exp);
    end
    dac_chk <= 0;
    if (stb && !srst && (phase == 1 || phase >= 2)) begin
      dac_exp <= phase == 1 ? 48'd0 : rx_entry_s[47:0]; dac_chk <= 1;
      if (phase >= 2) begin : classify
        integer c;
        c = dut.state == 0 && !tx_valid_s ? 0 :           // idle, nothing queued
            dut.state == 1 && !tx_valid_s ? 1 :           // underflow gap
            h_wait                        ? 2 :           // timed START_OF_BURST waits
            dut.state == 2                ? 3 : -1;       // LATE burst discarded
        if (c >= 0) begin
          if (rx_entry_s[47:0] != 0) begin
            errors = errors + 1; if (errors < 10) $display("%0t played %h in dac class %0d", $time, rx_entry_s[47:0], c);
          end
          dac_zero[c] = dac_zero[c] + 1;
        end
        if (rx_entry_s[47:0] != 0) dac_play = dac_play + 1;
      end
    end
  end

  // -- phase 2: expected bursts --------------------------------------------------------------------
  integer    b_n [0:BURSTS-1], b_pause [0:BURSTS-1];
  reg [63:0] b_t [0:BURSTS-1];
  reg        b_timed [0:BURSTS-1], b_late [0:BURSTS-1];
  integer    cur = 0, idx = 0, exp_late = 0, exp_ack = 0, exp_under = 0, gen_done = 0, prev6 = 0;
  reg [63:0] last_play = 0;
  task burst_check(input [63:0] t, input [47:0] s);
    integer b, i;
    begin
      if (s != 0) begin
        b = s[35:24]; i = s[23:0];
        while (cur < BURSTS && b_late[cur]) cur = cur + 1;     // late bursts never play
        if (s[47:36] != 12'hABC || b != cur || i != idx) begin
          errors = errors + 1; if (errors < 10) $display("%0t played %h at %0d, expected burst %0d sample %0d", $time, s, t, cur, idx);
        end else begin
          if (i == 0 && b_timed[b] && t != b_t[b]) begin
            errors = errors + 1; $display("%0t burst %0d started at %0d, its time %0d", $time, b, t, b_t[b]);
          end
          if (i > 0 && t != last_play + 1 && b_pause[b] != i) begin
            errors = errors + 1; $display("%0t burst %0d sample %0d at %0d after %0d without a pause", $time, b, i, t, last_play);
          end
        end
        last_play = t; idx = idx + 1;
        if (idx == b_n[cur]) begin cur = cur + 1; idx = 0; end
      end
    end
  endtask

  task push(input p, input sob, input eob, input tm, input [63:0] t, input [47:0] d);
    begin
      if (FAULT == 4 && !p && sob && eob) sob = 0;                       // the abort entry loses its sob
      while (txq_w - txq_r >= 1000) @(posedge clk);
      txq[txq_w % 1024] = {p, sob, eob, tm, t, d}; txq_w = txq_w + 1;
    end
  endtask

  // -- phase 3: directed burst rules ----------------------------------------------------------------
  // every sample sent in phase 3 is {0xDEF, case, index}; the sclk side
  // records the tick a watched sample plays at and counts each case's plays
  localparam D_CASES = 12;
  reg [47:0] watch = 0;
  reg [63:0] watch_t = 0;
  reg        watch_seen = 0;
  integer    played3 [0:15], d_cases = 0, a0 = 0, u0 = 0, l0 = 0, chk = 0, k3;
  initial for (k3 = 0; k3 < 16; k3 = k3 + 1) played3[k3] = 0;
  always @(posedge sclk) if (stb && dut.play && phase == 3) begin
    if (dut.e_data == watch) begin watch_t = dut.now; watch_seen = 1; end
    if (dut.e_data[47:36] == 12'hDEF) played3[dut.e_data[27:24]] = played3[dut.e_data[27:24]] + 1;
  end
  // (re-forced, with a constant, at every state change: iverilog evaluates
  // a force's right side only once)
  always @(dut.state) if (FAULT == 5) begin
    if (dut.state != 2'd1) force dut.fresh = 1'b1; else force dut.fresh = 1'b0;
  end

  // samples from..from+n-1 of case c; sob/timed on the first, eob on the last
  task d_burst(input integer c, input integer from, input integer n, input sob, input tm, input [63:0] at, input eob);
    integer j;
    for (j = from; j < from + n; j = j + 1)
      push(1, sob && j == from, eob && j == from + n - 1, tm && j == from, at, {12'hDEF, c[11:0], j[23:0]});
  endtask
  task d_abort; push(0, 1, 1, 0, 0, 0); endtask
  task d_dry;                    // the feeder runs dry inside the burst: one underflow
    begin while (tx_valid || tx_valid_s) @(posedge clk); repeat (100 * STB) @(posedge clk); end
  endtask
  task d_idle;
    begin
      while (dut.state != 0 || tx_valid || tx_valid_s) @(posedge clk);
      repeat (20) @(posedge clk);
    end
  endtask
  task d_start; begin d_idle; a0 = burst_acks; u0 = unders; l0 = lates; end endtask
  task d_check(input integer c, input integer da, input integer du, input integer dl);
    begin
      d_idle;
      d_cases = d_cases + 1;
      if (burst_acks - a0 != da || unders - u0 != du || lates - l0 != dl) begin
        errors = errors + 1;
        $display("d%0d: ack +%0d underflow +%0d late +%0d, expected +%0d +%0d +%0d", c,
                 burst_acks - a0, unders - u0, lates - l0, da, du, dl);
      end
    end
  endtask
  task d_at(input integer c, input [63:0] at);   // the watched sample played at `at`
    if (!watch_seen || watch_t != at) begin
      errors = errors + 1; $display("d%0d: burst started at %0d (seen %b), its time %0d", c, watch_t, watch_seen, at);
    end
  endtask
  task d_plays(input integer c, input integer n);
    if (played3[c] != n) begin errors = errors + 1; $display("d%0d: %0d samples played, expected %0d", c, played3[c], n); end
  endtask

  // reset everything (srst and the bus side's rst, as the top does) and
  // check the edge after: idle, tx_active 0, dac 0, now 0 (now_gray 0),
  // the event counts unchanged (du underflows since d_start); the feeder's
  // pending entries are dropped and the rx stream restarts at time 0
  task d_reset(input integer c, input integer du);
    begin
      @(posedge sclk); #1 srst = 1; rst = 1; txq_w = txq_r;
      @(posedge sclk); #1;
      if (dut.state != 0 || tx_active || dac != 0 || now_gray != 0 ||
          {underflow_g, late_g, burst_ack_g} != {gray16(u0[15:0] + du[15:0]), gray16(l0[15:0]), gray16(a0[15:0])}) begin
        errors = errors + 1;
        $display("d%0d: after reset state %0d tx_active %b dac %h now_gray %h counts %h %h %h", c, dut.state, tx_active, dac,
                 now_gray, underflow_g, late_g, burst_ack_g);
      end
      // released as the top does (b210.v): both halves of each crossing held
      // until the other side's pointer copy is 0, the bus side first, srst
      // 2 - 3 sample clocks later
      repeat (20) @(posedge sclk); #1 have_t = 0; rst = 0;
      repeat (3) @(posedge sclk); #1 srst = 0;
      repeat (50) @(posedge clk);
      if (now_b > 64'd1_000_000) begin errors = errors + 1; $display("d%0d: time did not restart: %0d", c, now_b); end
    end
  endtask

  task phase3;
    reg [63:0] at;
    begin
      phase = 3;
      // d1: untimed START_OF_BURST during a gapped burst: the new burst is acked
      d_start; d_burst(1, 0, 40, 1, 0, 0, 0); d_dry; d_burst(1, 40, 40, 1, 0, 0, 1);
      d_check(1, 1, 1, 0); d_plays(1, 80);
      // d2: timed START_OF_BURST during a gapped burst, at the head exactly at
      // its time: the old burst resumes contiguously after the gap, so its
      // sample 20 + k plays at t20 + k, and the new burst queued behind
      // sample 619 reaches the head at t20 + 600
      d_start; d_burst(2, 0, 20, 1, 0, 0, 0); d_dry;
      watch = {12'hDEF, 12'd2, 24'd20}; watch_seen = 0;
      d_burst(2, 20, 600, 0, 0, 0, 0);
      wait (watch_seen); at = watch_t + 600;
      watch = {12'hDEF, 12'd2, 24'd1000}; watch_seen = 0;
      d_burst(2, 1000, 40, 1, 1, at, 1);
      d_check(2, 1, 1, 0); d_at(2, at); d_plays(2, 660);
      // d3: timed START_OF_BURST during a gapped burst, time ahead: it ends the
      // old burst and waits with the DAC at 0 and tx_active low
      d_start; d_burst(3, 0, 20, 1, 0, 0, 0); d_dry;
      at = now_b + 400; watch = {12'hDEF, 12'd3, 24'd20}; watch_seen = 0;
      d_burst(3, 20, 30, 1, 1, at, 1);
      // the new burst reaches the head (and the old burst must be over)
      while (!tx_valid_s) @(posedge clk);
      repeat (4) @(posedge clk);
      chk = 0;
      while (dut.now + 4 < at) begin
        if (tx_active || dac != 0 || dut.state != 0) begin
          errors = errors + 1;
          if (errors < 10) $display("d3: state %0d tx_active %b dac %h while waiting", dut.state, tx_active, dac);
        end
        chk = chk + 1; @(posedge clk);
      end
      if (chk < 100) begin errors = errors + 1; $display("d3: waited only %0d cycles", chk); end
      d_check(3, 1, 1, 0); d_at(3, at); d_plays(3, 50);
      // d4: timed START_OF_BURST during a gapped burst, time passed: LATE
      d_start; d_burst(4, 0, 20, 1, 0, 0, 0); d_dry;
      d_burst(4, 20, 30, 1, 1, now_b - 50, 1);
      d_check(4, 0, 1, 1); d_plays(4, 20);
      // d5: untimed START_OF_BURST during a clean burst: only the new burst acks
      d_start; d_burst(5, 0, 30, 1, 0, 0, 0); d_burst(5, 30, 30, 1, 0, 0, 1);
      d_check(5, 1, 0, 0); d_plays(5, 60);
      // d6: abort entry right after a clean burst's samples: the burst ends
      // at once, with no ack and no underflow
      d_start; d_burst(6, 0, 30, 1, 0, 0, 0); d_abort;
      d_check(6, 0, 0, 0); d_plays(6, 30);
      // d7: abort entry in idle: nothing
      d_start; d_abort; d_check(7, 0, 0, 0);
      // d8: abort entry while a LATE burst (no END_OF_BURST) is discarded:
      // idle again, the next burst plays and acks
      d_start; d_burst(8, 0, 30, 1, 1, now_b - 50, 0);
      while (dut.state != 2) @(posedge clk);
      d_abort; d_burst(8, 30, 10, 1, 0, 0, 1);
      d_check(8, 1, 0, 1); d_plays(8, 10);
      // d9: one-sample burst in idle: acked
      d_start; d_burst(9, 0, 1, 1, 0, 0, 1); d_check(9, 1, 0, 0); d_plays(9, 1);
      // d10: one-sample burst during a gapped burst: acked
      d_start; d_burst(10, 0, 20, 1, 0, 0, 0); d_dry; d_burst(10, 20, 1, 1, 0, 0, 1);
      d_check(10, 1, 1, 0); d_plays(10, 21);
      // d11: reset in a burst, in an underflow gap; the cut-off burst gets no
      // ack, a burst after the reset plays and acks
      d_start; d_burst(11, 0, 20, 1, 0, 0, 0); d_dry;
      if (dut.state != 1 || !dut.gap) begin errors = errors + 1; $display("d11: not in a gap before the reset"); end
      d_reset(11, 1);
      d_burst(11, 20, 30, 1, 0, 0, 1);
      d_check(11, 1, 1, 0); d_plays(11, 50);
      // d12: reset while a burst plays (no gap): the queued rest is dropped
      d_start; d_burst(12, 0, 900, 1, 0, 0, 1);
      while (played3[12] < 100) @(posedge clk);
      if (dut.state != 1 || !tx_active) begin errors = errors + 1; $display("d12: not playing before the reset"); end
      d_reset(12, 0);
      d_check(12, 0, 0, 0);
      if (played3[12] >= 900) begin errors = errors + 1; $display("d12: the whole burst played"); end
      if (d_cases != D_CASES) begin errors = errors + 1; $display("phase 3: %0d of %0d cases ran", d_cases, D_CASES); end
      if (dac_play == 0 || dac_zero[0] == 0 || dac_zero[1] == 0 || dac_zero[2] == 0 || dac_zero[3] == 0) errors = errors + 1;
      $display("phase 3: %0d directed cases; dac checked: %0d played, 0 in idle %0d, gap %0d, wait %0d, discard %0d",
               d_cases, dac_play, dac_zero[0], dac_zero[1], dac_zero[2], dac_zero[3]);
    end
  endtask

  // -- run --------------------------------------------------------------------------------------
  integer k, b, i, kind, cdc_lost0;
  reg [63:0] t;
  initial begin
    repeat (4) @(posedge sclk); srst = 0;
    repeat (4) @(posedge clk); rst = 0;
    // phase 1: pattern, a stall, a time set
    repeat (3000) @(posedge clk);
    cdc_lost0 = cdc_lost;
    allow_gap = 1;
    stall = 1; repeat (200 + rnd(500)) @(posedge clk); stall = 0;
    repeat (2000) @(posedge clk);
    allow_gap = 0;
    if (cdc_lost == cdc_lost0) begin errors = errors + 1; $display("stall lost nothing"); end
    if (gap_total != cdc_lost - cdc_lost0) begin errors = errors + 1; $display("time gaps %0d, lost %0d", gap_total, cdc_lost - cdc_lost0); end
    time_set = 64'h0000_0123_FFFF_FF00; jump_to = time_set; jump = 1;
    time_req = !time_req;
    wait (time_ack == time_req);
    repeat (2000) @(posedge clk);
    if (jump) begin errors = errors + 1; $display("time set never seen in the rx stream"); end
    if (FAULT == 1) begin @(posedge sclk); fault_drop = 1; @(posedge sclk); fault_drop = 0; repeat (500) @(posedge clk); end

    // phase 2: loopback bursts
    phase = 0; rx_source = 2; repeat (50) @(posedge clk); phase = 2;   // no value check while rx_source crosses
    for (b = 0; b < BURSTS; b = b + 1) begin
      // sample_domain idle (or discarding: a late burst without its END_OF_BURST
      // leaves it there, and the next START_OF_BURST is what resyncs it) and
      // the FIFO empty: bursts do not overlap
      while ((dut.state != 0 && dut.state != 2) || tx_valid_s || tx_valid) @(posedge clk);
      // 0 untimed, 1 timed, 2 late, 3 pause, 4 EOB as its own entry,
      // 5 timed + pause, 6 late without an END_OF_BURST (the next burst must resync)
      kind = prev6 ? 0 : rnd(7);     // after a discarded burst without EOB, an untimed one
      prev6 = kind == 6;
      if (FAULT == 2 && b == 7) kind = 1;
      b_n[b] = 1 + rnd(300);
      b_timed[b] = kind == 1 || kind == 2 || kind == 5 || kind == 6;
      b_late[b] = kind == 2 || kind == 6;
      b_pause[b] = (kind == 3 || kind == 5) && b_n[b] > 2 ? 1 + rnd(b_n[b] - 1) : -1;
      b_t[b] = kind == 2 || kind == 6 ? now_b - 20 - rnd(1000) : now_b + 300 + rnd(3000);
      if (b_late[b]) exp_late = exp_late + 1;
      else if (b_pause[b] < 0 && kind != 4) exp_ack = exp_ack + 1;      // a gap or an EOB-only wait: no ack
      if (b_pause[b] > 0 && !b_late[b]) exp_under = exp_under + 1;
      if (kind == 4 && !b_late[b]) exp_under = exp_under + 1;           // the burst waits for its EOB
      for (i = 0; i < b_n[b]; i = i + 1) begin
        if (i == b_pause[b]) begin                                     // the FIFO runs dry: underflow
          while (dut.state != 1 || tx_valid) @(posedge clk);
          repeat (100 * STB) @(posedge clk);
          if (tx_active) begin errors = errors + 1; $display("%0t tx_active with no sample to play", $time); end
        end
        push(1, i == 0, i == b_n[b] - 1 && kind != 4 && kind != 6, i == 0 && b_timed[b],
             (FAULT == 2 && b == 7 && i == 0) ? b_t[b] - 1 : b_t[b], {12'hABC, b[11:0], i[23:0]});
      end
      if (kind == 4) begin
        while (tx_valid) @(posedge clk);
        repeat (100 * STB + 50) @(posedge clk); push(0, 0, 1, 0, 0, 0);
      end
    end
    // a header-only END_OF_BURST in idle plays nothing and counts no ack
    while (dut.state != 0 || tx_valid_s || tx_valid) @(posedge clk);
    push(0, 0, 1, 0, 0, 0);
    while (tx_valid_s || tx_valid) @(posedge clk);
    repeat (20) @(posedge clk);
    // drained: the feeder queue, the crossing and sample_domain all empty (IDLE,
    // or DISCARD after a late burst that sent no END_OF_BURST)
    while (tx_valid || (dut.state != 0 && dut.state != 2) || tx_valid_s) @(posedge clk);
    repeat (20) @(posedge clk);
    while (dut.state != 0 || tx_valid_s) @(posedge clk);
    repeat (200) @(posedge clk);
    while (cur < BURSTS && b_late[cur]) cur = cur + 1;
    if (cur != BURSTS) begin errors = errors + 1; $display("%0d bursts played, %0d expected", cur, BURSTS); end
    if (FAULT == 3) exp_ack = exp_ack + 1;                  // a wrong model must be caught
    if (lates != exp_late || burst_acks != exp_ack || unders != exp_under) begin
      errors = errors + 1;
      $display("late %0d ack %0d underflow %0d, expected %0d %0d %0d", lates, burst_acks, unders, exp_late, exp_ack, exp_under);
    end
    $display("%0d bursts: %0d late, %0d acks, %0d underflows; %0d samples lost in the stall", BURSTS, lates, burst_acks, unders, cdc_lost);
    // phase 3: directed burst rules, checked by deltas
    phase3;
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
