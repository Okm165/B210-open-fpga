// tb_adc_mimo.v - the dual-channel capture premise, in simulation.
//
// SISO is covered by tb_adc_pins (one 12-bit DDR bus duplicated to both
// channels).  In MIMO the AD9361 alternates the two channels on the same bus
// and marks channel 0 with RX_FRAME; b200_io then runs radio_clk at rx_clk/2
// and updates channel A on framed periods and channel B on the others.
//
// This bench drives that shape of bus with an index encoded in the samples
// (I = m, Q = m+2048, m incrementing once per rx_clk period, frame high on
// even m) and checks the invariants that make the dual-channel claim true:
//
//   * channel A and channel B never carry the same sample (they are two
//     independent streams, which is the whole purpose of MIMO),
//   * their indices are always consecutive, so no sample is dropped,
//   * each channel's index advances by exactly 2 per radio_clk period (one
//     capture per channel per DSP cycle, no double capture, no skip),
//   * channel parity is stable (A always the framed channel).
//
// What this cannot prove is the AD9361's own bus protocol; that needs the
// converter on a bench.  What it does prove is that the RTL consumes the
// alternating bus correctly once the protocol is as modelled.
`timescale 1ns/1ps

module tb_adc_mimo;

   localparam integer NSAMP = 20000;

   reg rx_clk = 0;
   always #8.138 rx_clk = ~rx_clk;      // 61.44 MHz DATA_CLK

   reg areset = 1;
   reg mimo   = 1;                      // configuration-time: must not change
   reg rx_frame = 0;
   reg [11:0] rx_data = 0;

   wire radio_clk, radio_rst;
   wire [11:0] rx_i0, rx_q0, rx_i1, rx_q1;
   wire rx_stb, tx_stb;
   wire tx_clk, tx_frame;
   wire [11:0] tx_data;

   b200_io dut (
      .areset(areset), .mimo(mimo),
      .radio_clk(radio_clk), .radio_rst(radio_rst),
      .rx_i0(rx_i0), .rx_q0(rx_q0), .rx_i1(rx_i1), .rx_q1(rx_q1),
      .rx_stb(rx_stb),
      .tx_i0(12'd0), .tx_q0(12'd0), .tx_i1(12'd0), .tx_q1(12'd0),
      .tx_stb(tx_stb),
      .rx_clk(rx_clk), .rx_frame(rx_frame), .rx_data(rx_data),
      .tx_clk(tx_clk), .tx_frame(tx_frame), .tx_data(tx_data));

   // ---- alternating DDR bus: m increments once per period, frame on even m
   integer n = 0;
   always @(posedge rx_clk) begin
      #1 rx_data  <= n[11:0];            // I(m), first half
      #0 ; // keep the frame change after the edge as well
   end
   always @(negedge rx_clk) begin
      #1 rx_data <= (n + 2048) & 4095;   // Q(m), second half
      #1 rx_frame <= ~n[0];              // framed period = channel 0
      n <= n + 1;
   end

   // ---- checks in the DSP clock domain ----------------------------------
   integer cycles = 0, checks = 0, errors = 0;
   integer d_ab, a_par, b_par, parity = -1;
   integer last_a = -1;
   integer step_ok = 0, step_bad = 0;

   always @(negedge radio_clk) begin
      if (!radio_rst && n > 100) begin
         checks = checks + 1;
         d_ab  = (rx_i1 - rx_i0) & 4095;
         a_par = rx_i0 & 1;
         b_par = rx_i1 & 1;
         // consecutive samples, not the same one
         if (d_ab != 1 && d_ab != 4095) begin
            errors = errors + 1;
            if (errors < 5)
               $display("ADC-MIMO: FAIL A=%0d B=%0d are not consecutive", rx_i0, rx_i1);
         end
         if (rx_i0 === rx_i1) begin
            errors = errors + 1;
            if (errors < 5)
               $display("ADC-MIMO: FAIL both channels carry sample %0d", rx_i0);
         end
         // channel parity stable
         if (parity < 0) parity = a_par;
         else if (a_par != parity || b_par == parity) begin
            errors = errors + 1;
            if (errors < 5)
               $display("ADC-MIMO: FAIL parity A=%0d B=%0d (expected A=%0d)",
                        a_par, b_par, parity);
         end
         // one capture per channel per DSP cycle: A advances by 2
         if (last_a >= 0) begin
            if (((rx_i0 - last_a) & 4095) == 2) step_ok = step_ok + 1;
            else step_bad = step_bad + 1;
         end
         last_a = rx_i0;
      end
   end

   initial begin
      repeat (8) @(posedge rx_clk);
      areset <= 0;
      repeat (100) @(posedge rx_clk);
      repeat (NSAMP) @(posedge rx_clk);
      $display("ADC-MIMO: %0d checks, A advances by 2 on %0d cycles (%0d bad), parity %0d",
               checks, step_ok, step_bad, parity);
      if (errors == 0 && step_bad == 0)
         $display("ADC-MIMO: PASS - two independent, consecutive, half-rate channels");
      else
         $display("ADC-MIMO: FAIL - %0d errors, %0d bad steps", errors, step_bad);
      $finish;
   end

endmodule
