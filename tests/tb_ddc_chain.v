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
//  2. The behavioural replacement for the CoreGen hbdec1/hbdec2 cores
//     (src/ip/hbdec.v) processed only din_1 and drove dout_2 from the same
//     accumulator, making the complex DDC a real (mono) datapath.
//
// This bench asserts the properties that were silently broken: with the chain
// running and a scale factor written, a constant input must produce samples,
// and channel 1 / channel 2 (I and Q) must be independent.
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
      .NEW_HB_DECIM(1), .DEVICE("7SERIES")
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

      // scale factor ~1.0 (Q17), both halfband stages enabled, CIC rate 2
      set_reg(8'd1, 32'h0001FFFF);
      set_reg(8'd2, 32'h0000_0000 | (2'b11 << 8) | 8'd2);
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
      check(got_q === 16'sd0,        "I-only input leaves Q at zero");
      check(got_i === 16'sd0,        "Q-only input leaves I at zero");
      check(q_only !== 16'sd0,       "Q-only input produces a Q sample");
      check(minus_i === -i_only,     "negative input gives the negative sample");
      check(i_only > 0,              "sign of the I sample follows the input");

      // ---- decimation ratio of the whole chain ---------------------------
      // rx sample rate is one per clock; CIC divides by `rate`, each halfband
      // by two, so the output strobe period is 4*rate clocks.  This is the
      // property that a missing or duplicated decimation stage breaks while
      // every sample still looks plausible.
      for (r = 2; r <= 8; r = r * 2) begin
         set_reg(8'd2, (2'b11 << 8) | r[7:0]);
         repeat (6000) @(posedge clk);
         measure_rate(40000, measured);
         expected_strobes = 40000 / (4 * r);
         $display("  rate %0d: %0d strobes in 40000 cycles, expected %0d",
                  r, measured, expected_strobes);
         check(measured >= expected_strobes - 1 && measured <= expected_strobes + 1,
               "output strobe period is 4*CIC rate");
      end

      if (errors == 0) $display("PASS: ddc_chain sample path, I/Q independence, decimation ratio (16 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
