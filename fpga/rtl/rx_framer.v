// SPDX-License-Identifier: GPL-3.0-or-later
//
// rx_framer - sample times in, rx packets out (docs/PROTOCOL.md 2, 3).
//
// Input: one sample time per s_take, show-ahead: s_time (ticks) and
// s_data = {Q1, I1, Q0, I0}, 12-bit two's complement each.
// Output: words of whole packets into a packet_fifo (w_room reserved for a
// whole packet before its first word).
//
// A packet holds n sample times, n fixed when its header is written:
//   n = min(spp, samples the stream still has), spp clamped to 16 .. full
//   L = 16 + n * B bytes, B = bytes per sample time = 2 * channels * (2 or 1.5)
//   transferred as S(L) = 4 * ceil(L / 4) bytes, + 4 if that is a multiple
//   of 1024 below 16384 (the FX3 sends no zero-length packet)
// Payload: the selected channels' values in the order I0 Q0 I1 Q1 as one
// little-endian bit stream: sc16 puts each code c as the 16 bits c << 4,
// sc12 as its 12 bits. The bits after the last value up to S(L) are zero.
//
// Stream control (one stream at a time, config static while it runs):
//   start          begin with the first sample at time >= start_time if
//                  start_at, else with the next sample
//   count          sample times in the stream, 0 = until stopped
//   stop           end after the packet in progress, then send a 16-byte
//                  packet (header only) with END_OF_BURST and the time just
//                  after the stream's last sample; a stream still waiting
//                  for its start time ends without a packet
// The first packet carries START_OF_BURST, the last END_OF_BURST; every
// packet HAS_TIME = the time of its first sample, so a gap between packets
// is time - (previous time + previous n).
// Overflow: if the packet_fifo has no room when a packet would start, its
// n samples are dropped (and counted) and the next packet carries OVERFLOW;
// if that was the stream's last packet, a header-only END_OF_BURST packet
// (with OVERFLOW) follows.
// Samples arriving while no stream runs are discarded.
//
// Throughput: one word written per cycle; a sample time is taken when the
// bit accumulator has room, so 2 channels sc16 (2 words per sample time)
// run at up to 50 M sample times/s at 100 MHz, 1 channel sc16 at 100 M.
`default_nettype none

module rx_framer (
  input  wire        clk, rst,
  // samples
  input  wire        s_valid,
  input  wire [63:0] s_time,
  input  wire [47:0] s_data,
  output wire        s_take,
  // configuration (static while a stream runs)
  input  wire [3:0]  format,      // 1 sc16, 2 sc12
  input  wire [1:0]  channels,    // bit c: channel c
  input  wire [12:0] spp,         // sample times per packet (clamped to 16 .. a full packet)
  // control: one-cycle strobes
  input  wire        start, stop,
  input  wire        start_at,
  input  wire [63:0] start_time,
  input  wire [31:0] count,
  // packets
  input  wire        w_room,
  output reg         w_valid = 0,
  output reg         w_last = 0,
  output reg  [31:0] w_data = 0,
  // status
  output wire        running,
  output reg  [31:0] dropped = 0     // sample times dropped for lack of room
);
  localparam VERSION = 4'd1, T_RX = 4'd0, FULL_WORDS = 4096;
  localparam F_TIME = 0, F_SOB = 1, F_EOB = 2, F_OVERFLOW = 3;

  // -- bits per sample time and per value ---------------------------------------
  wire       sc12  = format == 4'd2;
  wire       two   = channels == 2'b11;
  wire [6:0] vbits = sc12 ? 7'd12 : 7'd16;             // bits per value
  wire [6:0] tbits = two ? vbits << 2 : vbits << 1;    // bits per sample time: 24 32 48 64
  // the selected values of one sample time, low first, packed; bits above
  // tbits are zero
  wire [11:0] i0 = s_data[11:0], q0 = s_data[23:12], i1 = s_data[35:24], q1 = s_data[47:36];
  wire [11:0] ia = channels[0] ? i0 : i1, qa = channels[0] ? q0 : q1;   // the first (or only) channel
  wire [63:0] packed = sc12 ? (two ? {16'd0, q1, i1, q0, i0} : {40'd0, qa, ia})
                            : (two ? {q1, 4'd0, i1, 4'd0, q0, 4'd0, i0, 4'd0} : {32'd0, qa, 4'd0, ia, 4'd0});
  // sample times in a full packet: 16368 payload bytes / bytes per sample time
  wire [12:0] full  = sc12 ? (two ? 13'd2728 : 13'd5456) : (two ? 13'd2046 : 13'd4092);
  // at least 16: a packet costs 5 cycles besides its payload words (START,
  // 4 header words) and the radio cannot wait, so n / (5 + words(n)) must
  // exceed the top rate in sample times per cycle: 0.6144 at 61.44 MS/s
  // (n >= 8, 1 channel sc16), 0.3072 at 2 x 30.72 (n >= 4); 16 leaves margin
  wire [12:0] spp_c = spp < 16 ? 13'd16 : spp > full ? full : spp;

  // -- stream and packet state ----------------------------------------------------
  localparam IDLE = 0, ARMED = 1, START = 2, HEAD = 3, BODY = 4, DROP = 5, EOB_ONLY = 6;
  reg [2:0]  state = IDLE;
  reg        first = 0, overflow = 0, stopping = 0, endless = 0;
  reg [31:0] left = 0;            // sample times still to send (if !endless)
  reg [12:0] n = 0;               // sample times of this packet still to take
  reg [12:0] words = 0;           // words of this packet still to write
  reg [1:0]  hw = 0;              // header word
  reg [31:0] h0 = 0, h1 = 0;
  reg [63:0] t0 = 0;              // time of the packet's first sample
  reg [63:0] t_end = 0;           // time after the packet's last sample
  reg [15:0] seq = 0;
  reg [95:0] acc = 0;             // payload bits not yet written, low first
  reg [6:0]  nb = 0;              // how many
  assign running = state != IDLE;

  // n and the packet's size for the next packet, from the stream's remainder
  wire [31:0] want  = endless ? spp_c : (left < spp_c ? left : spp_c);
  wire [12:0] n_new = want[12:0];
  wire        last_packet = !endless && left == want || stopping;
  // L = 16 + n * B bytes, B = tbits / 8 = 3 4 6 8, by shifts and one add
  // (3 n = 2 n + n, 6 n = 2 (3 n)); words = ceil(L / 4), + 1 if that is a
  // multiple of 256 below the full 4096
  wire [15:0] n3    = {n_new, 1'b0} + n_new;
  wire [15:0] pbytes = sc12 ? (two ? {n3[14:0], 1'b0} : n3) : (two ? {n_new, 3'b0} : {n_new, 2'b0});
  wire [15:0] len   = 16 + pbytes;
  wire [12:0] w_raw = (len + 3) >> 2;
  wire [12:0] w_all = w_raw + (w_raw[7:0] == 0 && w_raw != FULL_WORDS);

  // accumulator: write a word when 32 bits are held or the packet's samples
  // are all in and bits remain; take a sample when it fits
  wire in_body   = state == BODY;
  wire emit_data = in_body && (nb >= 32 || (n == 0 && words != 0));
  wire [6:0] nb1 = emit_data ? (nb >= 32 ? nb - 7'd32 : 7'd0) : nb;
  wire take_body = in_body && n != 0 && s_valid && nb1 + tbits <= 96;
  // samples consumed outside a packet: discarded (idle, before the start
  // time, dropped for lack of room)
  wire take_skip = s_valid && (state == IDLE || state == EOB_ONLY ||
                               (state == ARMED && start_at && s_time < start_time) ||
                               (state == DROP && n != 0));
  assign s_take = take_body || take_skip;

  always @(posedge clk) begin
    w_valid <= 0; w_last <= 0;
    if (rst) begin
      state <= IDLE; nb <= 0;
    end else begin
      if (stop && state != IDLE) stopping <= 1;
      case (state)
        IDLE: if (start) begin
          first <= 1; overflow <= 0; stopping <= 0; seq <= 0;
          endless <= count == 0; left <= count; state <= ARMED;
        end
        ARMED: if (stopping) state <= IDLE;
          else if (s_valid && !(start_at && s_time < start_time)) state <= START;
        // a packet begins at the sample now at the head
        // (left == 0 here: the last packet was dropped, its EOB still owed)
        START: if ((!endless && left == 0) || (stopping && !first)) begin
          hw <= 0; state <= EOB_ONLY;
        end else if (s_valid) begin
          n <= n_new; t0 <= s_time; t_end <= s_time + n_new;
          if (!endless) left <= left - want;
          if (w_room) begin
            words <= w_all; hw <= 0;
            h0 <= {VERSION, 2'd0, channels, format, T_RX, len};
            h1 <= {11'd0, 1'b0, overflow, last_packet, first, 1'b1, seq};
            first <= 0; overflow <= 0; seq <= seq + 1;
            state <= HEAD;
          end else begin
            dropped <= dropped + n_new; overflow <= 1;
            state <= DROP;
          end
        end
        DROP: if (n == 0 || (n == 1 && take_skip)) state <= START;
        HEAD: begin
          w_valid <= 1; hw <= hw + 1; words <= words - 1;
          case (hw)
            0: w_data <= h0;
            1: w_data <= h1;
            2: w_data <= t0[31:0];
            default: begin w_data <= t0[63:32]; state <= BODY; end
          endcase
        end
        BODY: begin
          if (emit_data) begin
            w_valid <= 1; w_data <= acc[31:0]; words <= words - 1;
            w_last <= words == 1;
            if (words == 1) state <= h1[16 + F_EOB] ? IDLE : START;
          end
        end
        EOB_ONLY: if (hw != 0 || w_room) begin   // header-only packet ending the stream
          w_valid <= 1; hw <= hw + 1;
          case (hw)
            0: w_data <= {VERSION, 2'd0, channels, format, T_RX, 16'd16};
            1: w_data <= {11'd0, 1'b0, overflow, 1'b1, first, 1'b1, seq};
            2: w_data <= t_end[31:0];
            default: begin w_data <= t_end[63:32]; w_last <= 1; state <= IDLE; end
          endcase
        end
        default: state <= IDLE;
      endcase
      // the accumulator and the sample count of the packet
      if (state == START) acc <= 0;
      if (take_body || (state == DROP && take_skip)) n <= n - 1;
      if (in_body) begin
        acc <= (emit_data ? acc >> 32 : acc) | (take_body ? {32'd0, packed} << nb1 : 96'd0);
        nb  <= nb1 + (take_body ? tbits : 7'd0);
      end else nb <= 0;
    end
  end
endmodule

`default_nettype wire
