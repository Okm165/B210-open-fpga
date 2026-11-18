// tb_tx_pins.v - the TX half of the AD9361 interface, which no bench covered.
//
// b200_io drives tx_data through ODDRs: D1 = I on the rising half, D2 = Q on
// the falling half, with tx_frame marking the frame and tx_clk reproducing the
// interface clock.  The AD9361 samples both halves of one clock period as one
// sample, so the invariant is latency-free:
//
//     I(posedge) = n,  Q(negedge) = n + 2048   =>   Q - I = 2048 (mod 4096)
//
// for every clock period.  No alignment knowledge is needed: if the two halves
// came from different samples the difference would not be constant.
`timescale 1ns/1ps

module tb_tx_pins;

   reg rx_clk = 0;  always #8.138 rx_clk = ~rx_clk;
   reg areset = 1;
   reg mimo   = 0;

   wire radio_clk, radio_rst;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   reg [11:0] tx_i0 = 12'd0, tx_q0 = 12'd0;

   b200_io dut (
      .areset(areset), .mimo(mimo),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(tx_i0), .tx_q0(tx_q0), .tx_i1(12'd0), .tx_q1(12'd0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(1'b0), .rx_data(12'd0),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   // stimulus: a counter on I and the same counter plus 2048 on Q, so a
   // half-cycle mismatch is visible as a different constant
   integer n = 0;
   always @(posedge rx_clk) begin
      tx_i0 <= n[11:0];
      tx_q0 <= (n + 2048) & 4095;
      n     <= n + 1;
   end

   // ---- checks -----------------------------------------------------------
   integer checked = 0, bad_pair = 0, bad_clk = 0, bad_frame = 0;
   integer i_val, q_val, d;

   always @(posedge rx_clk) if (!areset) begin
      #2;                                   // let the ODDRs settle
      i_val = tx_data;
      if (tx_clk !== rx_clk)  bad_clk   = bad_clk + 1;
      if (tx_frame !== 1'b1)  bad_frame = bad_frame + 1;   // SISO: frame high in first half
   end

   always @(negedge rx_clk) if (!areset) begin
      #2;
      q_val = tx_data;
      d = (q_val - i_val) & 4095;
      checked = checked + 1;
      if (d != 2048) begin
         bad_pair = bad_pair + 1;
         if (bad_pair < 4)
            $display("TX-PINS: I=%0d Q=%0d differ by %0d (expected 2048)", i_val, q_val, d);
      end
      if (tx_clk !== rx_clk) bad_clk = bad_clk + 1;
      if (tx_frame !== 1'b0) bad_frame = bad_frame + 1;    // and low in the second half
   end

   initial begin
      repeat (8) @(posedge rx_clk);
      areset <= 0;
      repeat (4000) @(posedge rx_clk);
      $display("TX-PINS: %0d clock periods, %0d I/Q pair errors, %0d tx_clk errors, %0d frame errors",
               checked, bad_pair, bad_clk, bad_frame);
      if (checked > 1000 && bad_pair == 0 && bad_clk == 0 && bad_frame == 0)
         $display("TX-PINS: PASS - I on the rising half, Q on the falling half, frame and clock correct");
      else
         $display("TX-PINS: FAIL");
      $finish;
   end

endmodule
