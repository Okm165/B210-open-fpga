// tb_ddc_chain.v — the RX digital down-converter, end to end.
//
// Two real defects motivated this bench:
//
//  1. clip_reg drives strobe_out from its reset input.  Four instances in
//     ddc_chain left that port open.  Vivado ties an unconnected input to 0,
//     so strobe_out follows strobe_in; Yosys treats it as a don't-care and
//     folds strobe_out to constant 0, which stops the whole sample path.  The
//     synthesised `sample` output was literally 1'h0.
//
//  2. The I and Q datapaths were once tied together, turning the complex
//     DDC into a real (mono) datapath.
//
// The receive chain now performs no rate change and no filtering (CIC,
// compensator and halfbands were removed), so this bench also asserts that
// the output runs at exactly one sample per clock and that the rate / halfband
// setting registers no longer influence the datapath.
//
// Requires tests/sim/xilinx_prim_sim.v (SRLC32E / DSP48E1 behaviour).
`timescale 1ns/1ps

module tb_ddc_chain;

   localparam integer WIDTH = 24;

   reg                clk = 0;
   reg                rst = 1;
   reg                clr = 0;
   reg                run = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [WIDTH-1:0]   rx_i = 0;
   reg  [WIDTH-1:0]   rx_q = 0;

   wire [31:0]        sample;
   wire               strobe;
   wire [31:0]        debug;

   integer            errors = 0;
   integer            cyc = 0;
   integer            strobes = 0;
   integer            r;
   integer            expected_strobes;
   integer            measured;

   reg signed [15:0]  got_i, got_q;
   reg signed [15:0]  i_only, q_only, minus_i;

   always #5 clk = ~clk;      // 100 MHz

   ddc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
      .DEVICE("7SERIES")
   ) dut (
      .clk(clk), .rst(rst), .clr(clr),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
      .sample(sample), .run(run), .strobe(strobe),
      .debug(debug)
   );

   task check(input cond, input [8*64-1:0] what);
      begin
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL at cycle %0d: %0s", cyc, what);
         end
      end
   endtask

   // A comparison against x is not false, so `if (!cond)` silently passes.
   // Every captured value is therefore checked for definedness first.
   task check_known(input [15:0] v, input [8*48-1:0] what);
      begin
         if ((^v) === 1'bx) begin
            errors = errors + 1;
            $display("FAIL at cycle %0d: %0s is x", cyc, what);
         end
      end
   endtask

   task set_reg(input [7:0] addr, input [31:0] data);
      begin
         @(posedge clk);
         set_stb  <= 1'b1;
         set_addr <= addr;
         set_data <= data;
         @(posedge clk);
         set_stb  <= 1'b0;
      end
   endtask

   task settle(input [WIDTH-1:0] i, input [WIDTH-1:0] q, output signed [15:0] si,
               output signed [15:0] sq);
      begin
         rx_i = i;
         rx_q = q;
         repeat (6000) @(posedge clk);
         si = $signed(sample[31:16]);
         sq = $signed(sample[15:0]);
      end
   endtask

   // Count output strobes over a fixed window without touching the shared
   // counter, so the measurement has no side effects.
   task measure_rate(input integer window, output integer count);
      integer t;
      begin
         count = 0;
         for (t = 0; t < window; t = t + 1) begin
            @(posedge clk);
            if (!rst && strobe) count = count + 1;
         end
      end
   endtask

   always @(posedge clk) begin
      cyc <= cyc + 1;
      if (!rst && strobe) strobes <= strobes + 1;
   end

   initial begin
      repeat (8) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);

      // Scale and rate/halfband registers are no longer decoded; the writes
      // below are kept to prove the datapath ignores them.
      set_reg(8'd1, 32'h0000_0001);                    // would be scale ~0 if used
      set_reg(8'd2, 32'h0000_0000 | (2'b11 << 8) | 8'd8); // would be decim 16 if used
      set_reg(8'd3, 32'h0000_0000);   // no inversion, complex, no swap
      run <= 1'b1;

      // Input is a 16-bit sample in the top bits of a 24-bit signed word,
      // exactly as radio_legacy feeds it: {sample[15:0], 8'd0}.
      settle(24'sh0001000, 24'sh0000000, i_only, got_q);
      settle(24'sh0000000, 24'sh0001000, got_i, q_only);
      settle(-24'sh0001000, 24'sh0000000, minus_i, got_q);

      $display("  I-only : I=%0d Q=%0d", i_only, got_q);
      $display("  Q-only : I=%0d Q=%0d", got_i, q_only);
      $display("  -I     : I=%0d Q=%0d  (strobes=%0d)", minus_i, got_q, strobes);

      check_known(i_only,  "I sample");
      check_known(q_only,  "Q sample");
      check_known(got_i,   "I with Q-only input");
      check_known(got_q,   "Q with I-only input");
      check_known(minus_i, "I with negative input");

      check(strobes > 0,             "chain emits output strobes");
      check(i_only !== 16'sd0,       "I-only input produces an I sample");
      // The output quantiser is dithered with +-1 LSB (triangular), so a
      // zero-valued channel legitimately reads -1, 0 or +1: leakage-free means
      // "no signal-dependent component", not "bit-zero".
      check(got_q >= -16'sd1 && got_q <= 16'sd1, "I-only input leaves Q at zero (+-1 LSB dither)");
      check(got_i >= -16'sd1 && got_i <= 16'sd1, "Q-only input leaves I at zero (+-1 LSB dither)");
      check(q_only !== 16'sd0,       "Q-only input produces a Q sample");
      // The output rounder is dithered, so a single sample carries +-1 LSB of
      // legitimate rounding noise: the symmetry check must allow it.
      check(minus_i >= -i_only - 1 && minus_i <= -i_only + 1,
            "negative input gives the negative sample (+-1 LSB dither)");
      check(i_only > 0,              "sign of the I sample follows the input");

      // ---- rotation direction: down-conversion, not up-conversion -------
      // LO = fs/8, DC input of 512 ADC counts.  The output must be
      // 512*cos(-k*45deg), 512*sin(-k*45deg) -- i.e. the Q channel must lead
      // with the opposite sign to the I channel's sine term.  With +i*sin in
      // the Q path the rotation runs backwards (sideband at f_in+f_lo instead
      // of f_in-f_lo), which a DC test with LO parked at zero cannot detect.
      set_reg(8'd0, 32'h2000_0000);
      rx_i = 24'sd131072;   // 512 counts in the top 16 bits
      rx_q = 24'sd0;
      repeat (40) @(posedge clk);   // let the pipeline fill with the new input
      begin : rot
         integer k, idx, k0, best_errs, errs;
         reg signed [15:0] sq_i [0:7];
         reg signed [15:0] sq_q [0:7];
         real ex_i, ex_q;
         idx = 0;
         while (idx < 8) begin
            @(posedge clk);
            if (!rst && strobe) begin
               sq_i[idx] = $signed(sample[31:16]);
               sq_q[idx] = $signed(sample[15:0]);
               idx = idx + 1;
            end
         end
         // The absolute phase at capture time is wherever the accumulator
         // happens to be; try every 45-degree start and require ONE of them to
         // match exactly.  Up-conversion (the opposite rotation) matches none.
         best_errs = 99;
         for (k0 = 0; k0 < 8; k0 = k0 + 1) begin
            errs = 0;
            for (k = 0; k < 8; k = k + 1) begin
               ex_i = 512.0 * $cos(-(k + k0) * 0.7853981633974483);
               ex_q = 512.0 * $sin(-(k + k0) * 0.7853981633974483);
               if (sq_i[k] - ex_i >  2.0 || sq_i[k] - ex_i < -2.0) errs = errs + 1;
               if (sq_q[k] - ex_q >  2.0 || sq_q[k] - ex_q < -2.0) errs = errs + 1;
            end
            if (errs < best_errs) best_errs = errs;
         end
         $display("  rotation at fs/8: first samples I=%0d,%0d Q=%0d,%0d (down-conversion: best match %0d errors)",
                  sq_i[0],sq_i[1],sq_q[0],sq_q[1],best_errs);
         check(best_errs == 0, "mixer down-converts (Q rotation sign) at fs/8");
      end
      // ---- range: full-scale I and Q (complex envelope > full scale) -----
      // A quadrature signal never does this, but independent channels can
      // (blocker plus signal, clipped noise).  The output must saturate at the
      // rail, never wrap: before the saturator this produced 19199 where the
      // true value is 46340, with inverted sign.
      rx_i = 24'sd32767 << 8;
      rx_q = 24'sd32767 << 8;
      repeat (40) @(posedge clk);
      begin : range
         integer k, idx, k0, best, errs, v;
         reg signed [15:0] sq [0:7];
         real ex;
         idx = 0;
         while (idx < 8) begin
            @(posedge clk);
            if (!rst && strobe) begin
               sq[idx] = $signed(sample[31:16]);
               idx = idx + 1;
            end
         end
         best = 99;
         for (k0 = 0; k0 < 8; k0 = k0 + 1) begin
            errs = 0;
            for (k = 0; k < 8; k = k + 1) begin
               ex = 46340.0 * $cos(-(k + k0) * 0.7853981633974483);
               if (ex >  32767.0) ex =  32767.0;   // saturate, as the RTL does
               if (ex < -32768.0) ex = -32768.0;
               v = sq[k];
               if (v - ex > 2.0 || v - ex < -2.0) errs = errs + 1;
            end
            if (errs < best) best = errs;
         end
         $display("  full-scale I and Q: first samples %0d,%0d,%0d (saturating, %0d errors)",
                  sq[0], sq[1], sq[2], best);
         check(best == 0, "oversized complex envelope saturates at the rail, does not wrap");
      end
      rx_i = 24'sd0; rx_q = 24'sd0;
      set_reg(8'd0, 32'h0000_0000);

      // ---- full rate, independent of the (ignored) rate register ---------
      // One sample per clock is the defining property of the lossless path.
      for (r = 2; r <= 8; r = r * 2) begin
         set_reg(8'd2, (2'b11 << 8) | r[7:0]);
         repeat (200) @(posedge clk);
         measure_rate(4000, measured);
         expected_strobes = 4000;
         $display("  rate register %0d: %0d strobes in 4000 cycles, expected %0d",
                  r, measured, expected_strobes);
         check(measured >= expected_strobes - 2 && measured <= expected_strobes,
               "output stays at one sample per clock (rate register ignored)");
      end

      if (errors == 0) $display("PASS: ddc_chain sample path, I/Q independence, full-rate output (17 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
