// tb_tx_dc.v - TX DC gain from the host word to the 24-bit pin word, per rate.
//
// The RX side has an exhaustive static curve (tb_rx_codes); this is its TX
// mirror.  A constant host sample runs through a real duc_chain with the LO
// at DC, so every stage is a pure gain and the measurement needs no tone, no
// window and no spectral interpretation.
//
// It locks three facts:
//   * with the scale UHD's tx_dsp_core_3000 writes for each rate, the gain is
//     0.99925 at every rate, less 0.00006 per enabled halfband.  The first
//     number is the CORDIC's 1.64676 against the 1.648 in UHD's formula, the
//     second the halfband's coefficient sum; the CIC's shift normalisation
//     (R^3 / 2^ceil_log2(R^3), e.g. 0.84375 at CIC rate 3) is cancelled by
//     the same scale word, so it never shows at the pins;
//   * the scale word is linear, monotonic and saturates at the 24-bit rail;
//   * a complex sample with |I| = |Q| = full scale, rotated by the CORDIC,
//     saturates and never wraps (see the guard bit in duc_chain.v).
`timescale 1ns/1ps

module tb_tx_dc;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;
   reg [31:0] sample = 32'h3E80_0000;       // I = 16000, Q = 0
   reg        run = 0;

   wire [23:0] tx_fe_i, tx_fe_q;
   wire        strobe;
   wire [31:0] debug;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_fe_i), .tx_fe_q(tx_fe_q),
      .sample(sample), .run(run), .strobe(strobe), .debug(debug));

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clk); set_stb = 0;
      end
   endtask

   integer cfg, k, rate, settle, sum, total, errors;
   integer sc, xi, out24, expect, nbad, tol, prev_out, direction;
   reg [17:0] scale;
   reg [7:0] hb;
   real gain, exp_gain, rate_pow;
   integer uhd_scale;

   // The CORDIC as the chain uses it: algorithmic gain 1.646760258, halved.
   localparam real K_CORDIC = 0.823380129;
   // One halfband interpolator at DC: the centre phase passes the sample, the
   // filtered phase has a coefficient sum of 2 * 65528 / 2^17, so the mean of
   // the two output phases is 0.999939 (and the difference between them is
   // the -84 dBc line the filter leaves at half its output rate).
   localparam real HB_DC = 0.99993896;

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      wr(8'd0, 32'd0);                      // LO at DC

      for (cfg = 0; cfg < 9; cfg = cfg + 1) begin
         case (cfg)
           0: begin hb = 2'b00; rate = 1; end
           1: begin hb = 2'b01; rate = 1; end
           2: begin hb = 2'b01; rate = 3; end
           3: begin hb = 2'b11; rate = 1; end
           4: begin hb = 2'b11; rate = 2; end
           5: begin hb = 2'b11; rate = 3; end
           6: begin hb = 2'b11; rate = 4; end
           7: begin hb = 2'b11; rate = 5; end
           8: begin hb = 2'b11; rate = 8; end
         endcase
         // tx_dsp_core_3000::set_host_rate / update_scalar
         rate_pow  = $pow(1.0 * rate, 3);
         uhd_scale = $rtoi(65536.0 * $pow(2.0, $ceil($ln(rate_pow) / $ln(2.0))) / (1.648 * rate_pow) + 0.5);
         exp_gain  = 2.0 * K_CORDIC / 1.648;        // 0.99925
         if (hb[0]) exp_gain = exp_gain * HB_DC;
         if (hb[1]) exp_gain = exp_gain * HB_DC;
         wr(8'd1, uhd_scale);
         total = rate * (hb[0] + 1) * (hb[1] + 1);
         wr(8'd2, {hb, 8'd0} | rate);
         run = 1'b1;
         settle = 512 * rate + 512;
         repeat (settle) @(posedge clk);
         sum = 0;
         for (k = 0; k < 256; k = k + 1) begin
            @(posedge clk); #1;
            sum = sum + $signed(tx_fe_i);
         end
         gain = (sum / 256.0) / 4096000.0;  // 16000 * 256 = unity
         $display("TX-DC: halfbands %0d%0d CIC %0d total %2d scale %0d gain %.5f (%.4f dB)",
                  hb[1], hb[0], rate, total, uhd_scale, gain, 20.0*$log10(gain));
         if (gain > exp_gain + 5e-5 || gain < exp_gain - 5e-5) begin
            errors = errors + 1;
            $display("TX-DC: FAIL at total %0d: %.5f, expected %.5f",
                     total, gain, exp_gain);
         end
         run = 1'b0;
         repeat (64) @(posedge clk);
      end

      // ---- 2. scale: gain convention and saturation, no wrap ----
      // out24 = in16 * K * scale >> 7, saturating, K the CORDIC's 0.82338.
      // Total rate 1 (bypass) isolates the scale multiply.
      wr(8'd2, 32'h0000_0001);
      run = 1'b1;
      for (sc = 0; sc < 6; sc = sc + 1) begin
         nbad = 0; prev_out = 0; direction = 1;
         case (sc)
           0: scale = 18'h04000;   // a quarter of unity-before-the-CORDIC
           1: scale = 18'h08000;   // unity before the CORDIC: 0.82338 overall
           2: scale = 18'd39767;   // what UHD writes: 0.99925 overall
           3: scale = 18'h10000;   // 1.65: overdrive, must clip
           4: scale = 18'h1FFFF;   // 3.3: overdrive, must clip
           5: scale = 18'h00001;   // 1/32768
         endcase
         wr(8'd1, {14'd0, scale});
         for (xi = 0; xi < 7; xi = xi + 1) begin
            case (xi)
              // strictly increasing input order, so monotonicity is checkable
              0: sample = -32'sd32768 << 16;
              1: sample = -32'sd1000 << 16;
              2: sample = -32'sd1 << 16;
              3: sample = 32'sd0;
              4: sample = 32'sd1 << 16;
              5: sample = 32'sd1000 << 16;
              6: sample = 32'sd32767 << 16;
            endcase
            repeat (400) @(posedge clk);
            out24 = $signed(tx_fe_i);
            // real arithmetic: in*scale can exceed 32 bits (32768 * 131071)
            expect = $rtoi($floor(($itor($signed(sample[31:16])) * K_CORDIC * $itor(scale)) / 128.0));
            if (expect > 8388607) expect = 8388607;
            if (expect < -8388608) expect = -8388608;
            // The CORDIC output is truncated to 18 bits before the scale
            // multiply: up to one of those LSBs, i.e. scale/512 pin LSBs, plus
            // the CORDIC's own truncation.  A wrap or a broken scale would be
            // orders of magnitude larger.
            tol = 8 + ((expect < 0) ? (-expect) : expect) / 4096 + scale / 256;
            if (out24 > expect + tol || out24 < expect - tol) begin
               nbad = nbad + 1;
               if (nbad < 6)
                  $display("TX-DC: FAIL scale 0x%05X in %0d: out %0d, expected %0d +- %0d",
                           scale, $signed(sample[31:16]), out24, expect, tol);
            end
            // monotonic in the input for every scale: the wrap signature would
            // be a sign inversion at one of the rails
            if (xi > 0 && direction * out24 < direction * prev_out) begin
               nbad = nbad + 1;
               if (nbad < 6)
                  $display("TX-DC: FAIL scale 0x%05X: not monotonic at input %0d",
                           scale, $signed(sample[31:16]));
            end
            prev_out = out24;
         end
         $display("TX-DC: scale 0x%05X: %0d of 7 inputs wrong", scale, nbad);
      end
      if (nbad != 0) errors = errors + 1;

      // ---- 3. complex corner: the mixer must saturate, never wrap --------
      // A host complex sample with |I| = |Q| = full scale has magnitude 1.41,
      // so rotation by 45 degrees asks the CORDIC for 1.41 x 0.82338 = 1.16
      // of its output range.  The upstream CORDIC has no room for that and
      // changes sign; this chain gives it a guard bit and clips.  Per-axis
      // clipping is the correct behaviour, and the reference below applies
      // exactly the two clips of the RTL (CORDIC output, then the scaled pin
      // word).  The pipeline delay is unknown but it is a whole number of
      // clocks, and the LO advances 45 degrees per clock, so the output phase
      // is the input phase plus 45 deg x (an integer): the bench tries all 8
      // phases and requires one that matches everywhere.
      wr(8'd0, 32'h2000_0000);              // LO at fs/8 = 45 deg/sample
      wr(8'd1, 32'd39767);                  // the scale UHD writes
      wr(8'd2, 32'h0000_0001);              // bypass
      run = 1'b1;
      sample[31:16] = 32767; sample[15:0] = 32767;
      repeat (400) @(posedge clk);
      begin : corner
         integer n, o, off, best_off, best_bad, bad;
         integer oi [0:511];
         integer oq [0:511];
         real ai, aq, ph;
         integer ri, rq, e24i, e24q;
         for (n = 0; n < 512; n = n + 1) begin
            @(posedge clk); #1;
            oi[n] = $signed(tx_fe_i);
            oq[n] = $signed(tx_fe_q);
         end
         best_bad = 1000000; best_off = -1;
         for (off = 0; off < 8; off = off + 1) begin
            bad = 0;
            for (n = 64; n < 512; n = n + 1) begin
               ph = 2.0*3.14159265358979*(((n + off) % 8) * 128)/1024.0;
               ai = 46340.0 * 4.0 * K_CORDIC * $cos(ph);      // |x| = sqrt(2)*32767
               aq = 46340.0 * 4.0 * K_CORDIC * $sin(ph);
               ri = $rtoi(ai); rq = $rtoi(aq);
               if (ri >  131071) ri =  131071;
               if (ri < -131072) ri = -131072;
               if (rq >  131071) rq =  131071;
               if (rq < -131072) rq = -131072;
               e24i = $rtoi(ri * 39767.0 / 512.0);
               e24q = $rtoi(rq * 39767.0 / 512.0);
               if (e24i >  8388607) e24i =  8388607;
               if (e24i < -8388608) e24i = -8388608;
               if (e24q >  8388607) e24q =  8388607;
               if (e24q < -8388608) e24q = -8388608;
               // the CORDIC truncates and the two clips round to different
               // LSB patterns; 1500 LSB24 is 0.02 % of full scale
               if (oi[n] - e24i > 1500 || e24i - oi[n] > 1500 ||
                   oq[n] - e24q > 1500 || e24q - oq[n] > 1500) begin
                  bad = bad + 1;
                  if (off == 2 && bad < 6)
                     $display("   dbg n=%0d ph=%0d out (%0d,%0d) ref (%0d,%0d)",
                              n, (n + off) % 8, oi[n], oq[n], e24i, e24q);
               end
            end
            if (bad < best_bad) begin best_bad = bad; best_off = off; end
         end
         $display("TX-DC: complex corner (32767,32767) at 45 deg/sample: best phase offset %0d, %0d of 448 samples mismatch",
                  best_off, best_bad);
         if (best_bad > 2) begin
            errors = errors + 1;
            $display("TX-DC: FAIL - the corner does not match a saturated rotation at any phase (wrap?)");
         end
      end

      // and a corner below the rail must stay linear
      sample[31:16] = 16000; sample[15:0] = 16000;
      repeat (200) @(posedge clk);
      begin : corner_lin
         integer n, mmin, mmax, mag;
         real exp_mag, tmp;
         tmp = $sqrt(2.0) * 16000.0 * 4.0 * K_CORDIC;     // 74524: below the 18-bit rail
         exp_mag = tmp * 39767.0 / 512.0;
         mmin = 2000000000; mmax = 0;
         for (n = 0; n < 512; n = n + 1) begin
            @(posedge clk); #1;
            mag = $rtoi($sqrt(1.0*$signed(tx_fe_i)*$signed(tx_fe_i) +
                              1.0*$signed(tx_fe_q)*$signed(tx_fe_q)));
            if (mag < mmin) mmin = mag;
            if (mag > mmax) mmax = mag;
         end
         $display("TX-DC: complex corner (16000,16000): output magnitude %0d..%0d, reference %0d",
                  mmin, mmax, $rtoi(exp_mag));
         if (mmin < $rtoi(exp_mag * 0.995) || mmax > $rtoi(exp_mag * 1.005)) begin
            errors = errors + 1;
            $display("TX-DC: FAIL - a sub-rail corner is not rotated linearly");
         end
      end

      if (errors == 0)
         $display("TX-DC: PASS - DC gain 0.9992 at every rate with UHD's scale, scale word saturates, complex corner saturates");
      else
         $display("TX-DC: FAIL - %0d configurations wrong", errors);
      $finish;
   end

endmodule
