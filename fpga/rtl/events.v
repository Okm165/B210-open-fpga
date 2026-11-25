// SPDX-License-Identifier: GPL-3.0-or-later
//
// events - event packets from counters (docs/PROTOCOL.md 5).
//
// The FPGA counts what goes wrong or completes; an event is a counter's
// increase. Every INTERVAL cycles the counters are compared with what was
// last reported; if any rose, one event packet goes out with one event per
// counter that rose:
//   word 0  code[7:0], channels[15:8] (0: not channel specific), 0
//   word 1  count: the increase since the last report
//   words 2-3  time: the FPGA time when the packet was built
// Nothing is lost when the host is slow or the FIFO full: the increases
// add up until a packet can go. Codes (index k = code - 1):
//   1 OVERFLOW    rx sample times dropped
//   2 UNDERFLOW   tx gaps inside a burst
//   3 LATE        tx bursts that came after their time
//   4 SEQ_ERROR   tx sequence jumps
//   5 BURST_ACK   tx bursts played to their END_OF_BURST
//   6 BAD_PACKET  tx packets malformed or cut short
// Counters are free-running 32-bit binary in this clock; differences are
// taken modulo 2^32.
`default_nettype none

module events #(
  parameter INTERVAL = 10000          // cycles: 100 us at 100 MHz
) (
  input  wire         clk, rst,
  input  wire [191:0] counts,         // 6 x 32 bits, code 1 in bits 31:0
  input  wire [63:0]  now,
  // event packets into a packet_fifo
  input  wire         w_room,
  output reg          w_valid = 0,
  output reg          w_last = 0,
  output reg  [31:0]  w_data = 0
);
  `include "protocol.vh"
  localparam K = 6;
  reg [191:0] reported = 0, snap = 0;
  reg [31:0]  timer = 0;
  reg [15:0]  seq = 0;
  reg [63:0]  t = 0;
  reg [K-1:0] todo = 0;                // events still to write
  reg [2:0]   k = 0;                   // the event being written
  reg [1:0]   w = 0;                   // its word
  reg [2:0]   hw = 0;                  // header word
  reg [1:0]   state = 0;
  localparam IDLE = 0, HEAD = 1, BODY = 2;

  // which counters rose since the last report, and how many
  reg [K-1:0] rose;
  reg [2:0]   m;
  integer i;
  always @* begin
    m = 0;
    for (i = 0; i < K; i = i + 1) begin
      rose[i] = counts[32*i +: 32] != reported[32*i +: 32];
      m = m + rose[i];
    end
  end
  wire [15:0] len = 16 + 16 * m;
  // the lowest code still to write
  reg [2:0] first;
  always @* begin
    first = 0;
    for (i = K - 1; i >= 0; i = i - 1) if (todo[i]) first = i;
  end
  // the next code to write after k
  reg [2:0] first_after_k;
  always @* begin
    first_after_k = 0;
    for (i = K - 1; i >= 0; i = i - 1) if (todo[i] && i != k) first_after_k = i;
  end
  wire [31:0] increase = snap[32*k +: 32] - reported[32*k +: 32];

  always @(posedge clk) begin
    w_valid <= 0; w_last <= 0;
    if (timer != 0) timer <= timer - 1;
    if (rst) begin
      state <= IDLE; reported <= counts; timer <= INTERVAL;
    end else case (state)
      IDLE: if (timer == 0 && m != 0 && w_room) begin
        snap <= counts; todo <= rose; t <= now; hw <= 0; state <= HEAD;
        w_valid <= 1; w_data <= {VERSION, 8'd0, T_EVENT, len};
      end
      HEAD: begin
        w_valid <= 1; hw <= hw + 1;
        case (hw)
          0: w_data <= {15'd0, 1'b1, seq};          // flags: HAS_TIME only
          1: w_data <= t[31:0];
          default: begin w_data <= t[63:32]; k <= first; w <= 0; state <= BODY; end
        endcase
      end
      BODY: begin
        w_valid <= 1; w <= w + 1;
        case (w)
          0: w_data <= {29'd0, k + 3'd1};
          1: w_data <= increase;
          2: w_data <= t[31:0];
          default: begin
            w_data <= t[63:32];
            reported[32*k +: 32] <= snap[32*k +: 32];
            todo[k] <= 0;
            if (todo == (1 << k)) begin                // the last event
              w_last <= 1; seq <= seq + 1; timer <= INTERVAL; state <= IDLE;
            end else begin
              k <= first_after_k; w <= 0;
            end
          end
        endcase
      end
      default: state <= IDLE;
    endcase
  end
endmodule

`default_nettype wire
