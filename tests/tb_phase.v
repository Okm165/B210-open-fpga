// tb_phase.v - is the TX interpolation chain linear phase (no dispersion)?
//
// An amplitude-flat filter can still distort a pulse if its phase is not
// linear.  The definitive time-domain test is simple and exact: a real FIR has
// linear phase if and only if its impulse response is symmetric about its
// centre.  This bench injects one impulse into duc_chain (LO 0), captures the
// 24-bit pin word, and compares the response end-to-end:
//
//     h[first + i]  ==  h[last - i]
//
// Symmetry about (first+last)/2 is exactly constant group delay; any
// dispersion shows up as a difference between the leading and trailing tails.
// The test is run on the filter-heavy configuration (both halfbands, CIC
// rate 2, total 8) and on the bypass (a single sample, the reference).
`timescale 1ns/1ps

module tb_phase;

   localparam integer NMAX = 8192;
   localparam integer AMP  = 1000;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0; reg [7:0] set_addr = 0; reg [31:0] set_data = 0;
   reg  [31:0] sample = 0;
   reg         run = 0;
   wire [23:0] tx_i, tx_q;
   wire        strobe;
   wire [31:0] debug;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
      .sample(sample), .run(run), .strobe(strobe), .debug(debug));

   task wr(input [7:0] a, input [31:0] d);
      begin @(negedge clk); set_stb=1; set_addr=a; set_data=d;
            @(negedge clk); set_stb=0; end
   endtask

   // captured response
   integer h [0:NMAX-1];
   integer nh, peak, first, last, mid2, i, k;
   integer errors;
   real asym, rel;
   integer r_out;          // output clocks per input sample
   integer dump = 1, cfg_id = 0;

   task capture;
      begin
         nh = 0;
         for (k = 0; k < NMAX; k = k + 1) begin
            @(posedge clk); #1;
            // Keep the SIGN: a halfband response has negative side lobes, and
            // |h| is not symmetric even when h is.  Magnitude is used only for
            // the support and the peak.
            h[k] = $signed(tx_i);      // I channel; Q is 0 with LO at DC
            if (dump) $display("HD %0d %0d %0d", cfg_id, k, h[k]);
         end
      end
   endtask

   task run_config(input integer hb, input integer rate, input integer rout);
      integer m;
      begin
         r_out = rout;
         // Full reset between configurations: the filter state must not carry
         // over from the previous run, or the "impulse response" is the old
         // tail plus the new impulse.
         rst = 1;
         repeat (8) @(posedge clk);
         @(negedge clk); rst = 0;
         repeat (8) @(posedge clk);
         wr(8'd0, 32'd0);                       // LO at DC
         wr(8'd1, 32'd39767);                   // the scale UHD writes (CIC rates 1, 2, 4)
         wr(8'd2, ({2'b00, hb} << 8) | rate);   // {hb1,hb2,rate}
         sample = 0; run = 0;
         repeat (200) @(posedge clk);
         run = 1;
         // let the pipeline settle on zeros, then inject exactly one impulse
         repeat (2000) @(posedge clk);
         @(posedge clk);
         while (!(strobe && run)) @(posedge clk);
         @(negedge clk); sample = {AMP[15:0], 16'd0};
         @(posedge clk);
         while (!(strobe && run)) @(posedge clk);
         @(negedge clk); sample = 0;

         capture;

         // support: everything above 0.1 % of the peak
         peak = 0;
         for (m = 0; m < NMAX; m = m + 1) begin
            if (h[m] > 0) begin
               if (h[m] > peak) peak = h[m];
            end else begin
               if (-h[m] > peak) peak = -h[m];
            end
         end
         first = 0; last = NMAX-1;
         for (m = 0; m < NMAX; m = m + 1)
            if (((h[m] > 0) ? h[m] : -h[m]) > peak/1000) begin first = m; m = NMAX; end
         for (m = NMAX-1; m >= 0; m = m - 1)
            if (((h[m] > 0) ? h[m] : -h[m]) > peak/1000) begin last = m; m = -1; end
         mid2 = first + last;

         asym = 0.0;
         for (m = 0; m <= (last-first)/2; m = m + 1) begin
            rel = (h[first+m] > h[last-m]) ? (h[first+m]-h[last-m])
                                           : (h[last-m]-h[first+m]);
            if (rel > asym) asym = rel;
         end
         asym = asym / (peak + 1.0e-9);

         $display("PHASE: hb %02b rate %0d (x%0d) impulse support %0d..%0d (%0d clk) peak %0d",
                  hb, rate, rout, first, last, last-first+1, peak);
         $display("PHASE:   symmetry error %.3e of peak, group delay %.1f output clocks = %.2f input samples",
                  asym, (mid2*1.0)/2.0, (mid2*1.0)/2.0/rout);
         if (asym > 1.0e-3) begin
            errors = errors + 1;
            $display("PHASE:   FAIL - impulse response is not symmetric (dispersion)");
         end
         run = 0;
         repeat (200) @(posedge clk);
      end
   endtask

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;

      // bypass: the reference (no filter, one output sample)
      cfg_id=1; run_config(2'b00, 1, 1);
      // one halfband: total 2
      cfg_id=2; run_config(2'b01, 1, 2);
      // both halfbands + CIC rate 2: the filter-heavy path, total 8
      cfg_id=8; run_config(2'b11, 2, 8);
      // both halfbands, CIC rate 1: total 4
      cfg_id=4; run_config(2'b11, 1, 4);
      // CIC rate 4: total 16, the heaviest CIC configuration
      cfg_id=16; run_config(2'b11, 4, 16);

      if (errors == 0)
         $display("PHASE: PASS - the TX impulse response is symmetric at every rate: linear phase, constant group delay");
      else
         $display("PHASE: FAIL - %0d configurations dispersive", errors);
      $finish;
   end

endmodule
