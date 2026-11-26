// SPDX-License-Identifier: GPL-3.0-or-later
//
// gray_sync - a binary counter from another clock domain, read exactly.
//
// The source keeps its counter Gray-coded (g = b ^ (b >> 1)) and changes it
// by at most one step per source clock, so at most one bit changes at a
// time: a register sampling it mid-change gets the old or the new value,
// never a mix. Two registers here take the Gray value; then it is turned
// back into binary, b[i] = XOR of g[W-1:i], in two pipeline stages so a
// 64-bit counter meets 100 MHz:
//   1. within each 16-bit chunk, the XOR of the chunk's bits above i;
//   2. each chunk XORs in the parity of every chunk above it.
// `b` is the source's count 4 clocks (of clk) ago or later; it never moves
// backwards and never shows a value the source did not hold.
`default_nettype none

module gray_sync #(
  parameter W = 64            // a multiple of 16
) (
  input  wire         clk,
  input  wire [W-1:0] g_in,   // Gray-coded, from the other domain
  output reg  [W-1:0] b = 0
);
  localparam C = W / 16;
  (* ASYNC_REG = "TRUE" *) reg [W-1:0] g1 = 0, g2 = 0;
  reg [W-1:0] prefix = 0;     // per chunk: XOR of the chunk's bits from the top down to i
                              // (`local` would be a SystemVerilog keyword)
  integer c, i;
  reg p;
  always @(posedge clk) begin
    g1 <= g_in; g2 <= g1;
    for (c = 0; c < C; c = c + 1) begin
      p = 0;
      for (i = 15; i >= 0; i = i - 1) begin p = p ^ g2[16*c + i]; prefix[16*c + i] <= p; end
    end
    for (c = C - 1; c >= 0; c = c - 1) begin
      // parity of the chunks above c: the lowest bit of each one's prefix XOR
      p = 0;
      for (i = c + 1; i < C; i = i + 1) p = p ^ prefix[16*i];
      b[16*c +: 16] <= prefix[16*c +: 16] ^ {16{p}};
    end
  end
endmodule

`default_nettype wire
