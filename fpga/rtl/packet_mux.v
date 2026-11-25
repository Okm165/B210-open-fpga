// SPDX-License-Identifier: GPL-3.0-or-later
//
// packet_mux - two packet streams (packet_fifo read sides) into one, a
// whole packet at a time: results and events share the FPGA -> host
// control thread.
//
// While no packet is being read the output shows a source with a packet,
// preferring the one not served last (so neither can starve the other);
// from the first word taken to the last it stays with that source. The
// output keeps packet_fifo's promise: o_avail means a whole packet, taken
// one word per cycle to its end.
`default_nettype none

module packet_mux (
  input  wire        clk, rst,
  input  wire        a_avail, a_last,
  input  wire [31:0] a_data,
  output wire        a_take,
  input  wire        b_avail, b_last,
  input  wire [31:0] b_data,
  output wire        b_take,
  output wire        o_avail, o_last,
  output wire [31:0] o_data,
  input  wire        o_take
);
  reg locked = 0, cur = 0, last_served = 1;   // cur, last_served: 0 = a, 1 = b
  // the source shown: the locked one, else the one with a packet, the one
  // not served last if both have one
  wire pick = locked ? cur : (a_avail && b_avail) ? !last_served : !a_avail;
  assign o_avail = pick ? b_avail : a_avail;
  assign o_data  = pick ? b_data  : a_data;
  assign o_last  = pick ? b_last  : a_last;
  assign a_take  = o_take && !pick;
  assign b_take  = o_take && pick;
  always @(posedge clk)
    if (rst) begin locked <= 0; last_served <= 1; end
    else if (o_take && o_avail) begin
      if (o_last) begin locked <= 0; last_served <= pick; end
      else begin locked <= 1; cur <= pick; end
    end
endmodule

`default_nettype wire
