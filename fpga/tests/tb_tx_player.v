// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_tx_player - tx packets -> packet_fifo -> tx_player, every output entry
// compared with an independently computed model of what the packet must
// produce.
//
// The model (build / fill / expect / seq_model) holds the expected sample
// stream in a queue and the expected counters; the DUT's stream and counters
// are compared with those. Apart from the FAULT 2 injection below, the only
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
//   - HAS_TIME without START_OF_BURST is ignored: o_timed stays 0.
//   - a START_OF_BURST packet may be header-only (L = 16) and still opens a
//     burst; the next packet's sequence is then checked.
//   - a header-only END_OF_BURST makes one entry with o_present = 0 and no
//     sample; outside a burst that is all it does.
//   - a header-only packet with no flag is legal and plays nothing.
//
// tx_player has no overflow-on-last-packet logic: OVERFLOW is an rx-only
// flag (PROTOCOL.md 2) and is ignored on a tx packet. The bench sends one
// with the bit set and counts it in cov_ovf; it must play as if it were 0.
//
// Coverage: every state must be entered (state_seen) and every output kind
// must occur at least once (cov_sobt, cov_sobu, cov_eobonly, cov_ovf and
// bad_packets); the run fails and names whatever never ran.
//
// FAULT 1: a bit is flipped in the ring 30 words ahead of the reader. The
//          bench must catch it as a wrong sample value (or, if the bit lands
//          in a header, a packet that turns bad).
// FAULT 2: START_OF_BURST is made to lose `first` in state CHECK (2), so one
//          entry's o_sob is missing; the bench must catch that entry.
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
  localparam S_IDLE = 0, S_HEAD = 1, S_CHECK = 2, S_BODY = 3, S_SKIP = 4, S_EOB_ONLY = 5;
  wire        w_room, r_avail, r_last, r_take, o_valid, o_present, o_sob, o_eob, o_timed;
  wire [31:0] r_data, bad_packets, seq_errors;
  wire [63:0] o_time;
  wire [47:0] o_data;
  reg         w_valid = 0, w_last = 0, o_ready = 0;
  reg  [31:0] w_data = 0;
  packet_fifo #(.AW(14), .MAX(4096)) ring (.clk(clk), .rst(rst), .w_room(w_room), .w_valid(w_valid),
    .w_last(w_last), .w_data(w_data), .w_used(), .r_avail(r_avail), .r_data(r_data),
    .r_last(r_last), .r_take(r_take), .r_used());
  // bad / short are temporary aliases of bad_packets for b210.v: not used here
  tx_player dut (.clk(clk), .rst(rst), .r_avail(r_avail), .r_data(r_data), .r_last(r_last), .r_take(r_take),
    .o_valid(o_valid), .o_ready(o_ready), .o_present(o_present), .o_sob(o_sob), .o_eob(o_eob),
    .o_timed(o_timed), .o_time(o_time), .o_data(o_data),
    .bad_packets(bad_packets), .seq_errors(seq_errors));

  // -- expected entries: {present, sob, eob, timed, time, data} ---------------------------
  localparam QN = 1 << 22;
  reg [115:0] q [0:QN-1];
  integer     qw = 0, qr = 0;
  integer     exp_bad = 0, exp_seq = 0, exp_sobt = 0, exp_sobu = 0, exp_eobonly = 0;

  task expect(input p, input sob, input eob, input timed, input [63:0] t, input [47:0] dat);
    begin
      if (p) begin
        if (sob && timed) exp_sobt = exp_sobt + 1;
        else if (sob) exp_sobu = exp_sobu + 1;
      end else if (eob) exp_eobonly = exp_eobonly + 1;
      q[qw % QN] = {p, sob, eob, timed, t, dat};
      qw = qw + 1;
    end
  endtask

  // -- packet construction ----------------------------------------------------------------
  integer     words = 0;         // words the packet occupies in the ring, padding included
  reg [31:0]  pkt [0:4300];
  reg [47:0]  edat [0:5460];     // expected o_data per sample time
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

  task good(input integer fmt, input integer ch, input integer n, input integer sob,
            input integer eob, input integer ht, input [15:0] sq, input [63:0] t);
    begin
      build(fmt, ch, n, sob, eob, ht, sq, t);
      seq_model(1, sob, eob, sq);
      expect_samples(n, n, sob, eob, ht, t);
      if (n == 0 && eob) expect(0, 0, 1, 0, 0, 0);
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
        seq_model(1, sob, eob, sq);
        expect_samples(n, kmax, sob, eob, ht, t);
        if (kmax < n) exp_bad = exp_bad + 1;
        if (n == 0 && eob) expect(0, 0, 1, 0, 0, 0);
        words = given;
      end else begin
        seq_model(1, sob, eob, sq);
        expect_samples(n, n, sob, eob, ht, t);
        if (n == 0 && eob) expect(0, 0, 1, 0, 0, 0);
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
      // counted once, and its good header consumed the sequence
      build(1, 3, 2, 1, 1, 0, m_next, 64'd0);       // 8 words if whole
      seq_model(1, 1, 1, m_next); expect_samples(2, 1, 1, 1, 0, 64'd0);
      words = 6; exp_bad = exp_bad + 1;                                put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // OVERFLOW is rx-only: on tx the bit is ignored and the packet plays
      build(1, 3, 2, 0, 0, 0, m_next, 64'd0); pkt[1][19] = 1'b1;
      seq_model(1, 0, 0, m_next); expect_samples(2, 2, 0, 0, 0, 64'd0);
      cov_ovf = cov_ovf + 1;                                           put_pkt;

      // header-only END_OF_BURST outside a burst: one present=0 entry
      good(1, 3, 0, 0, 1, 0, m_next, 64'd0);                           put_pkt;

      // header-only packet with no flag outside a burst: legal, plays
      // nothing, and its arbitrary sequence is not checked (no burst)
      good(1, 3, 0, 0, 0, 0, 16'h4321, 64'd0);                         put_pkt;

      // an empty START_OF_BURST still opens a burst: the next packet's
      // sequence is checked, so this deliberate jump must raise seq_errors
      good(1, 3, 0, 1, 0, 0, 16'h2222, 64'd0);                         put_pkt;
      good(1, 3, 1, 0, 1, 0, m_next + 16'd3, 64'd0);                   put_pkt;
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

  initial begin
    wait (!rst);
    directed;
    for (i = 0; i < N; i = i + 1) begin gen; put_pkt; end
    all_sent = 1;
  end

  // -- check the output and the coverage --------------------------------------------------
  reg [115:0] e, got;
  reg [5:0]   state_seen = 0;
  integer     nout = 0, cov_sobt = 0, cov_sobu = 0, cov_eobonly = 0;
  always @(posedge clk) begin
    if (!rst) state_seen[dut.state] <= 1'b1;
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
      if (o_present && o_sob && o_timed) cov_sobt = cov_sobt + 1;
      else if (o_present && o_sob) cov_sobu = cov_sobu + 1;
      else if (!o_present) cov_eobonly = cov_eobonly + 1;
      nout = nout + 1;
    end
    o_ready <= rnd(4) != 0;
  end

  // -- faults -----------------------------------------------------------------------------
  initial if (FAULT == 1) begin
    wait (sent >= 20); wait (ring.wp - ring.rp > 40);
    ring.mem[(ring.rp + 30) % 16384] = ring.mem[(ring.rp + 30) % 16384] ^ 33'h100;
  end
  initial if (FAULT == 2) begin
    wait (nout > 100);
    wait (dut.state == S_CHECK && dut.h1[17] && dut.good && dut.n_hdr != 0);
    @(posedge clk); #1 force dut.first = 0;          // CHECK (state 2) has just set it
    wait (dut.give);
    @(posedge clk); #1 release dut.first;
  end

  // -- drain and verdict ------------------------------------------------------------------
  integer idle;
  initial begin
    repeat (5) @(posedge clk);
    rst = 0;
    wait (all_sent);
    idle = 0;
    while (qr != qw && idle < 200000) begin
      @(posedge clk); idle = (o_valid && o_ready) ? 0 : idle + 1;
    end
    repeat (1000) @(posedge clk);
    if (qw > QN) begin errors = errors + 1; $display("bench: %0d entries overflow the queue", qw); end
    if (qr != qw) begin errors = errors + 1; $display("%0d entries expected, %0d came", qw, qr); end
    if (bad_packets !== exp_bad) begin
      errors = errors + 1; $display("bad_packets %0d, expected %0d", bad_packets, exp_bad);
    end
    if (seq_errors !== exp_seq) begin
      errors = errors + 1; $display("seq_errors %0d, expected %0d", seq_errors, exp_seq);
    end
    if (cov_sobt !== exp_sobt || cov_sobu !== exp_sobu || cov_eobonly !== exp_eobonly) begin
      errors = errors + 1;
      $display("coverage entries: SOB-timed %0d/%0d, SOB-untimed %0d/%0d, EOB-only %0d/%0d (got/expected)",
               cov_sobt, exp_sobt, cov_sobu, exp_sobu, cov_eobonly, exp_eobonly);
    end
    if (cov_sobt == 0)  begin errors = errors + 1; $display("coverage: no SOB-timed entry");  end
    if (cov_sobu == 0)  begin errors = errors + 1; $display("coverage: no SOB-untimed entry"); end
    if (cov_eobonly == 0) begin errors = errors + 1; $display("coverage: no EOB-only entry"); end
    if (cov_ovf == 0)   begin errors = errors + 1; $display("coverage: no tx packet with OVERFLOW"); end
    if (bad_packets == 0) begin errors = errors + 1; $display("coverage: no BAD packet"); end
    if (state_seen[S_IDLE] !== 1'b1)     begin errors = errors + 1; $display("coverage: state IDLE never entered"); end
    if (state_seen[S_HEAD] !== 1'b1)     begin errors = errors + 1; $display("coverage: state HEAD never entered"); end
    if (state_seen[S_CHECK] !== 1'b1)    begin errors = errors + 1; $display("coverage: state CHECK never entered"); end
    if (state_seen[S_BODY] !== 1'b1)     begin errors = errors + 1; $display("coverage: state BODY never entered"); end
    if (state_seen[S_SKIP] !== 1'b1)     begin errors = errors + 1; $display("coverage: state SKIP never entered"); end
    if (state_seen[S_EOB_ONLY] !== 1'b1) begin errors = errors + 1; $display("coverage: state EOB_ONLY never entered"); end
    $display("%0d packets, %0d entries; bad %0d, seq jumps %0d", sent, nout, bad_packets, seq_errors);
    $display("coverage: states %b, SOB-timed %0d, SOB-untimed %0d, EOB-only %0d, OVERFLOW-hdr %0d, BAD %0d",
             state_seen, cov_sobt, cov_sobu, cov_eobonly, cov_ovf, bad_packets);
    $display("RESULT: %0s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule

`default_nettype wire
