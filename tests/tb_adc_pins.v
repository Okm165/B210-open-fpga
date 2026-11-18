// tb_adc_pins.v - the last unmodelled interface: the AD9361 DDR pins.
//
// Models the AD9361 CMOS DDR receive bus the way UG-570 specifies it: data
// transitions tDDRX (0.25-1.25 ns) AFTER each edge of DATA_CLK, not at the
// edge.  Within sample period n the bus carries I(n) in the first half
// (driven after the rising edge) and Q(n) in the second half (driven after
// the falling edge).  b200_io must reassemble I(n) and Q(n) as one pair.
//
// Invariant: after a constant capture latency L, every strobe must deliver
// (rx_i0, rx_q0) = (I(k), Q(k)) for one and the same k.  I and Q are driven
// with different, monotonic values, so a capture that mixes sample periods
// (for example an IDDR model whose Q2 is a delayed copy of Q1, or an IDDR
// whose separated-pair semantics are wrong for this bus phase) is detected
// as rx_i0 and rx_q0 disagreeing about k.
`timescale 1ns/1ps

module tb_adc_pins;

   localparam integer NSAMP = 4096;

   reg rx_clk = 0;
   always #8.138 rx_clk = ~rx_clk;      // 61.44 MHz DATA_CLK

   reg areset = 1;
   reg mimo   = 0;                       // SISO: both channels carry the pair
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

   // ---------------- AD9361 DDR pin model --------------------------------
   // Sample n: I = n[11:0] in the first half, Q = (n+2048)&0xfff in the
   // second half.  Data transitions 1 ns after each clock edge, per tDDRX.
   integer n = 0;
   always @(posedge rx_clk) begin #1 rx_data <= n[11:0];        end  // I(n)
   always @(negedge rx_clk) begin #1 rx_data <= (n+2048)&4095;
                                  n <= n + 1;                   end  // Q(n)

   // ---------------- measurement -----------------------------------------
   // Track the expected sample index at each strobe: the capture latency is
   // unknown a priori, so lock onto it once and then require exact tracking.
   integer strobes = 0, locked = 0, latency = -1;
   integer mismatches = 0, bad_i = 0, bad_q = 0;

   always @(posedge radio_clk) begin
      if (!radio_rst && rx_stb) begin
         strobes = strobes + 1;
         if (!locked && n > 100) begin
            latency = n - ((rx_q0 - 2048) & 4095);   // Q carries (k+2048)&0xfff
            locked  = 1;
         end
         if (locked) begin
            if (rx_i0 !== ((n - latency) & 4095)) begin
               mismatches = mismatches + 1;
               if (bad_i < 3) begin
                  $display("ADC-PINS:   I mismatch: got %0d expected %0d (Q says %0d)",
                           rx_i0, (n-latency)&4095, (rx_q0-2048)&4095);
                  bad_i = bad_i + 1;
               end
            end
            if (rx_q0 !== ((n - latency + 2048) & 4095)) begin
               mismatches = mismatches + 1;
               if (bad_q < 3) begin
                  $display("ADC-PINS:   Q mismatch: got %0d expected %0d",
                           rx_q0, (n-latency+2048)&4095);
                  bad_q = bad_q + 1;
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
      $display("ADC-PINS: %0d strobes, locked at latency %0d, %0d mismatches",
               strobes, latency, mismatches);
      if (mismatches == 0)
        $display("ADC-PINS: PASS - every I/Q pair belongs to one sample period");
      else
        $display("ADC-PINS: FAIL - capture mixes sample periods");
      $finish;
   end

endmodule
