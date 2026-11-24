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
// The chain is programmed the way UHD's rx_dsp_core_3000 programs a B200
// (scale 39767 = 2^16 / 1.648, which cancels the CORDIC gain; decimation word
// with its halfband bits), and the bench also asserts that the output rate
// follows that word: one strobe per `decimation` clocks.
//
// Requires tests/sim/xilinx_prim_sim.v.
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
   integer            total;
   reg [9:0]          rate_word;

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

      set_reg(8'd0, 32'h0000_0000);   // CORDIC parked
      set_reg(8'd1, 32'd39767);       // UHD scale for CIC rate 1
      set_reg(8'd2, 32'h0000_0001);   // decimation 1, no halfband
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
      // The CORDIC truncates in each of its 20 stages and the output rounder
      // is a first-order sigma-delta, so a zero-valued channel reads within a
      // count of zero, not bit-zero.
      check(got_q >= -16'sd1 && got_q <= 16'sd1, "I-only input leaves Q at zero (+-1 LSB)");
      check(got_i >= -16'sd1 && got_i <= 16'sd1, "Q-only input leaves I at zero (+-1 LSB)");
      check(q_only !== 16'sd0,       "Q-only input produces a Q sample");
      // A single sample carries +-1 LSB of rounding from the sigma-delta.
      check(minus_i >= -i_only - 1 && minus_i <= -i_only + 1,
            "negative input gives the negative sample (+-1 LSB)");
      // 16 ADC counts in, gain 0.99925 (CORDIC 1.64676 against UHD's 1.648)
      check(i_only >= 16'sd15 && i_only <= 16'sd16, "unity gain at the scale UHD writes");
      check(q_only >= 16'sd15 && q_only <= 16'sd16, "unity gain on Q at the scale UHD writes");
      check(i_only > 0,              "sign of the I sample follows the input");

      // ---- rotation direction ---------------------------------------------
      // The Ettus CORDIC multiplies by exp(+j*theta): a positive frequency
      // word moves the spectrum up, and UHD's sign conventions are built on
      // that.  LO = fs/8, DC input of 512 ADC counts: the output must be
      // 511.6*cos(+k*45deg), 511.6*sin(+k*45deg).  A mixer turning the other
      // way matches none of the eight start phases, and a DC test with the LO
      // parked at zero cannot tell the two apart.
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
         // match.  The opposite rotation matches none.
         best_errs = 99;
         for (k0 = 0; k0 < 8; k0 = k0 + 1) begin
            errs = 0;
            for (k = 0; k < 8; k = k + 1) begin
               ex_i = 511.6 * $cos((k + k0) * 0.7853981633974483);
               ex_q = 511.6 * $sin((k + k0) * 0.7853981633974483);
               if (sq_i[k] - ex_i >  2.0 || sq_i[k] - ex_i < -2.0) errs = errs + 1;
               if (sq_q[k] - ex_q >  2.0 || sq_q[k] - ex_q < -2.0) errs = errs + 1;
            end
            if (errs < best_errs) best_errs = errs;
         end
         $display("  rotation at fs/8: first samples I=%0d,%0d Q=%0d,%0d (exp(+j theta): best match %0d errors)",
                  sq_i[0],sq_i[1],sq_q[0],sq_q[1],best_errs);
         check(best_errs == 0, "mixer turns counter-clockwise for a positive frequency word");
      end
      // ---- range: full-scale I and Q (complex envelope > full scale) -----
      // A quadrature signal never does this, but independent channels can
      // (blocker plus signal, clipped noise).  The CORDIC has a guard bit for
      // it and the two clip stages behind the CIC take the excess: the output
      // must sit at the rail, never wrap.
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
               ex = 46305.0 * $cos((k + k0) * 0.7853981633974483);
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

      // ---- output rate follows the decimation word --------------------------
      // UHD: decimation 2 = small halfband only (bit 9), 4 = both halfbands,
      // 8 = both over CIC rate 2, 3 = CIC only.
      for (r = 0; r < 5; r = r + 1) begin
         case (r)
           0: begin rate_word = 10'h001; total = 1; end
           1: begin rate_word = 10'h201; total = 2; end
           2: begin rate_word = 10'h003; total = 3; end
           3: begin rate_word = 10'h301; total = 4; end
           default: begin rate_word = 10'h302; total = 8; end
         endcase
         run <= 1'b0;
         set_reg(8'd2, rate_word);
         run <= 1'b1;
         repeat (800) @(posedge clk);        // past the halfbands' start-up flush
         measure_rate(4800, measured);
         expected_strobes = 4800 / total;
         $display("  decimation %0d (word 0x%03x): %0d strobes in 4800 cycles, expected %0d",
                  total, rate_word, measured, expected_strobes);
         check(measured == expected_strobes, "output rate is the clock rate over the decimation");
      end

      if (errors == 0) $display("PASS: ddc_chain sample path, I/Q independence, rotation, saturation, decimation (21 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
