// tb_tx_pins.v - the TX half of the AD9361 interface (1R1T).
//
// b200_io drives tx_data through ODDRs: I in the first half of each tx_clk
// period, Q in the second, with tx_frame high in the first half and low in
// the second and tx_clk reproducing the interface clock.  The AD9361 takes
// the two halves of one clock period as one sample.
//
// Stimulus.  I(n) = n and Q(n) = 3n + 1000 (mod 4096) on channel 0; the two
// have different slopes, so an I/Q swap, or a period carrying I and Q of
// different samples, mismatches on every sample (the earlier Q = I + 2048
// was its own mirror image mod 4096).  Channel 1 is driven with the
// complement of channel 0: it must never reach the pins in 1R1T.
//
// Checks, 2 ns after each clock edge (the ODDR outputs have settled):
//   * tx_data, tx_frame and tx_clk carry no X or Z,
//   * first half === I(k) and second half === Q(k) of the same k, with
//     k = n - L for one latency L found once by search in 0..LAT_MAX and
//     then held: every period carries the next sample, none repeated or
//     skipped,
//   * tx_frame is 1 then 0, tx_clk follows the interface clock.
// PASS needs that on at least NSAMP periods.
`timescale 1ns/1ps

module tb_tx_pins;

   localparam integer NSAMP   = 4000;
   localparam integer LAT_MAX = 8;

   reg rx_clk = 0;  always #8.138 rx_clk = ~rx_clk;
   reg refclk = 0;  always #2.5 refclk = ~refclk;
   reg areset = 1;
   reg mimo   = 0;

   wire radio_clk, radio_rst, idelay_rdy;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   reg [11:0] tx_i0 = 12'd0, tx_q0 = 12'd0;

   b200_io dut (
      .areset(areset), .idelay_refclk(refclk), .idelay_rst(areset),
      .idelay_rdy(idelay_rdy), .mimo(mimo),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(tx_i0), .tx_q0(tx_q0), .tx_i1(~tx_i0), .tx_q1(~tx_q0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(1'b0), .rx_data(12'd0),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   function [11:0] i_of(input integer k); i_of = k;            endfunction
   function [11:0] q_of(input integer k); q_of = 3 * k + 1000; endfunction

   // Negative controls (the Makefile runs each and requires FAIL):
   //   +NEG_SWAP  the radio hands Q on the I port and I on the Q port
   //   +NEG_X     one bit of the Q word undefined
   reg neg_swap = 0, neg_x = 0;
   initial begin
      neg_swap = $test$plusargs("NEG_SWAP");
      neg_x    = $test$plusargs("NEG_X");
   end

   // the radio: one sample per radio_clk (= interface clock in 1R1T)
   integer n = 0;
   always @(posedge rx_clk) begin
      tx_i0 <= neg_swap ? q_of(n) : i_of(n);
      tx_q0 <= neg_swap ? i_of(n) : q_of(n);
      if (neg_x) tx_q0[4] <= 1'bx;
      n     <= n + 1;
   end

   // ---- checks -----------------------------------------------------------
   integer checked = 0, locked = 0, latency = -1, l, e;
   integer mismatches = 0, xwords = 0, bad_clk = 0, bad_frame = 0, lockfail = 0, shown = 0;
   reg [11:0] i_val, q_val;
   reg        i_x;
   integer    n_i;

   always @(posedge rx_clk) if (!areset && n > 100) begin
      #2;                                   // let the ODDRs settle
      i_val = tx_data;
      n_i   = n;
      i_x   = (^tx_data === 1'bx);
      if (tx_clk   !== 1'b1) bad_clk   = bad_clk + 1;
      if (tx_frame !== 1'b1) bad_frame = bad_frame + 1;   // 1R1T: frame high in the first half
   end

   always @(negedge rx_clk) if (!areset && n > 101) begin
      #2;
      q_val = tx_data;
      if (tx_clk   !== 1'b0) bad_clk   = bad_clk + 1;
      if (tx_frame !== 1'b0) bad_frame = bad_frame + 1;   // and low in the second
      if (i_x || ^tx_data === 1'bx) begin
         xwords = xwords + 1;
         if (shown < 4) begin
            shown = shown + 1;
            $display("TX-PINS:   X/Z on the pins: first half %h, second half %h", i_val, q_val);
         end
      end else begin
         if (!locked) begin
            for (l = 0; l <= LAT_MAX && !locked; l = l + 1)
               if (i_val === i_of(n_i - l) && q_val === q_of(n_i - l)) begin
                  latency = l;
                  locked  = 1;
               end
            if (!locked) lockfail = lockfail + 1;
         end
         if (locked) begin
            checked = checked + 1;
            e = n_i - latency;
            if (i_val !== i_of(e) || q_val !== q_of(e)) begin
               mismatches = mismatches + 1;
               if (shown < 4) begin
                  shown = shown + 1;
                  $display("TX-PINS:   sample %0d: first half %0d, second half %0d, expected I=%0d Q=%0d",
                           e, i_val, q_val, i_of(e), q_of(e));
               end
            end
         end
      end
   end

   initial begin
      repeat (8) @(posedge rx_clk);
      areset <= 0;
      repeat (200) @(posedge rx_clk);
      repeat (NSAMP) @(posedge rx_clk);
      #4;
      $display("TX-PINS: latency %0d periods, %0d samples checked, %0d mismatches, %0d X words, %0d tx_clk errors, %0d frame errors, %0d periods before lock",
               latency, checked, mismatches, xwords, bad_clk, bad_frame, lockfail);
      if (locked && checked >= NSAMP && mismatches == 0 && xwords == 0 &&
          bad_clk == 0 && bad_frame == 0 && lockfail == 0)
         $display("TX-PINS: PASS - %0d consecutive samples, I in the first half, Q of the same sample in the second, frame and clock correct",
                  checked);
      else
         $display("TX-PINS: FAIL - pins do not carry the radio's samples (swapped, mixed, lost, repeated or undefined)");
      $finish;
   end

endmodule
