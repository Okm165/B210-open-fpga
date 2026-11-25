// SPDX-License-Identifier: GPL-3.0-or-later
//
// tx_player - tx packets in, sample times out (docs/PROTOCOL.md 2, 3); the
// inverse of rx_framer.
//
// Input: whole packets from a packet_fifo (show-ahead, one FX3 buffer
// each). Every packet describes itself: format, channels, length L, flags,
// time. Before any of its samples is played the header is checked:
//   version 1, type 1 (tx), format sc16 or sc12, channels 01/10/11,
//   16 <= L <= 16384, (L - 16) a whole number of sample times
// A packet failing this is skipped whole and counted in `bad`.
// The sequence must count up by one per packet (mod 2^16); a jump is
// counted in `seq_errors` (the packet still plays).
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
// its n samples is counted in `short`; the samples it had are played.
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
  output reg  [31:0] bad = 0,
  output reg  [31:0] seq_errors = 0,
  output reg  [31:0] short = 0
);
  localparam VERSION = 4'd1, T_TX = 4'd1;
  localparam IDLE = 0, HEAD = 1, CHECK = 2, BODY = 3, SKIP = 4, EOB_ONLY = 5;
  reg [2:0]  state = IDLE;
  reg [1:0]  hw = 0;
  reg [31:0] h0 = 0, h1 = 0, tl = 0;
  reg [63:0] t0 = 0;
  reg        ended = 0;          // the buffer's last word was taken
  reg        first = 0;          // the next sample is the packet's first
  reg [15:0] seq_next = 0;
  reg        synced = 0;         // a packet has been seen since reset
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
  wire [3:0]  bpt   = tbits[6:3];                    // bytes per sample time: 3 4 6 8
  // n = pbytes / bpt without a divider: x / 3 = floor(x * 43691 / 2^17) for
  // every x < 2^16 (3 * 43691 = 2^17 + 1), x / 6 = (x / 3) / 2, 4 and 8 shift
  wire [31:0] third = pbytes * 32'd43691;
  wire [14:0] q3    = third[31:17];
  wire [12:0] n_hdr = sc12 ? (two ? q3 >> 1 : q3) : (two ? pbytes >> 3 : pbytes >> 2);
  wire        good  = h0[31:28] == VERSION && h0[19:16] == T_TX && h0[27:26] == 0 &&
                      (fmt == 4'd1 || fmt == 4'd2) && chans != 0 &&
                      len >= 16 && len <= 16384 && n_hdr * bpt == pbytes;

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
      state <= IDLE; o_valid <= 0; synced <= 0;
    end else case (state)
      IDLE: if (r_avail) begin hw <= 0; ended <= 0; state <= HEAD; end
      HEAD: if (r_avail) begin
        hw <= hw + 1;
        case (hw)
          0: h0 <= r_data;
          1: h1 <= r_data;
          2: tl <= r_data;
          default: t0 <= {r_data, tl};
        endcase
        if (r_last) ended <= 1;
        if (hw == 3) state <= CHECK;
        else if (r_last) begin bad <= bad + 1; state <= IDLE; end   // shorter than a header
      end
      CHECK: if (!good || h1[31:20] != 0) begin
        bad <= bad + 1; state <= ended ? IDLE : SKIP;
      end else begin
        if (synced && h1[15:0] != seq_next) seq_errors <= seq_errors + 1;
        seq_next <= h1[15:0] + 1; synced <= 1;
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
        else if (ended && !give && nb < tbits) begin short <= short + 1; state <= IDLE; end
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
