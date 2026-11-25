// SPDX-License-Identifier: GPL-3.0-or-later
//
// packet_fifo - a FIFO of whole packets between two clocks (or one).
//
// Words are 32 bits plus a `last` mark. A packet becomes visible to the
// reader only once its last word is written, so the reader can move a
// whole packet without waiting; the writer reserves room for a whole
// packet before it starts one. These are the two promises fx3_master
// relies on (out_room, in_avail), and the radio side relies on them too.
//
// Depth: a stream of full packets needs more than 2 MAX words: a finished
// packet waits whole until the reader takes it, while the writer reserves
// MAX words (+ 1, see w_room) for the next.
//
// Write side (wclk):
//   w_room   at least MAX words free, counting the word on w_data in this
//            cycle as written. Check it in the cycle before the first word
//            of a packet (or with it); a packet has at most MAX words, so it
//            then always fits.
//   w_valid, w_data, w_last   one word; w_last marks a packet's last word.
// Read side (rclk), show-ahead:
//   r_avail  r_data / r_last hold a word of a complete packet: the packet
//            can be taken one word per cycle to its end without a gap.
//   r_take   consume r_data.
//
// Clock crossing: three pointers of AW + 1 bits (the extra bit tells full
// from empty), each counting words modulo 2^(AW+1):
//   wp      words written           (write side)
//   wc      words of complete packets (write side) -> Gray -> read side
//   rp      words read from memory   (read side)  -> Gray -> write side
// A Gray-coded count changes one bit per step, so a synchroniser that
// samples it mid-change gets the old or the new value, never a mix
// (Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO
// Design", SNUG 2002). The copies a side holds of the other side's pointer
// are therefore never ahead of the truth: the reader never reads a word not
// yet committed, the writer never overwrites a word not yet read.
//
//   free (write side) = 2^AW - (wp - rp_seen)          <= true free space
//   ready (read side) = wc_seen - rp                   <= true ready words
// Both differences are taken modulo 2^(AW+1), in AW+1 bits.
//
// Memory: one simple dual-port RAM, read with a registered output and one
// more pipeline register (2 cycles, so large depths meet timing at
// 100 MHz). Reads run ahead into a 4-entry queue whose head is r_data:
// 4 >= 2 cycles in flight + 1 being taken + 1, so a word taken every cycle
// is always replaced in time.
//
// Reset: w_rst and r_rst must be asserted together (each synchronous to its
// clock) and held for at least 4 cycles of the slower clock, so that the
// pointers' synchronised copies (2 registers + 1 conversion register) are
// 0 when it ends.
`default_nettype none

module packet_fifo #(
  parameter AW  = 12,         // log2 of the depth in words
  parameter MAX = 4096        // words in the longest packet
) (
  input  wire        wclk, w_rst,
  output reg         w_room = 0,
  input  wire        w_valid, w_last,
  input  wire [31:0] w_data,
  input  wire        rclk, r_rst,
  output wire        r_avail,
  output wire [31:0] r_data,
  output wire        r_last,
  input  wire        r_take
);
  localparam DEPTH = 1 << AW;
  generate if (MAX > DEPTH) begin : max_exceeds_depth
    initial begin $display("packet_fifo: MAX %0d > depth %0d", MAX, DEPTH); $finish; end
  end endgenerate

  function [AW:0] gray(input [AW:0] b); gray = b ^ (b >> 1); endfunction
  function [AW:0] bin(input [AW:0] g);
    integer i;
    begin bin[AW] = g[AW]; for (i = AW - 1; i >= 0; i = i - 1) bin[i] = bin[i+1] ^ g[i]; end
  endfunction

  reg [32:0] mem [0:DEPTH-1];

  // -- write side ---------------------------------------------------------------
  reg [AW:0] wp = 0, wc = 0, wc_g = 0;
  (* ASYNC_REG = "TRUE" *) reg [AW:0] rp_g1 = 0, rp_g2 = 0;
  reg [AW:0] rp_g = 0;                      // rp in Gray, read side
  wire [AW:0] wp_n = wp + w_valid;
  // the reader's pointer, converted to binary one cycle after it is
  // synchronised (a register between the XOR tree and the subtraction:
  // 100 MHz); it lags one cycle more, which only understates the room
  reg  [AW:0] rp_seen = 0;
  wire [AW:0] used = wp_n - rp_seen;         // words in memory once w_data is written
  wire [AW:0] used_next = used + w_valid;    // ... and once the next word is too
  always @(posedge wclk) begin
    if (w_valid) mem[wp[AW-1:0]] <= {w_last, w_data};
    rp_g1 <= rp_g; rp_g2 <= rp_g1; rp_seen <= bin(rp_g2);
    if (w_rst) begin
      wp <= 0; wc <= 0; wc_g <= 0; w_room <= 0;
    end else begin
      wp <= wp_n;
      if (w_valid && w_last) begin wc <= wp_n; wc_g <= gray(wp_n); end
      // in the next cycle w_room must count the word then on w_data, which
      // the writer may be presenting now already: reserve one more
      w_room <= used_next + MAX <= DEPTH;
    end
  end

  // -- read side ----------------------------------------------------------------
  reg [AW:0] rp = 0;
  (* ASYNC_REG = "TRUE" *) reg [AW:0] wc_g1 = 0, wc_g2 = 0;
  reg [32:0] m1 = 0, m2 = 0;                // memory output, pipeline register
  reg        v1 = 0, v2 = 0;                // they hold a word in flight
  reg [32:0] q [0:3];                       // queue, q[0] is the head
  reg [2:0]  qn = 0;                        // words in the queue
  reg  [AW:0] wc_seen = 0;                  // as rp_seen: one more cycle, understates `ready`
  wire [AW:0] ready = wc_seen - rp;
  // issue a read if a committed word is left and the queue will have room
  // for it: queue + in flight + this read <= 4, counting the one taken now
  wire       take  = r_take && qn != 0;
  wire       issue = ready != 0 && qn + v1 + v2 + 1 - take <= 4;
  assign r_avail = qn != 0;
  assign {r_last, r_data} = q[0];
  integer i;
  always @(posedge rclk) begin
    wc_g1 <= wc_g; wc_g2 <= wc_g1; wc_seen <= bin(wc_g2);
    m1 <= mem[rp[AW-1:0]]; m2 <= m1;
    if (r_rst) begin
      rp <= 0; rp_g <= 0; v1 <= 0; v2 <= 0; qn <= 0;
    end else begin
      v1 <= issue; v2 <= v1;
      if (issue) begin rp <= rp + 1; rp_g <= gray(rp + 1); end
      // shift out the taken head, append the word leaving the pipeline
      if (take) for (i = 0; i < 3; i = i + 1) q[i] <= q[i+1];
      if (v2) q[qn - take] <= m2;
      qn <= qn - take + v2;
    end
  end
endmodule

`default_nettype wire
