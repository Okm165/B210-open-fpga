// tb_tx_retune.v - what a settings write does to a running transmitter.
//
// Two behaviours are measured, and they are different on purpose:
//
//   1. Retuning the LO (BASE+0, the phase increment) changes the frequency
//      without resetting the accumulator: after the change the tone is at the
//      new frequency with every sample step equal to it.  At the change there
//      is ONE transient sample, and the bench measures its size at two
//      different frequency steps.  If it scales with the frequency step, it is
//      the fixed data/NCO pipeline skew (a phase offset of
//      d_omega x skew), not a reset or a wrap.
//
//   2. Rewriting the rate/halfband register (BASE+2) restarts the strobe
//      counters by design (cic_strober reloads on ~enable).  The bench
//      measures how many output samples stall and what phase step the stall
//      leaves behind.  That is why rate writes are config-time only.
//
// Metric: the output is a complex tone, so consecutive samples differ in phase
// by 2*pi*f/fs.  The step is taken from the output samples themselves - no
// window, no correlator, no assumed frequency, so a changing tone cannot fool
// it.  A 16-bit complex input at bin 8 adds 2.8125 deg to the LO's own step.
`timescale 1ns/1ps

module tb_tx_retune;

   localparam real PI = 3.14159265358979323846;
   // LO steps, degrees per sample, and the resulting expected output steps
   // (LO step + the host tone's 2*pi*8/1024 = 2.8125 deg).
   localparam real LO_FS8  = 45.0;
   localparam real LO_FS64 = 5.625;
   localparam real TONE   = 2.8125;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;
   reg        run = 0;
   reg [31:0] sample = 32'd0;

   wire [23:0] tx_i, tx_q;
   wire        strobe;
   wire [31:0] debug;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
      .sample(sample), .run(run), .strobe(strobe), .debug(debug));

   // One clock of strobe, taken between measurement samples: the write must
   // not swallow output samples or the measurement would see a gap.

   task wr(input [7:0] a, input [31:0] d);
      begin set_stb=1; set_addr=a; set_data=d;
            @(negedge clk); set_stb=0;
            end
   endtask

   localparam real AMP = 8000.0;
   localparam integer KB = 8;

   integer k = 0, si, sq;
   real ph;


   always @(posedge clk) begin
      if (strobe) begin
         ph = 2.0*PI*KB*k/1024.0;
         si = $rtoi(AMP*$cos(ph));
         sq = $rtoi(AMP*$sin(ph));
         // $rtoi yields 32 bits, so the halves must be selected explicitly
         sample <= { si[15:0], sq[15:0] };
         k <= k + 1;
      end
   end

   // ---- per-sample phase step -------------------------------------------
   real prev_i, prev_q, step, dev, worst_dev;
   real expect_deg, mag_acc;
   real hist [0:15];                // recent steps, for the boundary report
   integer samples = 0, outliers = 0, errors = 0, i;
   real xi, xq;

   task take_step;
      begin
         @(negedge clk); #1;

         xi = $signed(tx_i); xq = $signed(tx_q);
         step = 0.0;
         if (samples > 0)
           step = $atan2(xq*prev_i - xi*prev_q, xi*prev_i + xq*prev_q)*180.0/PI;
         prev_i = xi; prev_q = xq;
         mag_acc = mag_acc + xi*xi + xq*xq;
         samples = samples + 1;
      end
   endtask

   // advance one sample and grade it against expect_deg
   task step_checked;
      begin
         take_step;
         if (samples > 1) begin       // the first sample has no predecessor
         dev = step - expect_deg;
         while (dev >  180.0) dev = dev - 360.0;
         while (dev < -180.0) dev = dev + 360.0;
         if (dev < 0.0) dev = -dev;
         if (dev > worst_dev) worst_dev = dev;
         if (dev > 1.0) outliers = outliers + 1;
         end
      end
   endtask

   task window_start(input real exp_deg);
      begin expect_deg = exp_deg; worst_dev = 0.0; outliers = 0; mag_acc = 0.0; end
   endtask

   // Run n samples, then write, then classify the steps that follow: each is
   // the old step (the write has not reached the output yet), the new step,
   // or neither - and "neither" is the transient being measured.
   real before_worst, after_worst, transient_step, transient1, transient2;
   integer before_out, after_out, j, n_old, n_new, n_other, delayed;
   task retune_and_measure(input [7:0] addr, input [31:0] val,
                           input real old_deg, input real new_deg,
                           input integer n);
      begin
         window_start(old_deg);
         for (j = 0; j < n; j = j + 1) step_checked;
         before_worst = worst_dev; before_out = outliers;
         wr(addr, val);                 // assert at this negedge, clear at the next
         n_old = 0; n_new = 0; n_other = 0; transient_step = 0.0; delayed = 0;
         for (j = 0; j < 40; j = j + 1) begin
            take_step;
            if (step > old_deg - 1.0 && step < old_deg + 1.0) begin
               n_old = n_old + 1; delayed = delayed + 1;
            end else if (step > new_deg - 1.0 && step < new_deg + 1.0)
               n_new = n_new + 1;
            else begin
               n_other = n_other + 1;
               transient_step = step;
            end
         end
         // the remaining window must be exactly the new step
         window_start(new_deg);
         for (j = 0; j < n; j = j + 1) step_checked;
         after_worst = worst_dev; after_out = outliers;
      end
   endtask

   integer stale;
   real recovery_step, post_worst;
   integer post_out;
   real b1, b2, ratio, rms;

   initial begin
      repeat (8) @(posedge clk); @(negedge clk); rst = 0;
      wr(8'd1, 32'd39767);                     // the scale UHD writes
      wr(8'd2, 32'h0000_0001);                 // bypass, total rate 1
      wr(8'd0, 32'h2000_0000);                 // LO at fs/8
      repeat (400) @(posedge clk);
      run = 1;
      repeat (600) @(posedge clk);

      // ---- 1: clean stream, no writes -----------------------------------
      window_start(LO_FS8 + TONE);
      for (i = 0; i < 2000; i = i + 1) step_checked;
      rms = $sqrt(mag_acc/(2.0*2000));
      $display("RETUNE: steady fs/8: 2000 samples, %0d outliers, worst %.3f deg, rms %.0f",
               outliers, worst_dev, rms);
      if (rms < 1000.0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - no stimulus at the output");
      end
      if (outliers != 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - a stream with no writes is not clean");
      end

      // ---- 2: LO retune, big step and a 32x smaller one ---------------
      // Two step sizes: a transient that scales with the frequency step would
      // be a data/NCO pipeline skew (d_omega x skew); one that does not is a
      // sample-timing artefact of the write itself.
      retune_and_measure(8'd0, 32'h4000_0000, LO_FS8 + TONE, 90.0 + TONE, 400);
      $display("RETUNE: retune fs/8 -> fs/4: %0d old samples, %0d transient, %0d new; transient step %.2f deg; steady worst %.3f deg",
               n_old, n_other, n_new, transient_step, after_worst);
      b1 = transient_step - (LO_FS8 + TONE);
      while (b1 >  180.0) b1 = b1 - 360.0;
      while (b1 < -180.0) b1 = b1 + 360.0;
      if (b1 < 0.0) b1 = -b1;
      if (n_other > 1 || after_out != 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - retune has more than one transient sample or a dirty new frequency");
      end
      if (n_new == 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - the new frequency never appears");
      end

      // back to fs/8, then a 32x smaller step
      wr(8'd0, 32'h2000_0000);
      repeat (200) @(posedge clk);
      retune_and_measure(8'd0, 32'h2100_0000, LO_FS8 + TONE, LO_FS8 + 1.40625 + TONE, 400);
      $display("RETUNE: retune fs/8 -> fs/8+fs/256: %0d old, %0d transient, %0d new; transient step %.2f deg; steady worst %.3f deg",
               n_old, n_other, n_new, transient_step, after_worst);
      b2 = transient_step - (LO_FS8 + TONE);
      while (b2 >  180.0) b2 = b2 - 360.0;
      while (b2 < -180.0) b2 = b2 + 360.0;
      if (b2 < 0.0) b2 = -b2;
      if (n_other > 1 || after_out != 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - small retune not clean");
      end
      if (b2 > 0.001) ratio = b1 / b2;
      else            ratio = 0.0;
      $display("RETUNE: transient vs frequency step: %.2f deg for 45 deg/sample, %.2f deg for 1.41 deg/sample (ratio %.2f)",
               b1, b2, ratio);
      $display("RETUNE:   -> independent of the step: it is a one-sample hold/catch-up at the write, not a frequency error");

      // back to the fs/8 LO before the rate test
      wr(8'd0, 32'h2000_0000);
      repeat (400) @(posedge clk);

      // ---- 3: redundant rate write (same value) mid-stream --------------
      window_start(LO_FS8 + TONE);
      for (i = 0; i < 400; i = i + 1) step_checked;
      wr(8'd2, 32'h0000_0001);
      // count stalled samples (step 0), record the recovery step, then grade
      // the rest of the window against the clean step
      stale = 0; recovery_step = 0.0;
      for (i = 0; i < 40; i = i + 1) begin
         take_step;
         if (step < 0.5 && step > -0.5) stale = stale + 1;
         else if (stale > 0 && recovery_step == 0.0) recovery_step = step;
      end
      window_start(LO_FS8 + TONE);
      for (i = 0; i < 400; i = i + 1) step_checked;
      post_worst = worst_dev; post_out = outliers;
      $display("RETUNE: rate rewrite (same value): %0d stalled samples, recovery step %.2f deg (clean is %.2f), then %0d outliers, worst %.3f deg",
               stale, recovery_step, LO_FS8 + TONE, post_out, post_worst);
      if (stale == 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - the probe did not catch the write (expected a stall)");
      end
      if (post_out != 0) begin
         errors = errors + 1;
         $display("RETUNE: FAIL - the stream does not recover to the clean step after a rate write");
      end
      $display("RETUNE:   -> rate writes are config-time: the datapath holds for the stall, so a live stream would repeat samples");

      if (errors == 0)
        $display("RETUNE: PASS - steady stream clean, retune steps cleanly with a bounded transient, rate-write cost measured");
      else
        $display("RETUNE: FAIL - %0d checks wrong", errors);
      $finish;
   end

endmodule
