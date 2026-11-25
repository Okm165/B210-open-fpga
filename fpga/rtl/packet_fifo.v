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
//   r_avail  the FIFO holds a word of a complete packet; r_data / r_last are
//            that word, the oldest one, in this cycle.
//   r_take   consume r_data: a word is read at an edge with r_take && r_avail.
//   r_used   words in the FIFO, the same count as w_used (a packet being
//            written counts before it is shown).
//
// Latency: registered both ways. A word is in the read register in the cycle
// after it is written; r_avail rises in the cycle after a packet's last word
// is written, and from then the packet's words follow on r_data one per
// cycle as they are taken. There is no combinational path from w_data to
// r_data.
//
// Pointers, all counting words modulo 2^(AW+1); the extra bit tells a full
// FIFO from an empty one and makes the differences below wrap correctly:
//   wp   words written            wc   words of complete packets
//   rp   words read and passed    used = wp - rp    (words in the FIFO)
//                                 ready = wc - rp   (words of complete
//                                 packets not read yet, r_avail is ready != 0)
// Both sides are the same clock: nothing crosses, so there is no Gray code
// and no synchroniser, and each pointer is a single register.
//
// Memory: one simple dual-port RAM, written at wp with a registered read at
// the head's successor, rp + take: the word that becomes the head is in the
// read register by the time the head is taken, so the head can be shown for
// as long as the reader needs it without a second register. When the FIFO is
// empty, or holds only the word being taken, the word written in this cycle
// is the head next cycle; it is forwarded from w_data rather than read (a
// read of the slot being written would return the old contents).
//
// Reset: synchronous, one clock, active high. One cycle is enough: it puts
// the three pointers and the read register at 0, so the FIFO is empty after
// it.
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

  reg  [AW:0] wp = 0, rp = 0, wc = 0;
  wire [AW:0] used  = wp - rp;                    // words in the FIFO
  wire [AW:0] ready = wc - rp;                    // words of complete packets
  wire        w_en  = w_valid && (used < DEPTH);  // the memory has a slot
  wire        take  = r_take && ready != 0;
  wire [AW:0] rp_n  = rp + take;                  // the head next cycle

  assign w_room  = used < ROOM;
  assign w_used  = used;
  assign r_used  = used;
  assign r_avail = ready != 0;

  // the head, in a register: the memory's registered read output
  reg  [32:0] m = 0;
  // the word being written is the head next cycle: the FIFO is empty, or the
  // only word in it is the one being taken. Reading the slot the writer fills
  // would return its old contents, so forward the word instead.
  wire        fwd = w_en && (used == take);

  assign {r_last, r_data} = m;

  always @(posedge clk) begin
    if (w_en) mem[wp[AW-1:0]] <= {w_last, w_data};
    if (fwd) m <= {w_last, w_data};
    else if (take) m <= mem[rp_n[AW-1:0]];
    if (rst) begin
      wp <= 0; rp <= 0; wc <= 0;
    end else begin
      wp <= wp + w_en;
      rp <= rp_n;
      if (w_en && w_last) wc <= wp + 1;           // the packet is whole
    end
  end
endmodule

`default_nettype wire
