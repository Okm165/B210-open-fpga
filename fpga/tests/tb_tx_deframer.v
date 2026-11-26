// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_tx_deframer - tx packets -> packet_fifo -> tx_deframer, every output
// entry compared with an independently computed model of what the packet
// must produce.
//
// The model (build / fill / expect / seq_model) holds the expected sample
// stream in a queue and the expected counters; the DUT's stream and counters
// are compared with those. Apart from the FAULT 2-4 injections below, the only
// DUT internal the bench reads is `state`, for the state-coverage check.
//
// The rules the model states, each also driven by a directed packet at the
// start of the run (see task directed):
//   - bad_packets rises once per malformed packet: wrong version/type/
//     format/channels, a reserved bit set, a length outside 16 .. 16384, a
//     length that is not a whole number of sample times, or a buffer that
//     ends before its last sample time. Such a packet plays only the complete
//     sample times it holds (usually none) and never an END_OF_BURST.
//   - a packet rejected by the header rule changes neither the burst nor the
//     sequence expectation: a good packet right after a bad one is compared
//     with the same expected sequence, so dropping a bad packet must not show
//     up as seq_errors. A cut-short packet is the other kind of bad packet:
//     its header was good, so its sequence is consumed and its complete
//     sample times play.
//   - seq_errors counts a jump only within a burst and never on a
//     START_OF_BURST packet: a burst may begin at any sequence, and a jump
//     across a burst boundary is not an error.
//   - HAS_TIME without START_OF_BURST is ignored: s_timed stays 0.
//   - a header-only START_OF_BURST without END_OF_BURST (L = 16) is
//     malformed: bad_packets + 1, no entry, and neither the burst nor the
//     sequence expectation moves (directed both outside and inside a burst).
//   - a header-only END_OF_BURST makes one entry with s_present = 0 and no
//     sample; outside a burst that is all it does. With START_OF_BURST as
//     well, during a burst, that entry is the abort entry {0, 1, 1}.
//   - a cut-short packet in an open burst (it opened it or continues it,
//     with or without END_OF_BURST) is followed by the abort entry and
//     closes the burst: the next packet's sequence is not compared. Outside
//     a burst nothing follows its samples.
//   - a header-only packet with no flag is legal and plays nothing.
//   - reset in flight (halfway through the random packets): with a burst's
//     packet stalled (s_valid high, s_full held), one rst cycle of ring and
//     tx_deframer must leave s_valid 0 and r_take 0 the cycle after, the
//     counters unchanged; the model drops its pending entries and closes
//     its burst, and everything after is checked as before (cov_reset).
//
// tx_deframer has no overflow-on-last-packet logic: OVERFLOW is an rx-only
// flag (PROTOCOL.md 2) and is ignored on a tx packet. The bench sends one
// with the bit set and counts it in cov_ovf; it must play as if it were 0.
//
// Coverage: every state must be entered (state_seen) and every output kind
// must occur at least once (cov_sobt, cov_sobu, cov_eobonly, cov_abort,
// cov_ovf and bad_packets); each burst-rule case must have been modelled
// (cov_cut_open, cov_cut_eob, cov_hdr_abort, cov_sob_empty, cov_orphan);
// the run fails and names whatever never ran.
//
// FAULT 1: a bit is flipped in the ring 30 words ahead of the reader. The
//          bench must catch it as a wrong sample value (or, if the bit lands
//          in a header, a packet that turns bad).
// FAULT 2: START_OF_BURST is made to lose `first_sample` in state CHECK (2),
//          so one entry's s_sob is missing; the bench must catch that entry.
// FAULT 3: abort handling disabled (`open` forced 0, `abort` forced 0): a
//          cut-short packet leaves its burst open and a header-only
//          START_OF_BURST + END_OF_BURST makes a plain END_OF_BURST entry.
// FAULT 4: the header-only START_OF_BURST rule disabled (`sob_empty`
//          forced 0): such a packet is accepted and opens a burst.
`timescale 1ns/1ps
`default_nettype none

module tb_tx_deframer;
  parameter N = 600, SEED = 1, FAULT = 0;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  integer errors = 0, seed = SEED;
  function integer rnd(input integer m); rnd = ($random(seed) & 32'h7fffffff) % m; endfunction

  // -- design ---------------------------------------------------------------------------
  localparam S_IDLE = 0, S_HEAD = 1, S_CHECK = 2, S_BODY = 3, S_SKIP = 4, S_EOB_ONLY = 5;
  wire        w_room, r_avail, r_last, r_take, s_valid, s_present, s_sob, s_eob, s_timed;
  wire [31:0] r_data, bad_packets, seq_errors;
  wire [63:0] s_at;
  wire [47:0] s_data;
  reg         w_valid = 0, w_last = 0, s_full = 1;
  reg  [31:0] w_data = 0;
  packet_fifo #(.AW(14), .MAX(4096)) ring (.clk(clk), .rst(rst), .w_room(w_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .w_used(), .r_avail(r_avail), .r_data(r_data),
    .r_last(r_last), .r_take(r_take), .r_used());
  tx_deframer dut (.clk(clk), .rst(rst), .r_avail(r_avail), .r_data(r_data), .r_last(r_last), .r_take(r_take),
    .s_valid(s_valid), .s_full(s_full), .s_present(s_present), .s_sob(s_sob), .s_eob(s_eob),
    .s_timed(s_timed), .s_at(s_at), .s_data(s_data),
    .bad_packets(bad_packets), .seq_errors(seq_errors));

  // -- expected entries: {present, sob, eob, timed, time, data} ---------------------------
  localparam QN = 1 << 22;
  reg [115:0] q [0:QN-1];
  integer     qw = 0, qr = 0;
  integer     exp_bad = 0, exp_seq = 0, exp_sobt = 0, exp_sobu = 0, exp_eobonly = 0, exp_abort = 0;

  task expect(input p, input sob, input eob, input timed, input [63:0] t, input [47:0] dat);
    begin
      if (p) begin
        if (sob && timed) exp_sobt = exp_sobt + 1;
        else if (sob) exp_sobu = exp_sobu + 1;
      end else if (sob) exp_abort = exp_abort + 1;
      else if (eob) exp_eobonly = exp_eobonly + 1;
      q[qw % QN] = {p, sob, eob, timed, t, dat};
      qw = qw + 1;
    end
  endtask

  // -- packet construction ----------------------------------------------------------------
  integer     words = 0;         // words the packet occupies in the ring, padding included
  reg [31:0]  pkt [0:4300];
  reg [47:0]  edat [0:5460];     // expected s_data per sample time
  integer     vb = 16, nv = 2;   // bits per value, values per sample time

  task clear_pkt;
    integer j;
    begin for (j = 0; j < 4300; j = j + 1) pkt[j] = 0; end
  endtask

  // random 12-bit values; sc16 carries random junk in the 4 low bits of each
  // 16-bit field (they must be ignored)
  task fill(input integer fmt, input integer ch, input integer n);
    integer k, v, j, bit0;
    reg [11:0] val [0:3];
    reg [15:0] field;
    reg [3:0]  junk;
    begin
      for (k = 0; k < n; k = k + 1) begin
        for (v = 0; v < 4; v = v + 1) val[v] = $random(seed);
        for (v = 0; v < nv; v = v + 1) begin
          junk = rnd(16);
          field = vb == 16 ? {val[v], junk} : {4'd0, val[v]};
          bit0 = 128 + (k * nv + v) * vb;
          for (j = 0; j < vb; j = j + 1) pkt[(bit0 + j) / 32][(bit0 + j) % 32] = field[j];
        end
        edat[k] = ch == 3 ? {val[3], val[2], val[1], val[0]} :
                  ch == 1 ? {24'd0, val[1], val[0]} : {val[1], val[0], 24'd0};
      end
    end
  endtask

  // a well-formed packet of n sample times; corrupt pkt[] afterwards for a bad one
  task build(input integer fmt, input integer ch, input integer n, input integer sob,
             input integer eob, input integer ht, input [15:0] sq, input [63:0] t);
    reg [15:0] L;
    begin
      vb = fmt == 2 ? 12 : 16; nv = ch == 3 ? 4 : 2;
      L = 16 + n * vb * nv / 8;
      clear_pkt;
      pkt[0] = {4'd1, 2'd0, ch[1:0], fmt[3:0], 4'd1, L};
      pkt[1] = {12'd0, 1'b0, (eob ? 1'b1 : 1'b0), (sob ? 1'b1 : 1'b0), (ht ? 1'b1 : 1'b0), sq};
      pkt[2] = t[31:0]; pkt[3] = t[63:32];
      fill(fmt, ch, n);
      // S(L) of PROTOCOL.md 1: 4 * ceil(L/4), plus one word if that is a
      // multiple of 1024 bytes and not the full buffer
      words = (L + 3) >> 2;
      if (words % 256 == 0 && words != 4096) words = words + 1;
    end
  endtask

  integer cov_orphan = 0;        // samples with no START_OF_BURST and no burst open

  // -- the model of the sequence check (independent of the DUT) ---------------------------
  reg        m_burst = 0;        // the model's burst state
  reg [15:0] m_next = 0;         // the sequence the next good packet must carry
  task seq_model(input integer ig, input integer sob, input integer eob, input [15:0] sq);
    begin
      if (ig) begin
        if (m_burst && !sob && sq !== m_next) exp_seq = exp_seq + 1;
        m_next = sq + 1;
        m_burst = !eob && (sob || m_burst);
      end
    end
  endtask

  // expected entries for n sample times, of which only the first kmax arrived
  task expect_samples(input integer n, input integer kmax, input integer sob, input integer eob,
                      input integer ht, input [63:0] t);
    integer k;
    reg timed;
    begin
      timed = sob && ht;
      for (k = 0; k < n && k < kmax; k = k + 1)
        expect(1, k == 0 && sob, k == n - 1 && eob, k == 0 && timed,
               (k == 0 && timed) ? t : 64'd0, edat[k]);
    end
  endtask

  // everything a packet with a good header rule does, n sample times of
  // which kmax arrived (kmax < n: cut short)
  integer cov_cut_open = 0, cov_cut_eob = 0, cov_hdr_abort = 0, cov_sob_empty = 0;
  task model(input integer n, input integer kmax, input integer sob, input integer eob,
             input integer ht, input [15:0] sq, input [63:0] t);
    reg was, open;
    begin
      if (n != 0 && !sob && !m_burst) begin
        // samples with neither START_OF_BURST nor an open burst: malformed,
        // nothing plays, nothing moves
        exp_bad = exp_bad + 1; cov_orphan = cov_orphan + 1;
      end else if (n == 0 && sob && !eob) begin
        // header-only START_OF_BURST: malformed, nothing moves
        exp_bad = exp_bad + 1; cov_sob_empty = cov_sob_empty + 1;
      end else begin
        was = m_burst; open = sob || m_burst;
        seq_model(1, sob, eob, sq);
        expect_samples(n, kmax, sob, eob, ht, t);
        if (n == 0 && eob) begin
          // an empty burst during a burst cuts the open one off: abort
          expect(0, sob && was, 1, 0, 0, 0);
          if (sob && was) cov_hdr_abort = cov_hdr_abort + 1;
        end
        if (kmax < n) begin
          exp_bad = exp_bad + 1;
          // a cut-short packet outside a burst cannot exist: without
          // START_OF_BURST it is the malformed case above, with it a burst
          // is open, so `open` always holds here
          expect(0, 1, 1, 0, 0, 0); m_burst = 0;
          if (eob) cov_cut_eob = cov_cut_eob + 1; else cov_cut_open = cov_cut_open + 1;
        end
      end
    end
  endtask

  task good(input integer fmt, input integer ch, input integer n, input integer sob,
            input integer eob, input integer ht, input [15:0] sq, input [63:0] t);
    begin
      build(fmt, ch, n, sob, eob, ht, sq, t);
      model(n, n, sob, eob, ht, sq, t);
    end
  endtask

  // the same packet with only `given` words in the buffer (given >= 4)
  task cut(input integer fmt, input integer ch, input integer n, input integer sob,
           input integer eob, input integer ht, input [15:0] sq, input [63:0] t, input integer given);
    integer kmax;
    begin
      build(fmt, ch, n, sob, eob, ht, sq, t);
      kmax = (given - 4) * 32 / (vb * nv); if (kmax > n) kmax = n;
      model(n, kmax, sob, eob, ht, sq, t);
      words = given;
    end
  endtask

  // -- one random packet ------------------------------------------------------------------
  task gen;
    integer kind, fmt, ch, n, full, j, given, kmax;
    reg [63:0] t;
    reg [15:0] sq;
    reg        sob, eob, ht;
    begin
      kind = rnd(16);        // 0 malformed, 1 cut short, 2 header-only EOB, 3 seq jump, 4 padding, else normal
      fmt = 1 + rnd(2); ch = 1 + rnd(3);
      vb = fmt == 2 ? 12 : 16; nv = ch == 3 ? 4 : 2;
      full = 16368 * 8 / (vb * nv);
      n = kind == 2 ? 0 : rnd(4) == 0 ? full : rnd(3) == 0 ? rnd(8) : rnd(full + 1);
      sob = rnd(3) == 0; eob = kind == 2 || rnd(3) == 0; ht = rnd(2);
      t = {$random(seed), $random(seed)};
      sq = sob ? $random(seed) : m_next;
      if (kind == 3) sq = m_next + 1 + rnd(100);              // a jump: counted inside a burst
      build(fmt, ch, n, sob, eob, ht, sq, t);
      if (kind == 0) begin
        case (rnd(9))
          0: pkt[0][31:28] = 4'd2;                         // version
          1: pkt[0][19:16] = 4'd0;                         // type
          2: pkt[0][23:20] = 4'd3;                         // format
          3: pkt[0][25:24] = 2'd0;                         // channels
          4: pkt[0][15:0] = pkt[0][15:0] + 16'd1;          // not a whole number of sample times
          5: pkt[0][15:0] = 16'd16384 + nv * vb / 8;       // above 16384
          6: pkt[0][15:0] = 16'd12;                        // below 16
          7: pkt[1][20] = 1'b1;                            // reserved h1 bit
          default: words = 1 + rnd(3);                     // shorter than a header
        endcase
        exp_bad = exp_bad + 1;
      end else if (kind == 1) begin
        given = 4 + rnd(words - 3);                        // 4 .. words in the buffer
        kmax = (given - 4) * 32 / (vb * nv); if (kmax > n) kmax = n;
        model(n, kmax, sob, eob, ht, sq, t);
        words = given;
      end else begin
        model(n, n, sob, eob, ht, sq, t);
        if (kind == 4) for (j = 0; j < 1 + rnd(6); j = j + 1) begin
          pkt[words] = 32'hFFFF_FFFF; words = words + 1;
        end
      end
      if (words > 4096) words = 4096;
    end
  endtask

  // -- directed corner cases --------------------------------------------------------------
  integer cov_ovf = 0;           // tx packets sent with the rx-only OVERFLOW bit
  task directed;
    begin
      // a new burst may begin at any sequence: no seq error across the boundary
      good(1, 3, 2, 1, 0, 0, 16'h0005, 64'd0);                          put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next, 64'd0);                           put_pkt;
      good(2, 1, 3, 1, 0, 0, 16'hF00D, 64'd0);                         put_pkt;
      good(2, 1, 2, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // HAS_TIME without START_OF_BURST: the time is ignored. Its sequence
      // is arbitrary and must not be checked: the previous burst ended.
      good(1, 3, 2, 0, 1, 1, m_next + 16'd5, 64'h0123_4567_89AB_CDEF);  put_pkt;

      // a timed START_OF_BURST, then another one during that burst (it ends it)
      good(1, 3, 2, 1, 0, 1, 16'h0100, 64'h1111_2222_3333_4444);       put_pkt;
      good(1, 3, 1, 0, 0, 0, m_next, 64'd0);                           put_pkt;
      good(2, 2, 2, 1, 0, 1, 16'h7777, 64'h5555_6666_7777_8888);       put_pkt;

      // a BAD packet between two good ones: bad_packets + 1, sequence
      // expectation unchanged (the good one still carries the old m_next)
      build(1, 3, 2, 0, 0, 0, 16'hDEAD, 64'd0); pkt[1][20] = 1'b1;
      exp_bad = exp_bad + 1;                                           put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // lengths the header rule rejects
      build(1, 3, 3, 0, 0, 0, m_next, 64'd0); pkt[0][15:0] = 16 + 3 * 8 + 2;
      exp_bad = exp_bad + 1;                                           put_pkt;
      build(2, 3, 3, 0, 0, 0, m_next, 64'd0); pkt[0][15:0] = 16 + 3 * 6 + 1;
      exp_bad = exp_bad + 1;                                           put_pkt;
      build(1, 3, 2, 0, 0, 0, m_next, 64'd0); pkt[0][15:0] = 16'd12;
      exp_bad = exp_bad + 1;                                           put_pkt;
      build(1, 3, 2, 0, 0, 0, m_next, 64'd0); pkt[0][27] = 1'b1;
      exp_bad = exp_bad + 1;                                           put_pkt;

      // a buffer cut short: the complete sample times it holds play, it is
      // counted once, and its good header consumed the sequence. It opened
      // a burst, so the abort entry follows its sample.
      cut(1, 3, 2, 1, 1, 0, m_next, 64'd0, 6);      // 8 words if whole
      put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // OVERFLOW is rx-only: on tx the bit is ignored and the packet plays
      build(1, 3, 2, 0, 0, 0, m_next, 64'd0); pkt[1][19] = 1'b1;
      model(2, 2, 0, 0, 0, m_next, 64'd0);
      cov_ovf = cov_ovf + 1;                                           put_pkt;

      // header-only END_OF_BURST outside a burst: one present=0 entry
      good(1, 3, 0, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // header-only packet with no flag outside a burst: legal, plays
      // nothing, and its arbitrary sequence is not checked (no burst)
      good(1, 3, 0, 0, 0, 0, 16'h4321, 64'd0);                         put_pkt;

      // samples with neither START_OF_BURST nor an open burst: malformed,
      // nothing plays and the sequence is not consumed
      good(1, 3, 2, 0, 0, 0, 16'h0BAD, 64'd0);                         put_pkt;
      // ... also when it claims END_OF_BURST (a tail with no head)
      good(2, 1, 3, 0, 1, 0, 16'h0BAE, 64'd0);                         put_pkt;
      // the same shape inside a burst is a continuation and plays
      good(1, 3, 2, 1, 0, 0, 16'h4444, 64'd0);                         put_pkt;
      good(1, 3, 2, 0, 1, 0, m_next, 64'd0);                           put_pkt;
      // after the burst, samples with no flag are malformed again
      good(1, 3, 1, 0, 0, 0, 16'h0BAF, 64'd0);                         put_pkt;

      // rule 3: a header-only START_OF_BURST without END_OF_BURST is
      // malformed and opens nothing: the next packet's jump is outside a
      // burst and must not raise seq_errors
      good(1, 3, 0, 1, 0, 0, 16'h2222, 64'd0);                         put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next + 16'd3, 64'd0);                   put_pkt;
      // ... and inside a burst it neither restarts the sequence nor ends
      // the burst: the next packet continues the old count
      good(1, 3, 2, 1, 0, 0, 16'h3000, 64'd0);                         put_pkt;
      good(1, 3, 0, 1, 0, 0, 16'h9999, 64'd0);                         put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // rule 2: cut short inside a burst (no END_OF_BURST): its sample,
      // then the abort entry; the burst is closed, so the next packet's
      // jump is not a sequence error
      good(1, 3, 2, 1, 0, 0, 16'h4000, 64'd0);                         put_pkt;
      cut(1, 3, 3, 0, 0, 0, m_next, 64'd0, 6);                         put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next + 16'd7, 64'd0);                   put_pkt;
      // cut short on the END_OF_BURST packet: the burst is still open in
      // sample_domain (no END_OF_BURST sample came), so it aborts too
      good(2, 1, 4, 1, 0, 1, 16'h5000, 64'h0000_0001_0000_0000);      put_pkt;
      cut(2, 1, 9, 0, 1, 0, m_next, 64'd0, 6);                         put_pkt;
      // cut short outside a burst: its samples and nothing else
      cut(1, 1, 5, 0, 0, 0, 16'h0BAD, 64'd0, 7);                       put_pkt;

      // an empty burst (header-only START_OF_BURST + END_OF_BURST) during
      // a burst ends that burst with the abort entry; outside a burst it is
      // the plain header-only END_OF_BURST entry
      good(1, 3, 2, 1, 0, 0, 16'h6000, 64'd0);                         put_pkt;
      good(1, 3, 0, 1, 1, 1, 16'h7000, 64'h0000_0002_0000_0000);      put_pkt;
      good(1, 3, 0, 1, 1, 0, 16'h7100, 64'd0);                         put_pkt;
    end
  endtask

  // -- send -------------------------------------------------------------------------------
  integer sent = 0, w, i;
  reg     all_sent = 0;
  task put_pkt;
    begin
      @(posedge clk); #1;      // #1: read w_room after this edge's register updates
      for (w = 0; w < words; w = w + 1) begin
        // wait for room for this word before presenting it: packet_fifo
        // accepts a word only while it holds fewer than MAX of them
        while (!w_room) begin w_valid <= 0; w_last <= 0; @(posedge clk); #1; end
        w_valid <= 1; w_data <= pkt[w]; w_last <= w == words - 1;
        @(posedge clk); #1;
      end
      w_valid <= 0; w_last <= 0;
      sent = sent + 1;
      repeat (rnd(20)) @(posedge clk);
    end
  endtask

  // reset in flight: everything sent so far is drained, then a burst's long
  // packet is stalled with s_valid high and s_full held. One rst cycle
  // (ring and tx_deframer, as the top resets them) must leave, the cycle
  // after: s_valid 0, r_take 0, the counters unchanged (they are not
  // cleared). The model resets too: pending entries dropped, burst closed.
  // The run then goes on and is checked as before.
  reg     hold_full = 0;
  integer cov_reset = 0, bad0, seq0;
  task reset_case;
    reg [115:0] pe;
    begin
      while (r_avail || dut.state != S_IDLE) @(posedge clk);
      repeat (100) @(posedge clk);
      if (qr != qw) begin                // a wrong DUT: report, don't hang
        errors = errors + 1; $display("%0t before the reset: %0d expected entries never came", $time, qw - qr);
      end
      hold_full = 1;
      good(1, 3, 300, 1, 0, 1, 16'h1357, 64'h0000_00AB_0000_0000);    put_pkt;
      while (!(s_valid && s_full && qw - qr > 1)) @(posedge clk);
      bad0 = bad_packets; seq0 = seq_errors;
      #1 rst = 1;
      @(posedge clk); #1;
      if (s_valid !== 1'b0 || r_take !== 1'b0 || bad_packets !== bad0 || seq_errors !== seq0) begin
        errors = errors + 1;
        $display("%0t after reset: s_valid %b r_take %b bad %0d/%0d seq %0d/%0d", $time, s_valid, r_take,
                 bad_packets, bad0, seq_errors, seq0);
      end
      // the model resets: the entries still pending will never come
      while (qr != qw) begin
        pe = q[qr % QN]; qr = qr + 1;
        if (pe[115] && pe[114] && pe[112]) exp_sobt = exp_sobt - 1;
        else if (pe[115] && pe[114]) exp_sobu = exp_sobu - 1;
        else if (!pe[115] && pe[114]) exp_abort = exp_abort - 1;
        else if (!pe[115] && pe[113]) exp_eobonly = exp_eobonly - 1;
      end
      rst = 0; m_burst = 0; hold_full = 0;
      cov_reset = cov_reset + 1;
    end
  endtask

  initial begin
    wait (!rst);
    directed;
    for (i = 0; i < N / 2; i = i + 1) begin gen; put_pkt; end
    reset_case;
    for (i = N / 2; i < N; i = i + 1) begin gen; put_pkt; end
    all_sent = 1;
  end

  // -- check the output and the coverage --------------------------------------------------
  reg [115:0] e, got;
  reg [5:0]   state_seen = 0;
  integer     nout = 0, cov_sobt = 0, cov_sobu = 0, cov_eobonly = 0, cov_abort = 0;
  always @(posedge clk) begin
    if (!rst) state_seen[dut.state] <= 1'b1;
    if (s_valid && !s_full) begin
      got = {s_present, s_sob, s_eob, s_timed, s_timed ? s_at : 64'd0, s_data};
      if (qr == qw) begin errors = errors + 1; $display("%0t entry %0d not expected", $time, nout); end
      else begin
        e = q[qr % QN]; qr = qr + 1;
        if (got !== e) begin
          errors = errors + 1;
          if (errors < 10) $display("%0t entry %0d: p%b s%b e%b t%b %h %h, expected p%b s%b e%b t%b %h %h", $time, nout,
            got[115], got[114], got[113], got[112], got[111:48], got[47:0], e[115], e[114], e[113], e[112], e[111:48], e[47:0]);
        end
      end
      if (s_present && s_sob && s_timed) cov_sobt = cov_sobt + 1;
      else if (s_present && s_sob) cov_sobu = cov_sobu + 1;
      else if (!s_present && s_sob) cov_abort = cov_abort + 1;
      else if (!s_present) cov_eobonly = cov_eobonly + 1;
      nout = nout + 1;
    end
    s_full <= hold_full || rnd(4) == 0;
  end

  // -- faults -----------------------------------------------------------------------------
  initial if (FAULT == 1) begin
    // a bit inside the body of a packet being played: the packet is legal
    // (not one of the rejects), so the wrong sample must show as a mismatch.
    // 8 words past the read pointer is beyond the three the FIFO prefetches
    // and well inside a packet with more than 40 sample times left.
    wait (dut.state == 3'd3 && !dut.ended && dut.n > 40 && ring.wp - ring.rp > 12);
    ring.mem[(ring.rp + 8) % 16384] = ring.mem[(ring.rp + 8) % 16384] ^ 33'h100;
  end
  initial if (FAULT == 2) begin
    wait (nout > 100);
    wait (dut.state == S_CHECK && dut.h1[17] && dut.good && dut.n_hdr != 0);
    @(posedge clk); #1 force dut.first_sample = 0;          // CHECK (state 2) has just set it
    wait (dut.give);
    @(posedge clk); #1 release dut.first_sample;
  end
  initial if (FAULT == 3) begin force dut.open = 0; force dut.abort = 0; end
  initial if (FAULT == 4) force dut.sob_empty = 0;

  // -- drain and verdict ------------------------------------------------------------------
  integer idle;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    wait (all_sent);
    idle = 0;
    while (qr != qw && idle < 200000) begin
      @(posedge clk); idle = (s_valid && !s_full) ? 0 : idle + 1;
    end
    // the entries can all have arrived while the last packets (all rejects,
    // which emit none) are still being read: wait for the deframer itself
    idle = 0;
    while ((r_avail != 0 || dut.state != 0) && idle < 200000) begin
      @(posedge clk); idle = idle + 1;
    end
    if (idle >= 200000) begin errors = errors + 1; $display("the deframer never went idle"); end
    if (qw > QN) begin errors = errors + 1; $display("bench: %0d entries overflow the queue", qw); end
    if (qr != qw) begin errors = errors + 1; $display("%0d entries expected, %0d came", qw, qr); end
    if (bad_packets !== exp_bad) begin
      errors = errors + 1; $display("bad_packets %0d, expected %0d", bad_packets, exp_bad);
    end
    if (seq_errors !== exp_seq) begin
      errors = errors + 1; $display("seq_errors %0d, expected %0d", seq_errors, exp_seq);
    end
    if (cov_sobt !== exp_sobt || cov_sobu !== exp_sobu || cov_eobonly !== exp_eobonly || cov_abort !== exp_abort) begin
      errors = errors + 1;
      $display("coverage entries: SOB-timed %0d/%0d, SOB-untimed %0d/%0d, EOB-only %0d/%0d, abort %0d/%0d (got/expected)",
               cov_sobt, exp_sobt, cov_sobu, exp_sobu, cov_eobonly, exp_eobonly, cov_abort, exp_abort);
    end
    if (cov_sobt == 0)  begin errors = errors + 1; $display("coverage: no SOB-timed entry");  end
    if (cov_sobu == 0)  begin errors = errors + 1; $display("coverage: no SOB-untimed entry"); end
    if (cov_eobonly == 0) begin errors = errors + 1; $display("coverage: no EOB-only entry"); end
    if (cov_abort == 0) begin errors = errors + 1; $display("coverage: no abort entry"); end
    if (cov_orphan == 0) begin errors = errors + 1; $display("coverage: no orphan packet"); end
    if (cov_orphan < 3) begin errors = errors + 1; $display("coverage: %0d orphan packets, at least the 3 directed expected", cov_orphan); end
    if (cov_cut_open == 0)  begin errors = errors + 1; $display("coverage: no cut-short packet inside a burst"); end
    if (cov_cut_eob == 0)   begin errors = errors + 1; $display("coverage: no cut-short END_OF_BURST packet"); end
    if (cov_hdr_abort == 0) begin errors = errors + 1; $display("coverage: no empty burst during a burst"); end
    if (cov_sob_empty == 0) begin errors = errors + 1; $display("coverage: no header-only START_OF_BURST"); end
    if (cov_ovf == 0)   begin errors = errors + 1; $display("coverage: no tx packet with OVERFLOW"); end
    if (bad_packets == 0) begin errors = errors + 1; $display("coverage: no BAD packet"); end
    if (cov_reset != 1) begin errors = errors + 1; $display("coverage: the reset in flight did not run"); end
    if (state_seen[S_IDLE] !== 1'b1)     begin errors = errors + 1; $display("coverage: state IDLE never entered"); end
    if (state_seen[S_HEAD] !== 1'b1)     begin errors = errors + 1; $display("coverage: state HEAD never entered"); end
    if (state_seen[S_CHECK] !== 1'b1)    begin errors = errors + 1; $display("coverage: state CHECK never entered"); end
    if (state_seen[S_BODY] !== 1'b1)     begin errors = errors + 1; $display("coverage: state BODY never entered"); end
    if (state_seen[S_SKIP] !== 1'b1)     begin errors = errors + 1; $display("coverage: state SKIP never entered"); end
    if (state_seen[S_EOB_ONLY] !== 1'b1) begin errors = errors + 1; $display("coverage: state EOB_ONLY never entered"); end
    $display("%0d packets, %0d entries; bad %0d, seq jumps %0d", sent, nout, bad_packets, seq_errors);
    $display("coverage: states %b, SOB-timed %0d, SOB-untimed %0d, EOB-only %0d, abort %0d, OVERFLOW-hdr %0d, BAD %0d",
             state_seen, cov_sobt, cov_sobu, cov_eobonly, cov_abort, cov_ovf, bad_packets);
    $display("coverage: cut short in a burst %0d, on END_OF_BURST %0d; empty burst in a burst %0d; header-only SOB %0d; reset in flight %0d",
             cov_cut_open, cov_cut_eob, cov_hdr_abort, cov_sob_empty, cov_reset);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
