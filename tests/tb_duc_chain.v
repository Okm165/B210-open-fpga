// tb_duc_chain.v - the TX digital up-converter, end to end.
//
// The RX side has a bench because it broke: an open clip_reg reset folded the
// sample strobe to zero, and the halfband replacement made Q a copy of I.
// The TX side has the same structures (two halfbands, a CIC interpolator, two
// clip_reg instances) and the same failure mode would be silent in the other
// direction: a transmitter that emits zeros, or a complex upconverter that
// emits a real signal.
//
// The chain is programmed the way UHD's tx_dsp_core_3000 programs it for an
// interpolation of 8: both halfbands, CIC rate 2, scale 39767 = 2^16 / 1.648,
// which cancels the CORDIC gain.
//
// Requires tests/sim/xilinx_prim_sim.v.
`timescale 1ns/1ps

module tb_duc_chain;

   localparam integer WIDTH = 24;

   reg                clk = 0;
   reg                rst = 1;
   reg                clr = 0;
   reg                run = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [31:0]        sample = 0;

   wire [WIDTH-1:0]   tx_i, tx_q;
   wire               strobe;
   wire [31:0]        debug;

   integer            errors = 0;
   integer            cyc = 0;
   integer            strobes = 0;

   reg signed [15:0]  got_i, got_q;
   reg signed [15:0]  i_only, q_only, minus_i;
   reg signed [15:0]  zero_i, zero_q;
   integer            zero_bad = 0;

   always #5 clk = ~clk;      // 100 MHz

   duc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
       .DEVICE("7SERIES")
   ) dut (
      .clk(clk), .rst(rst), .clr(clr),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
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

   // sample is {I[15:0], Q[15:0]}; hold it and read the TX frontend outputs.
   task settle(input signed [15:0] i, input signed [15:0] q, output signed [15:0] si,
               output signed [15:0] sq);
      begin
         sample = {i, q};
         repeat (6000) @(posedge clk);
         si = $signed(tx_i[WIDTH-1:WIDTH-16]);
         sq = $signed(tx_q[WIDTH-1:WIDTH-16]);
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

      // No priming: the chain must come out of reset defined.  (The halfband
      // interpolator has registers without reset; they carry power-up values
      // so that the CIC integrators behind them never see an X.)
      set_reg(8'd0, 32'h0000_0000);            // CORDIC parked
      set_reg(8'd1, 32'd39767);                // UHD scale for CIC rate 2
      set_reg(8'd2, (2'b11 << 8) | 8'd2);      // interpolation 8
      run <= 1'b1;

      settle( 16'sd0,     16'sd0,    zero_i, zero_q);

      // I/Q leakage: with Q-only input the I output must stay at its idle
      // value on every strobe, not just at one sampling instant.  The idle
      // value is not zero: the Ettus CORDIC truncates in each stage, which
      // leaves a constant offset of one count of the 16-bit word (the pin
      // quantiser in radio_legacy rounds it away).
      sample = {16'sd0, 16'sd1000};
      repeat (2000) begin
         @(posedge clk);
         if (strobe && ($signed(tx_i[WIDTH-1:WIDTH-16]) < -16'sd1 ||
                        $signed(tx_i[WIDTH-1:WIDTH-16]) >  16'sd0))
           zero_bad = zero_bad + 1;
      end
      settle( 16'sd1000,  16'sd0,    i_only, got_q);
      settle( 16'sd0,     16'sd1000, got_i,  q_only);
      settle(-16'sd1000,  16'sd0,    minus_i, got_q);

      $display("  I-only : I=%0d Q=%0d", i_only, got_q);
      $display("  Q-only : I=%0d Q=%0d", got_i, q_only);
      $display("  -I     : I=%0d Q=%0d  (strobes=%0d)", minus_i, got_q, strobes);

      check_known(i_only,  "I output");
      check_known(q_only,  "Q output");
      check_known(got_i,   "I with Q-only input");
      check_known(got_q,   "Q with I-only input");
      check_known(minus_i, "I with negative input");

      check(strobes > 0,          "TX chain emits strobes");
      check(i_only !== 16'sd0,    "I-only input produces an I output");
      check(zero_bad === 0,       "Q-only input leaves I at its idle value on every strobe");
      check(zero_i >= -16'sd1 && zero_i <= 16'sd0, "zero input leaves I within the CORDIC's one count");
      check(zero_q >= -16'sd1 && zero_q <= 16'sd0, "zero input leaves Q within the CORDIC's one count");
      check(got_q >= -16'sd1 && got_q <= 16'sd0,   "I-only input leaves Q at its idle value");
      check(got_i >= -16'sd1 && got_i <= 16'sd0,   "Q-only input leaves I at its idle value");
      // 1000 in, gain 0.99925 (CORDIC 1.64676 against UHD's 1.648)
      check(i_only >= 16'sd998 && i_only <= 16'sd1000, "unity gain at the scale UHD writes");
      check(q_only >= 16'sd998 && q_only <= 16'sd1000, "unity gain on Q at the scale UHD writes");
      check(q_only !== 16'sd0,    "Q-only input produces a Q output");
      check(minus_i < 0,          "negative input gives a negative output");
      check(i_only > 0,           "sign of the I output follows the input");

      if (errors == 0) $display("PASS: duc_chain output path, I/Q independence and unity gain (17 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
