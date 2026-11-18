// tb_duc_chain.v - the TX digital up-converter, end to end.
//
// The RX side has a bench because it broke: an open clip_reg reset folded the
// sample strobe to zero, and the halfband replacement made Q a copy of I.
// The TX side has the same structures (two halfbands, a CIC interpolator, two
// clip_reg instances) and the same failure mode would be silent in the other
// direction: a transmitter that emits zeros, or a complex upconverter that
// emits a real signal.
//
// It also pins the clip_reg contract that made the RX defect possible: both
// instances here leave `reset` open and tie `strobe_in` high.  That is safe
// only because nothing consumes their strobe_out; this bench proves the data
// path still updates in that configuration.
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

   always #5 clk = ~clk;      // 100 MHz

   duc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
      .NEW_HB_INTERP(1), .DEVICE("7SERIES")
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

      // Power-on x is a simulation-only artefact here: hb47_int emits x for
      // its first output samples, and the CIC interpolator's integrators then
      // add that x once and stay x forever (a feedback accumulator cannot
      // recover).  Registers start at 0 in the bitstream, so silicon has no
      // such state.  Prime the chain, pulse rst to clear the integrators,
      // re-program the settings (rst also clears the setting registers) and
      // the datapath is defined from then on.
      set_reg(8'd0, 32'h0000_0000);
      set_reg(8'd1, 32'h0001_FFFF);
      set_reg(8'd2, (2'b11 << 8) | 8'd2);
      run <= 1'b1;
      repeat (300) @(posedge clk);
      rst <= 1'b1;
      repeat (4) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);
      run <= 1'b0;

      // phase increment 0 (DC), scale ~1.0 in Q17, both halfbands on,
      // interpolation rate 2 - the same shape radio_legacy programs.
      set_reg(8'd0, 32'h0000_0000);
      set_reg(8'd1, 32'h0001_FFFF);
      set_reg(8'd2, (2'b11 << 8) | 8'd2);
      run <= 1'b1;

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
      check(got_q === 16'sd0,     "I-only input leaves Q at zero");
      check(got_i === 16'sd0,     "Q-only input leaves I at zero");
      check(q_only !== 16'sd0,    "Q-only input produces a Q output");
      check(minus_i < 0,          "negative input gives a negative output");
      check(i_only > 0,           "sign of the I output follows the input");

      if (errors == 0) $display("PASS: duc_chain output path and I/Q independence (12 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
