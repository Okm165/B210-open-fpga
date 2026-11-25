// tb_adc_pins.v - the AD9361 DDR receive pins, one channel (1R1T).
//
// Models the AD9361 CMOS DDR receive bus the way UG-570 specifies it: data
// transitions tDDRX (0.25-1.25 ns) AFTER each edge of DATA_CLK, not at the
// edge.  Within sample period n the bus carries I(n) in the first half
// (driven after the rising edge) and Q(n) in the second half (driven after
// the falling edge).  b200_io must reassemble I(n) and Q(n) as one pair.
//
// Stimulus.  I(n) = n and Q(n) = 3n + 1000 (mod 4096).  The two sequences
// have different slopes, so no shift of the sample index turns one into the
// other: a capture that swaps I and Q, or pairs I and Q of different sample
// periods, mismatches on every sample (the earlier Q = I + 2048 was its own
// mirror image mod 4096 and let a swap pass as "sample n + 2048").
//
// Checks, on every radio_clk edge the radio would use (rx_stb high):
//   * no bit of the four output words is X or Z,
//   * (rx_i0, rx_q0) === (I(k), Q(k)) for k = n - L, with one capture latency
//     L found once by search in 0..LAT_MAX periods and then held: every
//     later sample must be the next one, none repeated, none skipped,
//   * channel 1 carries the same pair (1R1T duplicates the bus),
//   * rx_stb is high on every radio_clk edge once it has risen.
// PASS needs all of that on at least NSAMP samples; a bench that saw no
// strobe, or never found the latency, fails.
`timescale 1ns/1ps

module tb_adc_pins;

   localparam integer NSAMP   = 4096;
   localparam integer LAT_MAX = 8;       // sample periods, pins -> rx_i0/rx_q0

   reg rx_clk = 0;
   always #8.138 rx_clk = ~rx_clk;      // 61.44 MHz DATA_CLK
   reg refclk = 0;
   always #2.5 refclk = ~refclk;        // 200 MHz IDELAYCTRL reference

   reg areset = 1;
   reg mimo   = 0;                       // 1R1T: both channels carry the pair
   reg rx_frame = 0;
   reg [11:0] rx_data = 0;

   wire radio_clk, radio_rst, idelay_rdy;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   b200_io dut (
      .areset(areset), .idelay_refclk(refclk), .idelay_rst(areset),
      .idelay_rdy(idelay_rdy), .mimo(mimo),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(12'd0), .tx_q0(12'd0), .tx_i1(12'd0), .tx_q1(12'd0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   // ---------------- AD9361 DDR pin model --------------------------------
   function [11:0] i_of(input integer k); i_of = k;              endfunction
   function [11:0] q_of(input integer k); q_of = 3 * k + 1000;   endfunction

   // Negative controls (the justfile runs each and requires FAIL):
   //   +NEG_SWAP  Q in the first half of the period, I in the second
   //   +NEG_DROP  the converter skips one sample period in mid-run
   //   +NEG_X     one data pin undriven
   reg neg_swap = 0, neg_drop = 0, neg_x = 0;
   initial begin
      neg_swap = $test$plusargs("NEG_SWAP");
      neg_drop = $test$plusargs("NEG_DROP");
      neg_x    = $test$plusargs("NEG_X");
   end

   integer n = 0;                        // sample period on the pins
   wire [31:0] m = n + ((neg_drop && n >= 2000) ? 1 : 0);
   wire [11:0] first_half  = neg_swap ? q_of(m) : i_of(m);
   wire [11:0] second_half = neg_swap ? i_of(m) : q_of(m);
   always @(posedge rx_clk) begin #1 rx_data <= first_half;        // I(n)
                                  if (neg_x) rx_data[5] <= 1'bz;    end
   always @(negedge rx_clk) begin #1 rx_data <= second_half;       // Q(n)
                                  if (neg_x) rx_data[5] <= 1'bz;
                                  n <= n + 1;                       end

   // ---------------- measurement -----------------------------------------
   integer strobes = 0, checked = 0, locked = 0, latency = -1, l;
   integer mismatches = 0, xwords = 0, gaps = 0, lockfail = 0, shown = 0;
   reg     stb_seen = 0;

   always @(posedge radio_clk) begin
      if (!radio_rst) begin
         if (rx_stb === 1'b1) stb_seen = 1;
         else if (stb_seen) gaps = gaps + 1;       // 1R1T: a sample every clock
      end
      if (!radio_rst && rx_stb === 1'b1) begin
         strobes = strobes + 1;
         if (n > 100) begin
            if (^{rx_i0, rx_q0, rx_i1, rx_q1} === 1'bx) begin
               xwords = xwords + 1;
               if (shown < 6) begin
                  shown = shown + 1;
                  $display("ADC-PINS:   X/Z in output word %h %h %h %h",
                           rx_i0, rx_q0, rx_i1, rx_q1);
               end
            end else begin
               if (!locked) begin
                  for (l = 0; l <= LAT_MAX && !locked; l = l + 1)
                     if (rx_i0 === i_of(n - l) && rx_q0 === q_of(n - l)) begin
                        latency = l;
                        locked  = 1;
                     end
                  if (!locked) lockfail = lockfail + 1;
               end
               if (locked) begin
                  checked = checked + 1;
                  if (rx_i0 !== i_of(n - latency) || rx_q0 !== q_of(n - latency) ||
                      rx_i1 !== i_of(n - latency) || rx_q1 !== q_of(n - latency)) begin
                     mismatches = mismatches + 1;
                     if (shown < 6) begin
                        shown = shown + 1;
                        $display("ADC-PINS:   sample %0d: got I0=%0d Q0=%0d I1=%0d Q1=%0d, expected I=%0d Q=%0d",
                                 n - latency, rx_i0, rx_q0, rx_i1, rx_q1,
                                 i_of(n - latency), q_of(n - latency));
                     end
                  end
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
      $display("ADC-PINS: %0d strobes, latency %0d periods, %0d samples checked, %0d mismatches, %0d X words, %0d strobe gaps, %0d words before lock",
               strobes, latency, checked, mismatches, xwords, gaps, lockfail);
      if (locked && checked >= NSAMP && mismatches == 0 && xwords == 0 &&
          gaps == 0 && lockfail == 0 && idelay_rdy === 1'b1)
        $display("ADC-PINS: PASS - %0d consecutive samples, I and Q of one period, in order, on both channels",
                 checked);
      else
        $display("ADC-PINS: FAIL - capture wrong (swapped, mixed, lost, repeated or undefined samples)");
      $finish;
   end

endmodule
