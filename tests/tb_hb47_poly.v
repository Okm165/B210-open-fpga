// tb_hb47_poly - regression guard for the transmit halfband.
//
// hb47_int's defect class: at a slow input strobe its polyphase selection went
// stale, it computed one filter half only, and the interpolation image was
// reinforced instead of cancelled (-22.9 dBc at the DAC pins).  hb47_poly
// computes both phases explicitly; this bench pins the properties that make
// that true, in the exact strobe regime the DUC uses (stb_in every 4 clocks,
// stb_out every 2):
//
//   1. impulse response: centre tap at the impulse, taps on ODD offsets from
//      the centre with the designed values, zeros on even offsets.  Any phase
//      misalignment or coefficient-order error moves taps onto even offsets
//      or changes their values, and the measured DAC image follows.
//   2. image gain: |H(fs/2)| below -60 dB relative to H(0) (the alternating
//      sum of the captured response; the defective module measured -12 dB).
//   3. DC gain: 2.0 across both phases, i.e. unity for the interpolated
//      stream (matches the level convention of the removed hb47_int).
//   4. DC: both output phases within 2 LSB of the input (no fs/2 ripple).
`timescale 1ns/1ps

module tb_hb47_poly;

   reg clk = 0, rst = 1, stb_in = 0, stb_out = 0;
   always #5 clk = ~clk;

   reg signed [17:0] din = 0;
   wire signed [17:0] dout;

   hb47_poly #(.WIDTH(18)) dut
     (.clk(clk), .rst(rst), .bypass(1'b0), .stb_in(stb_in),
      .data_in(din), .stb_out(stb_out), .data_out(dout));

   // strobe pattern: phase 0 = stb_in & stb_out, phase 2 = stb_out only
   reg [1:0] ph = 0;
   always @(posedge clk) begin
      ph      <= (ph == 3) ? 2'd0 : ph + 2'd1;
      stb_out <= (ph % 2 == 0);
      stb_in  <= (ph == 0);
   end

   // designed taps, centre outward (Q17): +-1, +-3, ... +-23
   integer tap [0:11];
   initial begin
      tap[0]  =  41508;  tap[1]  = -13273; tap[2]  =   7322;
      tap[3]  =  -4600;  tap[4]  =   3002; tap[5]  =  -1956;
      tap[6]  =   1243;  tap[7]  =   -755; tap[8]  =    428;
      tap[9]  =   -218;  tap[10] =     93; tap[11] =    -27;
   end

   integer ir [0:127];
   integer i, n_in, idx, centre, sum_h, sum_nyq, worst, bad;
   integer dc_lo, dc_hi;

   task pulse_rst;
      begin
         rst <= 1'b1; din <= 0;
         repeat (6) @(posedge clk);
         rst <= 1'b0;
         repeat (6) @(posedge clk);
      end
   endtask

   initial begin
      // ---- 1..3: impulse response ----
      pulse_rst;
      n_in = 0; idx = 0;
      for (i = 0; i < 128*4 + 8; i = i + 1) begin
         @(posedge clk);
         if (stb_in) begin
            din <= (n_in == 20) ? 18'sd65536 : 18'sd0;
            n_in = n_in + 1;
         end
         @(negedge clk);
         if (stb_out && idx < 128) begin
            ir[idx] = dout;
            idx = idx + 1;
         end
      end

      centre = 0;
      for (i = 1; i < 128; i = i + 1)
        if (ir[i] > ir[centre]) centre = i;
      if (ir[centre] < 65500) begin
         $display("FAIL: centre tap %0d, expected ~65536", ir[centre]);
         $finish;
      end

      bad = 0;
      // even offsets from the centre must be zero (halfband condition)
      for (i = 2; i <= 24; i = i + 2) begin
         if (centre+i < 128 && ir[centre+i] > 4)  bad = bad + 1;
         if (centre-i >= 0   && ir[centre-i] > 4) bad = bad + 1;
         if (centre-i >= 0   && ir[centre-i] < -4) bad = bad + 1;
         if (centre+i < 128 && ir[centre+i] < -4) bad = bad + 1;
      end
      if (bad != 0) begin
         $display("FAIL: %0d nonzero samples on even offsets from the centre - taps are not on the interpolating phase", bad);
         $finish;
      end
      // odd offsets carry the designed coefficients
      for (i = 1; i <= 23; i = i + 2) begin
         if (centre-i >= 0 && (ir[centre-i] > tap[(i-1)/2]+4 || ir[centre-i] < tap[(i-1)/2]-4)) begin
            $display("FAIL: tap at -%0d is %0d, expected %0d", i, ir[centre-i], tap[(i-1)/2]);
            $finish;
         end
         if (centre+i < 128 && (ir[centre+i] > tap[(i-1)/2]+4 || ir[centre+i] < tap[(i-1)/2]-4)) begin
            $display("FAIL: tap at +%0d is %0d, expected %0d", i, ir[centre+i], tap[(i-1)/2]);
            $finish;
         end
      end

      sum_h = 0; sum_nyq = 0;
      for (i = 0; i < 128; i = i + 1) begin
         sum_h   = sum_h   + ir[i];
         sum_nyq = sum_nyq + (i[0] ? -ir[i] : ir[i]);
      end
      // H(0) = 2.0 (unity for the interpolated stream)
      if (sum_h < 2*65536 - 300 || sum_h > 2*65536 + 300) begin
         $display("FAIL: DC gain %.4f, expected 2.0", $itor(sum_h)/65536.0);
         $finish;
      end
      // |H(fs/2)| < 0.001 * H(0)  (-60 dB; the defective module measured -12 dB)
      if ((sum_nyq > 0 ? sum_nyq : -sum_nyq) * 1000 > sum_h) begin
         $display("FAIL: image gain %.1f dB (sum %0d vs %0d), expected below -60 dB",
                  20.0*$ln(($itor(sum_nyq > 0 ? sum_nyq : -sum_nyq)+1.0)/$itor(sum_h))/$ln(10.0),
                  sum_nyq, sum_h);
         $finish;
      end
      $display("  HB: centre %0d, H(0) %.4f, H(fs/2) %0d (%.1f dB)",
               ir[centre], $itor(sum_h)/65536.0, sum_nyq,
               20.0*$ln(($itor(sum_nyq > 0 ? sum_nyq : -sum_nyq)+1.0)/$itor(sum_h))/$ln(10.0));

      // ---- 4: DC, both phases ----
      pulse_rst;
      n_in = 0; idx = 0; dc_lo = 99999; dc_hi = -99999;
      for (i = 0; i < 512*4 + 8; i = i + 1) begin
         @(posedge clk);
         if (stb_in) begin
            din <= 18'sd4096;
            n_in = n_in + 1;
         end
         @(negedge clk);
         if (stb_out && idx > 64) begin   // skip the filter's fill-in
            if (dout < dc_lo) dc_lo = dout;
            if (dout > dc_hi) dc_hi = dout;
            idx = idx + 1;
         end else if (stb_out) idx = idx + 1;
      end
      if (dc_lo < 4096-2 || dc_hi > 4096+2) begin
         $display("FAIL: DC output spans %0d..%0d for input 4096 (phases not aligned or gain wrong)", dc_lo, dc_hi);
         $finish;
      end
      $display("  HB: DC in 4096 -> out %0d..%0d", dc_lo, dc_hi);

      $display("PASS: hb47_poly taps, phase alignment, image gain and DC verified");
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
