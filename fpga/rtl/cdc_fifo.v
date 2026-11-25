// SPDX-License-Identifier: GPL-3.0-or-later
//
// cdc_fifo - a small FIFO of W-bit entries between two clocks, in LUT RAM.
//
// Write side: w_valid writes w_data unless w_full (then the entry is lost:
// the writer, the radio, cannot wait; it counts the loss itself).
// Read side, show-ahead: r_valid says r_data is the oldest entry; r_take
// consumes it.
// Pointers of AW + 1 bits cross Gray-coded through two registers, as in
// packet_fifo (Cummings, SNUG 2002): each side's copy of the other's
// pointer lags the truth, so w_full and !r_valid are never wrong in the
// unsafe direction. A word written is visible to the reader 3 to 4 reader
// cycles later.
`default_nettype none

module cdc_fifo #(
  parameter W = 64,
  parameter AW = 4            // depth 2^AW entries
) (
  input  wire         wclk, w_rst,
  input  wire         w_valid,
  input  wire [W-1:0] w_data,
  output wire         w_full,
  input  wire         rclk, r_rst,
  output wire         r_valid,
  output wire [W-1:0] r_data,
  input  wire         r_take
);
  localparam DEPTH = 1 << AW;
  reg [W-1:0] mem [0:DEPTH-1];

  reg [AW:0] wp = 0, wp_g = 0, rp = 0, rp_g = 0;
  (* ASYNC_REG = "TRUE" *) reg [AW:0] rp_g1 = 0, rp_g2 = 0, wp_g1 = 0, wp_g2 = 0;

  // full: the writer is a whole depth ahead of what it knows was read; in
  // Gray code that is: top two bits inverted, the rest equal
  assign w_full = wp_g == {~rp_g2[AW:AW-1], rp_g2[AW-2:0]};
  wire [AW:0] wp_n = wp + 1;
  always @(posedge wclk) begin
    rp_g1 <= rp_g; rp_g2 <= rp_g1;
    if (w_rst) begin wp <= 0; wp_g <= 0; end
    else if (w_valid && !w_full) begin
      mem[wp[AW-1:0]] <= w_data;
      wp <= wp_n; wp_g <= wp_n ^ (wp_n >> 1);
    end
  end

  assign r_valid = rp_g != wp_g2;
  assign r_data  = mem[rp[AW-1:0]];
  wire [AW:0] rp_n = rp + 1;
  always @(posedge rclk) begin
    wp_g1 <= wp_g; wp_g2 <= wp_g1;
    if (r_rst) begin rp <= 0; rp_g <= 0; end
    else if (r_take && r_valid) begin rp <= rp_n; rp_g <= rp_n ^ (rp_n >> 1); end
  end
endmodule

`default_nettype wire
