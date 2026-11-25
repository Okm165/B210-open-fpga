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
// Stream control (one stream at a time). format, channels, spp, timed and
// at are latched when the stream starts (run_*): the stream keeps them to
// its END_OF_BURST whatever the registers do meanwhile (the
// host's stop write itself rewrites rx_ctrl's configuration bits).
//   start          begin with the first sample at time >= at if timed,
//                  else with the next sample; ignored unless the
//                  framer is idle (a start while a stream runs does nothing)
//   count          sample times in the stream, 0 = until stopped
//   stop           end after the packet in progress, then send a 16-byte
//                  packet (header only) with END_OF_BURST and the time just
//                  after the stream's last sample
// How a stream ends, exactly (state names below; `first` set = no packet has
// been written yet):
//   stop seen while ARMED (the start is latched, the first sample at/after
//     `at` has not arrived): nothing is sent, not even END_OF_BURST,
//     the framer goes IDLE - no packet at all.
//   stop seen while START (no header written yet: nothing has been sent):
//     one 16-byte header-only packet with END_OF_BURST, START_OF_BURST too
//     when it is the stream's first, written as soon as the fifo has room,
//     never counted in `overflows`.
//   stop seen while HEAD/BODY (this packet's header is already written):
//     the packet in progress ends, then the same 16-byte END_OF_BURST
//     packet closes the stream, unless that packet was already marked
//     END_OF_BURST (a stop seen at its START) and ends the stream itself.
//   stop seen while DROP (a packet is being discarded for lack of room):
//     the dropped samples are consumed, then the 16-byte END_OF_BURST
//     carries OVERFLOW; if the stream's count was used up by a dropped
//     packet, that header-only packet is the stream's only one.
// A header-only packet's time is t_end, the time just after the stream's
// last sample (0 after reset: a stream that never sent a sample has no
// last sample and the field carries the previous stream's t_end).
// The first packet carries START_OF_BURST, the last END_OF_BURST; every
// packet HAS_TIME = the time of its first sample, so a gap between packets
// is time - (previous time + previous n).
//
// Configuration is checked when start is seen, from the values that would be
// latched: format must be 1 (sc16) or 2 (sc12) and channels must be nonzero
// (the port is 2 bits, so bits outside [1:0] cannot reach this module; 0 is
// the only invalid value). Otherwise start is ignored - the framer stays
// IDLE, running stays low, nothing is latched and no packet is written, so
// the host reads rx_ctrl's running bit as 0. A stream that does run was
// checked at its start, and it uses only its latched run_* copies, so no
// invalid configuration can reach a packet; the check is not repeated.
// Overflow: if the packet_fifo has no room when a packet would start, its
// n samples are dropped (counted in `overflows`) and the next packet carries
// OVERFLOW; if that was the stream's last packet, a header-only END_OF_BURST
// packet (with OVERFLOW) follows.
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
  input  wire        timed,       // start at `at`, else at once
  input  wire [63:0] at,
  input  wire [31:0] count,
  // packets
  input  wire        w_room,
  output reg         w_valid = 0,
  output reg         w_last = 0,
  output reg  [31:0] w_data = 0,
  // status
  output wire        running,
  output reg  [31:0] overflows = 0   // sample times dropped for lack of room (event OVERFLOW)
);
  `include "protocol.vh"
  localparam FULL_WORDS = 4096;

  // -- bits per sample time and per value ---------------------------------------
  // the running stream's configuration, latched at start
  reg  [3:0]  run_format = 1;
  reg  [1:0]  run_channels = 1;
  reg  [12:0] run_spp = 16;
  reg         run_timed = 0;
  reg  [63:0] run_at = 0;
  wire       sc12  = run_format == 4'd2;
  wire       two   = run_channels == 2'b11;
  // a start is taken only with a configuration the host can be given: the
  // latched copies are only ever written by a start that passed this
  wire       cfg_ok = (format == 4'd1 || format == 4'd2) && channels != 2'b00;
  wire [6:0] vbits = sc12 ? 7'd12 : 7'd16;             // bits per value
  wire [6:0] tbits = two ? vbits << 2 : vbits << 1;    // bits per sample time: 24 32 48 64
  // the selected values of one sample time, low first, packed; bits above
  // tbits are zero
  wire [11:0] i0 = s_data[11:0], q0 = s_data[23:12], i1 = s_data[35:24], q1 = s_data[47:36];
  wire [11:0] ia = run_channels[0] ? i0 : i1, qa = run_channels[0] ? q0 : q1;   // the first (or only) channel
  wire [63:0] packed = sc12 ? (two ? {16'd0, q1, i1, q0, i0} : {40'd0, qa, ia})
                            : (two ? {q1, 4'd0, i1, 4'd0, q0, 4'd0, i0, 4'd0} : {32'd0, qa, 4'd0, ia, 4'd0});
  // sample times in a full packet: 16368 payload bytes / bytes per sample time
  wire [12:0] full  = sc12 ? (two ? 13'd2728 : 13'd5456) : (two ? 13'd2046 : 13'd4092);
  // at least 16: a packet costs 5 cycles besides its payload words (START,
  // 4 header words) and the radio cannot wait, so n / (5 + words(n)) must
  // exceed the top rate in sample times per cycle: 0.6144 at 61.44 MS/s
  // (n >= 8, 1 channel sc16), 0.3072 at 2 x 30.72 (n >= 4); 16 leaves margin

  // -- stream and packet state ----------------------------------------------------
  localparam IDLE = 0, ARMED = 1, START = 2, HEAD = 3, BODY = 4, DROP = 5;
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

  // n and the packet's size for the next packet, from the stream's remainder,
  // in a pipeline of registers (100 MHz: one compare or one adder per
  // stage), each stage computed every cycle from the one before:
  //   1  n = min(left, spp) (spp if endless); ends = n takes all of left
  //   2  L = 16 + n * B bytes, B = tbits / 8 = 3 4 6 8, by shifts and one
  //      add (3 n = 2 n + n, 6 n = 2 (3 n)); w = ceil(L / 4) = (n B + 19) / 4
  //   3  words = w, + 1 if w is a multiple of 256 below 4096 (S(L))
  // (spp is clamped one stage earlier.) `age` counts cycles since `left`
  // last changed; START acts only at age >= 4, when all stages describe the
  // current `left`. On the normal path HEAD alone takes 4 cycles, so this
  // only delays the rare quick returns (stream start, a short DROP).
  reg  [12:0] spp_c = 16;
  always @(posedge clk) spp_c <= run_spp < 16 ? 13'd16 : run_spp > full ? full : run_spp;
  reg  [12:0] n_new = 0, w_raw = 0, w_all = 0;
  reg  [15:0] len = 0;
  reg         ends = 0;           // this packet takes the rest of a counted stream
  reg  [2:0]  age = 0;
  wire [15:0] n3     = {n_new, 1'b0} + n_new;
  wire [15:0] pbytes = sc12 ? (two ? {n3[14:0], 1'b0} : n3) : (two ? {n_new, 3'b0} : {n_new, 2'b0});
  always @(posedge clk) begin
    n_new <= endless || left >= spp_c ? spp_c : left[12:0];
    ends  <= !endless && left <= spp_c;
    len   <= 16 + pbytes;
    w_raw <= (pbytes + 19) >> 2;
    w_all <= w_raw + (w_raw[7:0] == 0 && w_raw != FULL_WORDS);
  end
  wire        last_packet = ends || stopping;
  // START owes a header-only END_OF_BURST instead of a data packet: stop
  // arrived before this packet's header, or the stream's count was used up
  // by a dropped packet. Loaded like a data packet's header, so HEAD writes
  // and ends it (words == 4, w_last on its last word).
  wire        eob_owed = state == START && ((!endless && left == 0) || stopping);

  // accumulator: write a word when 32 bits are held or the packet's samples
  // are all in and bits remain; take a sample when it fits
  wire in_body   = state == BODY;
  wire emit_data = in_body && (nb >= 32 || (n == 0 && words != 0));
  wire [6:0] nb1 = emit_data ? (nb >= 32 ? nb - 7'd32 : 7'd0) : nb;
  wire take_body = in_body && n != 0 && s_valid && nb1 + tbits <= 96;
  // samples consumed outside a packet: discarded (idle, before the start
  // time, dropped for lack of room)
  wire take_skip = s_valid && (state == IDLE || eob_owed ||
                               (state == ARMED && run_timed && s_time < run_at) ||
                               (state == DROP && n != 0));
  assign s_take = take_body || take_skip;

  always @(posedge clk) begin
    w_valid <= 0; w_last <= 0;
    if (rst) begin
      state <= IDLE; nb <= 0;
    end else begin
      if (stop && state != IDLE) stopping <= 1;
      if (age != 4) age <= age + 1;               // a later `age <= 0` wins
      case (state)
        IDLE: if (start && cfg_ok) begin
          first <= 1; overflow <= 0; stopping <= 0; seq <= 0;
          endless <= count == 0; left <= count; age <= 0; state <= ARMED;
          run_format <= format; run_channels <= channels; run_spp <= spp;
          run_timed <= timed; run_at <= at;
        end
        ARMED: if (stopping) state <= IDLE;
          else if (s_valid && !(run_timed && s_time < run_at)) state <= START;
        // a packet begins at the sample now at the head; if the next packet
        // would be empty - its count was used up by a dropped packet, or stop
        // arrived with no packet begun - the stream closes with a header-only
        // END_OF_BURST instead (HEAD writes it and ends on its last word)
        START: if (age != 4) ;                     // the size pipeline is catching up
        else if (eob_owed) begin                   // header-only END_OF_BURST
          if (w_room) begin
            hw <= 0; words <= 4; t0 <= t_end;
            h0 <= {VERSION, 2'd0, run_channels, run_format, T_RX, 16'd16};
            // last_packet is set here: ends (count used up) or stopping
            // flags OVERFLOW, END_OF_BURST, START_OF_BURST, HAS_TIME = 1
            h1 <= {12'd0, overflow, last_packet, first, 1'b1, seq};
            state <= HEAD;
          end
        end else if (s_valid) begin
          n <= n_new; t0 <= s_time; t_end <= s_time + n_new;
          if (!endless) left <= left - n_new;
          age <= 0;
          if (w_room) begin
            words <= w_all; hw <= 0;
            h0 <= {VERSION, 2'd0, run_channels, run_format, T_RX, len};
            h1 <= {12'd0, overflow, last_packet, first, 1'b1, seq};   // as above
            first <= 0; overflow <= 0; seq <= seq + 1;
            state <= HEAD;
          end else begin
            overflows <= overflows + n_new; overflow <= 1;
            state <= DROP;
          end
        end
        DROP: if (n == 0 || (n == 1 && take_skip)) state <= START;
        HEAD: begin
          w_valid <= 1; hw <= hw + 1; words <= words - 1;
          w_last <= words == 1;                    // the packet is header only
          case (hw)
            0: w_data <= h0;
            1: w_data <= h1;
            2: w_data <= t0[31:0];
            default: begin
              w_data <= t0[63:32];
              if (words == 1) state <= h1[END_OF_BURST] ? IDLE : START;
              else state <= BODY;
            end
          endcase
        end
        BODY: begin
          if (emit_data) begin
            w_valid <= 1; w_data <= acc[31:0]; words <= words - 1;
            w_last <= words == 1;
            if (words == 1) state <= h1[END_OF_BURST] ? IDLE : START;
          end
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
