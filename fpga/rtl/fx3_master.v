// SPDX-License-Identifier: GPL-3.0-or-later
//
// fx3_master - master of the FX3 slave FIFO bus: moves whole FX3 DMA
// buffers between the FX3 and four local streams, one buffer per visit.
//
// Threads (FX3 A[1:0]), t = {c, in}, c = 0 data, 1 control:
//   0  data OUT     host -> FPGA   read,  to   out stream 0 (tx samples)
//   1  data IN      FPGA -> host   write, from in stream 0  (rx samples)
//   2  control OUT  host -> FPGA   read,  to   out stream 1 (commands)
//   3  control IN   FPGA -> host   write, from in stream 1  (results, events)
// One FX3 buffer is one packet in both directions (docs/PROTOCOL.md 1).
//
// The FX3 contract (Infineon AN65974; fpga/tests/fx3_model.v enforces it),
// in cycles: a pad value decided in cycle n is on the pad in cycle n+1 and
// sampled by the FX3 at the edge that ends it; a flag the FX3 drives in
// cycle m is seen by this logic in cycle m+1 (fx3_pads registers both).
//   - flags follow a new address ADDR_LAT = 2 edges after the FX3 samples
//     it: seen here 2 + ADDR_LAT cycles after the address is decided;
//   - READY drops RD_LAT = 2 edges after the last read, WR_LAT = 3 after the
//     last write: seen here 3 + RD_LAT / 3 + WR_LAT cycles after them;
//   - a read word is on D 2 edges after its SLRD#: captured here 4 cycles
//     after the read is decided;
//   - WMARK (read threads, W = 5): once seen low, at most W - 1 = 4 words
//     are still to come counting the strobes already issued.
// Every wait below is that latency plus MARGIN cycles, so the master works
// for FX3 latencies up to MARGIN cycles longer than the specified ones.
// WMARK has 1 cycle of slack, fixed by W and this pipeline: 3 strobes after
// the flag is sampled, of W - 1 = 4 allowed (a WMARK 1 cycle late still
// passes, 2 cycles late overreads). fpga/tests/tb_fx3_master.v measures
// both margins.
//
// A visit (one buffer):
//   IDLE    pick the next thread, after the current one, whose local side
//           can take a whole buffer (out_room) or holds a whole packet
//           (in_avail); put its address on A.
//   SETTLE  SETTLE cycles: flags valid for this address and for the end of
//           any previous transfer. Then, if READY:
//   WRITE   one word per cycle until in_last (PKTEND# with it, unless it
//           fills the buffer, which commits by itself).
//   READ    burst: SLRD# while WMARK is high. On WMARK low 3 strobes are
//           still in flight (seen at E, decided E, on the pad E+1), so of
//           the W - 1 = 4 words at most 1 is left:
//   PEEK    PEEK cycles, then one more read if READY still says words are
//           left; else the buffer is done and its last word is marked.
//           READY can only fall once the buffer is empty, so a low READY
//           in any cycle of the wait ends the buffer: the FX3 must show
//           the gap between two buffers for 1 cycle (it takes "up to a few
//           microseconds" to load the next DMA descriptor, AN65974 7).
//   A read word is held back one word, since only READY tells which word
//   was the last.
//
// Bus ownership: the FPGA drives D only when SLOE# was high in the previous
// cycle and is high in the next (the FX3 drives until up to tOEZ = 8 ns
// after SLOE# rises), and stops driving before a read: SETTLE of a read
// thread already leaves D to the FX3.
//
// Throughput: per visit 1 + SETTLE cycles plus, for reads, about 2 * PEEK;
// for a 4096-word data buffer 99.5 % (write) / 99.3 % (read) of the bus.
`default_nettype none

module fx3_master #(
  parameter DATA = 4096,      // words per data buffer (16 KiB)
  parameter CTRL = 256,       // words per control buffer (1 KiB)
  parameter MARGIN = 2        // cycles of slack on every FX3 latency
) (
  input  wire        clk, rst,
  // fx3_pads: next pad values, active high
  output reg         wr, rd, oe, pkt_end, drive,
  output reg  [1:0]  thread,
  output reg  [31:0] dout,
  // fx3_pads: pad values at the last edge
  input  wire [31:0] din,
  input  wire        ready, wmark,
  // OUT streams (host -> FPGA), index c
  input  wire [1:0]  out_room,    // sink c can take a whole buffer
  output reg  [1:0]  out_valid,   // out_data is the sink's next word
  output reg  [31:0] out_data,
  output reg         out_last,
  // IN streams (FPGA -> host), index c, show-ahead
  input  wire [1:0]  in_avail,    // source c holds a whole packet (never withdrawn untaken)
  input  wire [31:0] in_data0, in_data1,
  input  wire [1:0]  in_last,
  output reg  [1:0]  in_take
);
  localparam ADDR_LAT = 2, RD_LAT = 2, WR_LAT = 3;
  // The IDLE cycle after a transfer adds one: last write decided at n, IDLE
  // at n+1, decision at n+1+SETTLE >= n + 3 + WR_LAT + MARGIN. That also
  // covers the address (2 + ADDR_LAT) and the end of a read (3 + RD_LAT).
  localparam SETTLE = 2 + WR_LAT + MARGIN;
  localparam PEEK   = 3 + RD_LAT + MARGIN;

  localparam IDLE = 3'd0, SET = 3'd1, WRITE = 3'd2, READ = 3'd3, PEEKING = 3'd4;
  reg [2:0]  state = IDLE, state_n;
  reg [3:0]  cnt = 0, cnt_n;          // SETTLE / PEEK countdown
  reg [12:0] n = 0, n_n;              // words written in this visit
  reg [1:0]  t = 0;                   // current thread: the address on A
  reg        oe_q = 0;                // SLOE# asserted on the pad now
  reg [3:0]  rp = 0;                  // reads decided 1..4 cycles ago
  reg [31:0] hold = 0;
  reg        hold_v = 0, hold_v_n;
  reg        gap = 0, gap_n;           // READY seen low during this PEEK

  wire        c    = t[1];
  wire        in   = t[0];
  wire [12:0] size = c ? CTRL : DATA;
  wire [31:0] src  = c ? in_data1 : in_data0;
  wire        src_last = c ? in_last[1] : in_last[0];

  // thread th's local side is ready for a whole buffer: index th = {c, in}
  wire [3:0] eligible = {in_avail[1], out_room[1], in_avail[0], out_room[0]};
  // the first eligible thread after t, cyclically (t itself last)
  reg [1:0] next_t;
  reg       any;
  integer   k;
  always @* begin
    next_t = t; any = 0;
    for (k = 4; k >= 1; k = k - 1)
      if (eligible[t + k[1:0]]) begin next_t = t + k[1:0]; any = 1; end
  end

  always @* begin
    state_n = state; cnt_n = cnt; n_n = n; hold_v_n = hold_v; gap_n = 0;
    wr = 0; rd = 0; oe = 0; pkt_end = 0; thread = t; dout = 0;
    in_take = 0; out_valid = 0; out_last = 0; out_data = hold;
    if (rp[3]) begin                      // a read word arrives
      out_valid[c] = hold_v;
      hold_v_n = 1;
    end
    case (state)
      IDLE: if (any) begin
        thread = next_t; state_n = SET; cnt_n = SETTLE - 1;
      end
      SET: if (cnt != 0) cnt_n = cnt - 1;
        else if (!ready || !eligible[t]) state_n = IDLE;
        else if (in) begin
          wr = 1; dout = src; in_take[c] = 1; n_n = 1;
          pkt_end = src_last;                   // a buffer holds more than 1 word
          if (src_last) state_n = IDLE; else state_n = WRITE;
        end else begin
          oe = 1; rd = 1;
          state_n = wmark ? READ : PEEKING; cnt_n = PEEK - 1;
        end
      WRITE: begin
        wr = 1; dout = src; in_take[c] = 1; n_n = n + 1;
        pkt_end = src_last && n + 1 != size;
        if (src_last || n + 1 == size) state_n = IDLE;
      end
      READ: begin
        oe = 1; rd = wmark;
        if (!wmark) begin state_n = PEEKING; cnt_n = PEEK - 1; end
      end
      PEEKING: begin
        oe = 1;
        if (cnt != 0) begin cnt_n = cnt - 1; gap_n = gap || !ready; end
        else if (ready && !gap) begin rd = 1; cnt_n = PEEK - 1; end
        else begin                         // buffer done: release the last word
          oe = 0; out_valid[c] = 1; out_last = 1; hold_v_n = 0; state_n = IDLE;
        end
      end
      default: state_n = IDLE;
    endcase
    // drive D in the next cycle only if SLOE# is high now and then, and not
    // while waiting to read (SETTLE of an OUT thread, READ, PEEK)
    drive = !oe && !oe_q && !((state_n == SET && !thread[0]) || state_n == READ || state_n == PEEKING);
    if (rst) begin
      wr = 0; rd = 0; oe = 0; pkt_end = 0; in_take = 0; out_valid = 0;
      state_n = IDLE; hold_v_n = 0; drive = !oe_q;
    end
  end

  always @(posedge clk) begin
    state <= state_n; cnt <= cnt_n; n <= n_n; t <= thread;
    oe_q <= oe; rp <= {rp[2:0], rd};
    hold_v <= hold_v_n; gap <= gap_n;
    if (rp[3]) hold <= din;
  end
endmodule

`default_nettype wire
