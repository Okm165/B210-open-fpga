// SPDX-License-Identifier: GPL-3.0-or-later
//
// packet_fifo - a FIFO of whole packets, one clock.
//
// Units: words of 32 bits, each carrying a `last` mark (33 bits an entry).
// MAX is the longest packet in words; the depth is 2^AW words, with
// MAX <= 2^AW. w_used, r_used and the room/avail decisions count words.
//
// Invariant:
//   * A packet becomes visible to the reader only once its last word is
//     written: r_avail is high only when the packet that r_data starts is
//     whole, and it stays high until that packet's last word is taken, so
//     the reader moves a whole packet without waiting. A word of a packet
//     still being written is kept, never shown.
//   * Words and their `last` marks come out in the order they were written:
//     word j of a packet the writer wrote is word j of the packet the reader
//     takes, and the reader sees the packet's end exactly where the writer
//     put it. The reader never reads a word that was not written, the writer
//     never writes over a word the reader has not taken.
// These are the two promises fx3_master relies on (out_room, in_avail: "a
// source holds a whole packet, never withdrawn untaken") and the radio side
// relies on them too.
//
// Write side:
//   w_valid, w_data, w_last   one word; w_last marks a packet's last word.
//   w_room   there is room for one more packet: the FIFO holds fewer than
//            ROOM words, where ROOM = MAX when the depth is 2*MAX or less
//            and depth - MAX when it is deeper (deeper than 2*MAX, a FIFO
//            buffers several packets and the room is what is left for one
//            more). Check it in the cycle before the first word of a packet
//            (or with it); a packet has at most MAX words, so it then always
//            fits - the FIFO holds 2*MAX - 1 words at most when
//            depth <= 2*MAX and depth - 1 at most otherwise.
//            A word is taken at an edge with w_valid && w_room. The room
//            check is the writer's promise, as it was in the two-clock
//            version; the module takes a word with w_valid as long as the
//            memory has a slot (fewer than 2^AW words in), which a writer
//            that keeps its promise never reaches, and a writer that breaks
//            it loses the word rather than writing over an unread one.
//   w_used   words in the FIFO in this cycle, before this cycle's write; a
//            high-water register can follow it.
//   A packet must be written whole: no other packet's words in between.
//
// Read side, show-ahead:
//   r_avail  the read buffer holds a word of a complete packet; r_data /
//            r_last are that word, the oldest one, in this cycle.
//   r_take   consume r_data: a word is read at an edge with r_take && r_avail.
//   r_used   words in the FIFO, the same count as w_used (a packet being
//            written counts before it is shown).
//
// Latency: registered everywhere. r_avail rises 3 cycles after a packet's
// last word is written (commit, fetch, buffer); from then the packet's words
// follow on r_data one per cycle for as long as the reader takes them.
// r_data, r_last and r_avail come straight from registers.
//
// Pointers, all counting words modulo 2^(AW+1); the extra bit tells a full
// FIFO from an empty one and makes the differences wrap correctly:
//   wp   words written            used = wp - rp   (words in the FIFO,
//   wc   words of whole packets                     prefetched ones too)
//   ra   words fetched from memory into the read buffer
//   rp   words taken by the reader
// Only words below wc are fetched, so everything in the read buffer belongs
// to a whole packet: r_avail = "the buffer is not empty".
//
// Read path, and why it is built this way: the memory is up to 256 BRAMs
// wide on the rings, and its read address fans out over several ns of
// routing. So the address is a register (ra), never a function of r_take:
// a reader's take decision (its own compare chain) must not reach the BRAM
// address in the same cycle. The cost is a 3-word buffer after the memory:
//   cycle n    fetch = ra != wc && (q_valid + count) < 3: read mem[ra]
//   cycle n+1  the word is in q (the memory's output register)
//   cycle n+2  q is appended to the buffer; the head is buf[0]
// At most 3 words are ever in flight (q plus the buffer), and with a take
// every cycle the fetch runs every cycle too (steady state: 1 in q, 1 in the
// buffer), so the reader is never starved inside a packet.
//
// A word is fetched at least one cycle after its write (wc moves at the
// write's edge and the fetch compares the registered wc), so the memory is
// never read and written at the same address in the same cycle.
//
// Reset: synchronous, one clock, active high; it empties the FIFO.
`default_nettype none

module packet_fifo #(
  parameter AW  = 12,         // log2 of the depth in words
  parameter MAX = 4096        // words in the longest packet
) (
  input  wire          clk,
  input  wire          rst,      // synchronous, holds the pointers at 0
  // write side
  input  wire          w_valid,
  input  wire          w_last,
  input  wire [31:0]   w_data,
  output wire          w_room,   // room for a whole more packet
  output wire [AW:0]   w_used,   // words in the FIFO
  // read side, show-ahead
  input  wire          r_take,
  output wire          r_avail,
  output wire          r_last,
  output wire [31:0]   r_data,
  output wire [AW:0]   r_used
);
  localparam DEPTH = 1 << AW;
  // room for one more packet: the whole depth less one packet, but never
  // less than one packet itself (a depth of 2*MAX or less holds one)
  localparam ROOM  = (DEPTH - MAX) > MAX ? (DEPTH - MAX) : MAX;
  generate if (MAX > DEPTH) begin : max_exceeds_depth
    initial begin $display("packet_fifo: MAX %0d > depth %0d", MAX, DEPTH); $finish; end
  end endgenerate

  reg [32:0] mem [0:DEPTH-1];

  reg  [AW:0] wp = 0, wc = 0, ra = 0, rp = 0;
  wire [AW:0] used = wp - rp;                     // words in the FIFO
  wire        w_en = w_valid && (used < DEPTH);   // the memory has a slot
  // read side: q = the memory's output register, buf = the 3-word buffer
  reg  [32:0] q = 0;
  reg         q_valid = 0;
  reg  [32:0] buf0 = 0, buf1 = 0, buf2 = 0;
  reg  [1:0]  count = 0;                          // words in buf, 0 .. 3
  wire        fetch = ra != wc && ({1'b0, q_valid} + count) < 3;
  wire        take  = r_take && count != 0;

  assign w_room  = used < ROOM;
  assign w_used  = used;
  assign r_used  = used;
  assign r_avail = count != 0;
  assign {r_last, r_data} = buf0;

  // the buffer after this cycle: take removes buf0, q (if valid) is appended
  wire [1:0] kept = count - take;                 // words left after the take
  always @(posedge clk) begin
    if (w_en) mem[wp[AW-1:0]] <= {w_last, w_data};
    q <= mem[ra[AW-1:0]];
    if (take) begin buf0 <= buf1; buf1 <= buf2; end
    if (q_valid) case (kept)
      2'd0: buf0 <= q;
      2'd1: buf1 <= q;
      default: buf2 <= q;
    endcase
    if (rst) begin
      wp <= 0; wc <= 0; ra <= 0; rp <= 0; q_valid <= 0; count <= 0;
    end else begin
      wp <= wp + w_en;
      if (w_en && w_last) wc <= wp + 1;           // the packet is whole
      ra <= ra + fetch;
      q_valid <= fetch;
      rp <= rp + take;
      count <= kept + q_valid;
    end
  end
endmodule

`default_nettype wire
