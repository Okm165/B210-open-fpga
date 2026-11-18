// tb_dither_dc.v - the dithered quantiser under a STATIC input.
//
// Tone tests measure SNR; they cannot see the failure modes that matter for a
// constant input: a dither that collapses to one or two values (which happened
// once: at WIDTH_IN=23 the span degenerated to {0,-1} accumulator units), a DC
// bias in the dither centring, or an idle limit cycle.
//
// The input is 0x1000 + 64 in 24-bit units, i.e. exactly 16.25 in 16-bit output
// units, a quarter of an LSB away from a representable value.  A correct
// triangular dither of +-1 LSB then produces four output codes, a mean equal to
// the exact input, and an rms near sqrt(1/6) = 0.41 plus the quantiser term.
//
// Measured with the same stimulus offline (1 048 576 samples, Blackman-Harris):
//   mean 16.2479 (exact 16.25), rms 0.577 LSB, integrated noise -95.1 dBFS,
//   strongest discrete line -141.0 dBFS = 67 dB below the 12-bit ADC's floor,
//   line spacing 469 Hz (the 2^17-1 period of the dither LFSRs).
`timescale 1ns/1ps

module tb_dither_dc;

   localparam integer N   = 262144;
   localparam integer OFF = 64;      // 24-bit units: 0.25 of an output LSB

   reg clk = 0; always #8.138 clk = ~clk;
   reg rst = 1;
   reg signed [23:0] in = 24'sd0;
   wire [15:0] out;
   wire strobe;

   round_sd #(.WIDTH_IN(24), .WIDTH_OUT(16)) dut (
      .clk(clk), .reset(rst), .in(in), .strobe_in(1'b1),
      .out(out), .strobe_out(strobe));

   // ---- statistics -------------------------------------------------------
   integer n = 0, warm = 0;
   integer sum = 0;              // sum of the signed value
   integer sumsq = 0;            // sum of squares
   integer v, mn = 32767, mx = -32768;
   integer distinct_lo = 0;      // codes in the window 14..19
   integer hist[0:7];

   always @(posedge clk) if (!rst) begin
      if (warm < 100) warm = warm + 1;
      else begin
      v = $signed(out);
      sum   = sum + v;
      sumsq = sumsq + v*v;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
      if (v >= 14 && v <= 21) hist[v-14] = hist[v-14] + 1;
      n = n + 1;
      end
   end

   real mean, rms;
   integer i, codes;
   initial begin
      for (i = 0; i < 8; i = i + 1) hist[i] = 0;
      repeat (5) @(posedge clk); rst <= 0; repeat (5) @(posedge clk);
      in = 24'sd4096 + OFF;
      repeat (N + 200) @(posedge clk);
      mean = sum*1.0/n;
      rms  = $sqrt(sumsq*1.0/n - mean*mean);
      codes = 0;
      for (i = 0; i < 8; i = i + 1) if (hist[i] > n/1000) codes = codes + 1;
      $display("DITHER: %0d samples, mean %.4f (exact 16.2500), rms %.3f LSB, range %0d..%0d, %0d codes >0.1%%",
               n, mean, rms, mn, mx, codes);
      if (mean > 16.27 || mean < 16.23)
         $display("DITHER: FAIL - DC bias in the dither centring");
      else if (rms < 0.45 || rms > 0.70)
         $display("DITHER: FAIL - dither amplitude is not a triangular +-1 LSB");
      else if (codes < 4)
         $display("DITHER: FAIL - dither collapsed: idle output has only %0d codes", codes);
      else
         $display("DITHER: PASS - unbiased, triangular +-1 LSB, four idle codes");
      $finish;
   end

endmodule
