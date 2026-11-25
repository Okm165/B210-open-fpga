// SPDX-License-Identifier: GPL-3.0-or-later
//
// tx_player - tx packets in, sample times out (docs/PROTOCOL.md 2, 3); the
// inverse of rx_framer.
//
// Input: whole packets from a packet_fifo (show-ahead, one FX3 buffer
// each). Every packet describes itself: format, channels, length L, flags,
// time.
//
// Header rule (one rule, checked before any sample is played):
//   version = 1 (h0[31:28]), type = 1 tx (h0[19:16]), format sc16 or sc12
//   (h0[23:20] = 1 or 2), channels != 0 (h0[25:24]), 16 <= L <= 16384,
//   (L - 16) a whole number of sample times (bytes per sample time 3, 4, 6
//   or 8 from format x channels), and the reserved bits zero:
//   h0[27:26] = 0 and h1[31:20] = 0. h1[19] (OVERFLOW) is not reserved: it
//   means nothing on a tx packet and is ignored.
// A packet that fails the rule is not played and `bad_packets` rises by
// exactly one; it is checked before its samples, so its sequence field and
// the expected sequence are left untouched: the next good packet is still
// compared with the same count, and dropping a bad packet never shows up as
// a sequence jump. A buffer that ends before its last sample time is the one
// other `bad_packets` fault: its header was good, so its sequence was
// consumed as usual and the sample times whose words all arrived are played
// (without an END_OF_BURST); it is counted once, not twice.
//
// Sequence: it is checked within a burst only. START_OF_BURST opens a burst
// and restarts the expectation at that packet's sequence without comparing
// it (any value: a new process may start at 0), so a jump across a burst
// boundary is not an error. From then on, up to and including the
// END_OF_BURST packet, a good packet's sequence must equal the previous
// good packet's + 1 (mod 2^16); a jump rises `seq_errors` and the packet
// still plays. END_OF_BURST closes the burst, so a non-START_OF_BURST
// packet outside a burst is not compared with anything.
//
// Time and bursts:
//   HAS_TIME (h1[16]) is honoured only together with START_OF_BURST: o_timed
//   is set on the burst's first sample and o_time carries words 2-3; on any
//   other packet the time words are ignored.
//   START_OF_BURST (h1[17]) also begins a new burst: a timed
//   START_OF_BURST arriving during a burst ends that burst at the previous
//   sample (the top counts no BURST_ACK for the burst it cuts off), because
//   the old burst never showed its END_OF_BURST.
//   END_OF_BURST (h1[18]) marks the packet's last sample o_eob. A
//   header-only END_OF_BURST (L = 16) emits one o_present = 0 entry and no
//   sample; outside a burst that is all it does (nothing plays).
//
// Output: one entry per sample time, valid/ready:
//   o_data   {Q1, I1, Q0, I0}, 12-bit codes; a 1-channel packet fills its
//            channel's slots and leaves the other channel 0
//   o_sob    first sample of a packet with START_OF_BURST
//   o_eob    last sample of a packet with END_OF_BURST
//   o_timed, o_time   on the o_sob entry: play it at this time (HAS_TIME)
//   o_present 0 only for the entry a header-only END_OF_BURST packet
//            makes: the burst ended with the previous sample
// sc16 values are taken from bits 15:4 of each 16-bit field (the low 4
// bits carry nothing, PROTOCOL.md 3). Words after the n-th sample time up
// to the buffer's end are padding and skipped. A buffer that ends before
// its n samples is counted in `bad_packets`; the samples it had are played.
//
// Throughput: one word taken and one sample time given per cycle at most,
// so 2 channels sc16 (2 words per sample time) run at 50 M sample times/s.
`default_nettype none

module tx_player (
  input  wire        clk, rst,
  // packets
  input  wire        r_avail,
  input  wire [31:0] r_data,
  input  wire        r_last,
  output wire        r_take,
  // sample times
  output reg         o_valid = 0,
  input  wire        o_ready,
  output reg         o_present = 0,
  output reg         o_sob = 0,
  output reg         o_eob = 0,
  output reg         o_timed = 0,
  output reg  [63:0] o_time = 0,
  output reg  [47:0] o_data = 0,
  // counters
  output reg  [31:0] bad_packets = 0,      // malformed headers, bad lengths, cut short
  output reg  [31:0] seq_errors = 0
);

  localparam VERSION = 4'd1, T_TX = 4'd1;
  // IDLE 0, HEAD 1, CHECK 2, BODY 3, SKIP 4, EOB_ONLY 5 (tb_tx_player covers
  // every one of them)
  localparam IDLE = 0, HEAD = 1, CHECK = 2, BODY = 3, SKIP = 4, EOB_ONLY = 5;
  reg [2:0]  state = IDLE;
  reg [1:0]  hw = 0;
  reg [31:0] h0 = 0, h1 = 0;
  reg [63:0] t0 = 0;
  reg        ended = 0;          // the buffer's last word was taken
  reg        first = 0;          // the next sample is the packet's first
  reg [15:0] seq_next = 0;
  reg        in_burst = 0;       // between START_ and END_OF_BURST
  reg [12:0] n = 0;              // sample times still to give
  reg [95:0] acc = 0;
  reg [6:0]  nb = 0;

  // header fields
  wire [15:0] len   = h0[15:0];
  wire [3:0]  fmt   = h0[23:20];
  wire [1:0]  chans = h0[25:24];
  wire        sc12  = fmt == 4'd2;
  wire        two   = chans == 2'b11;
  wire [6:0]  tbits = sc12 ? (two ? 7'd48 : 7'd24) : (two ? 7'd64 : 7'd32);
  wire [15:0] pbytes = len - 16;
  // n = pbytes / bytes-per-sample-time (3 4 6 8) without a divider:
  // x / 3 = floor(x * 43691 / 2^17) for every x < 2^16 (3 * 43691 = 2^17 +
  // 1), x / 6 = (x / 3) / 2, 4 and 8 shift. The multiply is registered from
  // h0, which HEAD takes at word 0; CHECK runs at least two cycles later
  // (words 1, 2 and 3 in between), so no wait state is needed.
  reg  [31:0] third = 0;
  always @(posedge clk) third <= pbytes * 32'd43691;
  wire [14:0] q3    = third[31:17];
  wire [12:0] n_hdr = sc12 ? (two ? q3 >> 1 : q3) : (two ? pbytes >> 3 : pbytes >> 2);
  // n * bpt by shifts: 3 n = 2 n + n, 6 n = 2 (3 n)
  wire [15:0] n3    = {n_hdr, 1'b0} + n_hdr;
  wire [15:0] back  = sc12 ? (two ? {n3[14:0], 1'b0} : n3) : (two ? {n_hdr, 3'b0} : {n_hdr, 2'b0});
  wire        good  = h0[31:28] == VERSION && h0[19:16] == T_TX && h0[27:26] == 0 &&
                      (fmt == 4'd1 || fmt == 4'd2) && chans != 0 &&
                      len >= 16 && len <= 16384 && back == pbytes;

  // decoding: take a word when the next sample time is not complete and the
  // buffer has words left; give a sample time when it is complete
  wire give = state == BODY && n != 0 && nb >= tbits && (!o_valid || o_ready);
  wire [6:0] nb1 = give ? nb - tbits : nb;
  wire take_body = state == BODY && !ended && r_avail && nb1 < tbits && n != 0;
  wire take_head = state == HEAD && r_avail;
  wire take_skip = state == SKIP && r_avail;
  assign r_take = take_body || take_head || take_skip;

  // the values of the sample time at the bottom of the accumulator
  wire [47:0] v12 = acc[47:0];
  wire [47:0] v16 = {acc[63:52], acc[47:36], acc[31:20], acc[15:4]};
  wire [47:0] v   = sc12 ? v12 : v16;                 // {v3, v2, v1, v0}
  wire [47:0] sample = two ? v : chans[0] ? {24'd0, v[23:0]} : {v[23:0], 24'd0};

  always @(posedge clk) begin
    if (o_valid && o_ready) o_valid <= 0;
    if (rst) begin
      state <= IDLE; o_valid <= 0; in_burst <= 0;
    end else case (state)
      IDLE: if (r_avail) begin hw <= 0; ended <= 0; state <= HEAD; end
      HEAD: if (r_avail) begin
        hw <= hw + 1;
        case (hw)
          0: h0 <= r_data;
          1: h1 <= r_data;
          2: t0[31:0] <= r_data;
          default: t0[63:32] <= r_data;
        endcase
        if (r_last) ended <= 1;
        if (hw == 3) state <= CHECK;
        else if (r_last) begin bad_packets <= bad_packets + 1; state <= IDLE; end   // shorter than a header
      end
      CHECK: if (!good || h1[31:20] != 0) begin
        bad_packets <= bad_packets + 1; state <= ended ? IDLE : SKIP;
      end else begin
        if (in_burst && !h1[17] && h1[15:0] != seq_next) seq_errors <= seq_errors + 1;
        seq_next <= h1[15:0] + 1;
        in_burst <= !h1[18] && (h1[17] || in_burst);       // EOB closes, SOB opens
        n <= n_hdr; first <= 1; acc <= 0; nb <= 0;
        if (n_hdr != 0) state <= BODY;
        else if (h1[18]) state <= EOB_ONLY;                 // END_OF_BURST, no samples
        else state <= ended ? IDLE : SKIP;
      end
      BODY: begin
        if (take_body && r_last) ended <= 1;
        if (give) begin
          o_valid <= 1; o_present <= 1; o_data <= sample;
          o_sob <= first && h1[17]; o_timed <= first && h1[17] && h1[16]; o_time <= t0;
          o_eob <= n == 1 && h1[18];
          first <= 0; n <= n - 1;
        end
        acc <= (give ? acc >> tbits : acc) | (take_body ? {64'd0, r_data} << nb1 : 96'd0);
        nb  <= nb1 + (take_body ? 7'd32 : 7'd0);
        if (give && n == 1) state <= (ended || (take_body && r_last)) ? IDLE : SKIP;
        else if (ended && !give && nb < tbits) begin bad_packets <= bad_packets + 1; state <= IDLE; end
      end
      SKIP: if (r_avail && r_last) state <= IDLE;
      EOB_ONLY: if (!o_valid || o_ready) begin
        o_valid <= 1; o_present <= 0; o_sob <= 0; o_eob <= 1; o_timed <= 0; o_data <= 0;
        state <= ended ? IDLE : SKIP;
      end
      default: state <= IDLE;
    endcase
  end
endmodule

`default_nettype wire
