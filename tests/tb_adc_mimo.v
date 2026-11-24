// tb_adc_mimo.v - the dual-channel (2R2T) capture, in simulation.
//
// 1R1T is covered by tb_adc_pins.  In 2R2T the AD9361 alternates the two
// channels on the same DDR bus and marks channel 0 with RX_FRAME high;
// b200_io then runs radio_clk at rx_clk/2 and presents one {ch0, ch1} pair
// per radio_clk period.
//
// Stimulus.  Pair k puts four different known sequences on the bus:
//
//     ch0:  I = k            Q = 3k + 1000
//     ch1:  I = 5k + 2000    Q = 7k + 3000        (mod 4096)
//
// with RX_FRAME high for the channel-0 period and low for the channel-1
// period.  The four slopes differ, so no shift of k maps one sequence on
// another: a channel swap, an I/Q swap, or a pair made of two different k
// mismatches on every sample.
//
// Checks, on every rising edge of radio_clk (what the radio samples), for
// both phases the /2 divider can come up in:
//   * no bit of the four output words is X or Z,
//   * rx_i0, rx_q0 === ch0 I, Q of pair k and rx_i1, rx_q1 === ch1 I, Q of
//     the SAME pair k, with k = (pair on the pins) - L for one latency L
//     found once by search in 0..LAT_MAX pairs and then held, so every
//     radio_clk period delivers the next pair: none repeated, none skipped.
// PASS needs that on at least NPAIR pairs in each phase.
//
// What this cannot prove is the AD9361's own bus protocol; that needs the
// converter on a bench.  What it does prove is that the RTL delivers each
// channel on its own port once the protocol is as modelled.
`timescale 1ns/1ps

module adc_mimo_case #(
   parameter integer PHASE = 0,          // extra rx_clk periods before reset release
   parameter integer NPAIR = 10000
) (output reg done, output reg ok, output reg div_phase);

   localparam integer LAT_MAX = 8;       // pairs, pins -> outputs

   reg rx_clk = 0;
   always #8.138 rx_clk = ~rx_clk;      // 61.44 MHz DATA_CLK
   reg refclk = 0;
   always #2.5 refclk = ~refclk;        // 200 MHz IDELAYCTRL reference

   reg areset = 1;
   reg rx_frame = 0;
   reg [11:0] rx_data = 0;

   wire radio_clk, radio_rst, idelay_rdy;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   b200_io dut (
      .areset(areset), .idelay_refclk(refclk), .idelay_rst(areset),
      .idelay_rdy(idelay_rdy), .mimo(1'b1),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(12'd0), .tx_q0(12'd0), .tx_i1(12'd0), .tx_q1(12'd0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   function [11:0] i0_of(input integer k); i0_of = k;            endfunction
   function [11:0] q0_of(input integer k); q0_of = 3 * k + 1000; endfunction
   function [11:0] i1_of(input integer k); i1_of = 5 * k + 2000; endfunction
   function [11:0] q1_of(input integer k); q1_of = 7 * k + 3000; endfunction

   // Negative controls (the Makefile runs each and requires FAIL):
   //   +NEG_CHSWAP  the two channels exchanged on the bus (frame unchanged)
   //   +NEG_IQSWAP  Q in the first half of each period, I in the second
   //   +NEG_X       one data pin undriven
   reg neg_chswap = 0, neg_iqswap = 0, neg_x = 0;
   initial begin
      neg_chswap = $test$plusargs("NEG_CHSWAP");
      neg_iqswap = $test$plusargs("NEG_IQSWAP");
      neg_x      = $test$plusargs("NEG_X");
   end

   // ---- alternating DDR bus: tDDRX = 1 ns after each DATA_CLK edge --------
   integer k  = 0;                       // pair on the pins
   reg     ch = 0;                       // channel on the pins
   wire        dch = ch ^ neg_chswap;    // channel whose data is driven
   wire [11:0] di = dch ? i1_of(k) : i0_of(k);
   wire [11:0] dq = dch ? q1_of(k) : q0_of(k);
   always @(posedge rx_clk) begin
      #1 rx_data  <= neg_iqswap ? dq : di;       // first half
         rx_frame <= ~ch;                        // high = channel 0
      if (neg_x) rx_data[7] <= 1'bz;
   end
   always @(negedge rx_clk) begin
      #1 rx_data <= neg_iqswap ? di : dq;        // second half
      if (neg_x) rx_data[7] <= 1'bz;
   end
   always @(posedge rx_clk) begin                // next channel / next pair
      #0.5;
      if (ch) k <= k + 1;
      ch <= ~ch;
   end

   // ---- checks in the DSP clock domain ----------------------------------
   integer cycles = 0, checked = 0, locked = 0, latency = -1, l, e;
   integer mismatches = 0, xwords = 0, lockfail = 0, shown = 0;

   // which of the two bus periods radio_clk rises in (constant for a run)
   integer phase_flips = 0;
   always @(posedge radio_clk) begin
      if (!radio_rst && k > 100) begin
         if (cycles > 0 && ch !== div_phase) phase_flips = phase_flips + 1;
         div_phase = ch;
         cycles = cycles + 1;
         if (^{rx_i0, rx_q0, rx_i1, rx_q1} === 1'bx) begin
            xwords = xwords + 1;
            if (shown < 4) begin
               shown = shown + 1;
               $display("ADC-MIMO:   phase %0d: X/Z in output word %h %h %h %h",
                        PHASE, rx_i0, rx_q0, rx_i1, rx_q1);
            end
         end else begin
            if (!locked) begin
               for (l = 0; l <= LAT_MAX && !locked; l = l + 1)
                  if (rx_i0 === i0_of(k - l) && rx_q0 === q0_of(k - l)) begin
                     latency = l;
                     locked  = 1;
                  end
               if (!locked) lockfail = lockfail + 1;
            end
            if (locked) begin
               checked = checked + 1;
               e = k - latency;
               if (rx_i0 !== i0_of(e) || rx_q0 !== q0_of(e) ||
                   rx_i1 !== i1_of(e) || rx_q1 !== q1_of(e)) begin
                  mismatches = mismatches + 1;
                  if (shown < 4) begin
                     shown = shown + 1;
                     $display("ADC-MIMO:   phase %0d pair %0d: got A=(%0d,%0d) B=(%0d,%0d), expected A=(%0d,%0d) B=(%0d,%0d)",
                              PHASE, e, rx_i0, rx_q0, rx_i1, rx_q1,
                              i0_of(e), q0_of(e), i1_of(e), q1_of(e));
                  end
               end
            end
         end
      end
   end

   initial begin
      done = 0; ok = 0; div_phase = 1'bx;
      repeat (8 + PHASE) @(posedge rx_clk);
      areset <= 0;
      repeat (300) @(posedge rx_clk);
      repeat (2 * NPAIR) @(posedge rx_clk);
      $display("ADC-MIMO: divider phase %0d: %0d radio_clk periods, latency %0d pairs, %0d pairs checked, %0d mismatches, %0d X words, %0d words before lock",
               PHASE, cycles, latency, checked, mismatches, xwords, lockfail);
      ok   = (locked && checked >= NPAIR && mismatches == 0 && xwords == 0 &&
              lockfail == 0 && phase_flips == 0 && idelay_rdy === 1'b1);
      done = 1;
   end

endmodule

module tb_adc_mimo;

   localparam integer NPAIR = 10000;

   wire done0, ok0, ph0, done1, ok1, ph1;
   adc_mimo_case #(.PHASE(0), .NPAIR(NPAIR)) p0 (.done(done0), .ok(ok0), .div_phase(ph0));
   adc_mimo_case #(.PHASE(1), .NPAIR(NPAIR)) p1 (.done(done1), .ok(ok1), .div_phase(ph1));

   initial begin
      wait (done0 === 1'b1 && done1 === 1'b1);
      // the two cases must really be the two divider phases
      if ((ph0 ^ ph1) !== 1'b1)
         $display("ADC-MIMO: FAIL - the two cases did not exercise both divider phases (%b, %b)", ph0, ph1);
      else if (ok0 === 1'b1 && ok1 === 1'b1)
         $display("ADC-MIMO: PASS - each channel on its own port, I and Q in place, pairs whole and in order, both divider phases");
      else
         $display("ADC-MIMO: FAIL - channels swapped, mixed, lost, repeated or undefined");
      $finish;
   end

endmodule
