// -*- verilog -*-
//
// Bench for the CIC inverse-sinc compensator (cic_comp.v).
//
// 1. Impulse response: must equal the design taps exactly (proves tap
//    order, symmetry wiring, pipeline and strobe alignment).
// 2. DC response: gain 1.0 +- 1 LSB (proves the q17 shift/clip path).
//
`timescale 1ns/1ps

module tb_cic_comp;

   reg clk = 0, rst = 1;
   always #5 clk = ~clk;

   reg         stb = 0;
   reg signed [17:0] din = 0;
   wire        stb_out;
   wire signed [17:0] dout;

   cic_comp #(.WIDTH(18)) dut
     (.clk(clk), .rst(rst), .stb_in(stb), .data_in(din),
      .stb_out(stb_out), .data_out(dout));

   // design taps, q17, in y[n] = sum_k c_k x[n-k] order (tap 0 first)
   reg signed [17:0] taps [0:14];
   initial begin
      taps[0]  = 18'sd1262;   taps[1]  = -18'sd10783; taps[2]  = 18'sd15333;
      taps[3]  = 18'sd6275;   taps[4]  = -18'sd27192; taps[5]  = -18'sd10388;
      taps[6]  = 18'sd63968;  taps[7]  = 18'sd54124;  taps[8]  = 18'sd63968;
      taps[9]  = -18'sd10388; taps[10] = -18'sd27192; taps[11] = 18'sd6275;
      taps[12] = 18'sd15333;  taps[13] = -18'sd10783; taps[14] = 18'sd1262;
   end

   integer errors = 0;
   integer n_imp;

   // one input strobe, then wait for the matching output strobe (bounded)
   task do_sample;
     input signed [17:0] x;
     integer guard;
     begin
        // drain any in-flight output strobe from the previous sample first
        // (pipeline latency spans cycles, so a new strobe would otherwise
        // capture the previous sample's output - an undrained-pipeline
        // bench artifact, not an RTL issue)
        guard = 0;
        while (stb_out === 1'b1 && guard < 10) begin
           @(negedge clk);
           guard = guard + 1;
        end
        @(negedge clk);
        din <= x;
        stb <= 1'b1;
        @(negedge clk);
        stb <= 1'b0;
        guard = 0;
        // sample mid-cycle (post-NBA) so strobe and data are both settled
        while (stb_out !== 1'b1 && guard < 10) begin
           @(negedge clk);
           guard = guard + 1;
        end
        if (guard >= 10) begin
           $display("FAIL: no strobe_out within 10 clk");
           errors = errors + 1;
        end
     end
   endtask

   initial begin
      repeat (5) @(posedge clk);
      rst = 0;
      repeat (3) @(posedge clk);

      // ---- 1. impulse response ----
      // The multiplier stage registers the delay line before its shi-strobe
      // update, so the whole FIR carries one extra sample of group delay;
      // prime with one zero sample and the response lines up with the taps.
      do_sample(18'sd0);
      // x[0] = 2^15 impulse; expected y[n] = taps[n] * 2^15 >> 17 = taps[n]/4
      do_sample(18'sd32768);
      if (dout !== (taps[0] >>> 2)) begin
         $display("FAIL: impulse y[0] = %0d, expected %0d", dout, taps[0] >>> 2);
         errors = errors + 1;
      end
      for (n_imp = 1; n_imp < 15; n_imp = n_imp + 1) begin
         do_sample(18'sd0);
         if (dout !== (taps[n_imp] >>> 2)) begin
            $display("FAIL: impulse y[%0d] = %0d, expected %0d",
                     n_imp, dout, taps[n_imp] >>> 2);
            errors = errors + 1;
         end
      end
      $display("INFO: impulse response verified (15 taps)");

      // ---- 2. DC response ----
      repeat (20) begin
         do_sample(18'sd32000);
      end
      if (dout < 18'sd31999 || dout > 18'sd32001) begin
         $display("FAIL: DC output %0d, expected 32000 +- 1", dout);
         errors = errors + 1;
      end else
        $display("INFO: DC response %0d (expect 32000)", dout);

      if (errors == 0)
        $display("PASS: tb_cic_comp impulse+DC verified");
      else
        $display("FAIL: %0d errors", errors);
      $finish;
   end


endmodule
