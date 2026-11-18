// Validates b200_clk_gen and, at the same time, the MMCME2_ADV/BUFG/IBUFDS
// models in tests/sim/xilinx_prim_sim.v.
//
// Documented plan (README, chapter 02): 40 MHz differential in, VCO 1000 MHz,
// outputs 40 / 100 / 100 MHz.
`timescale 1ns/1ps

module tb_b200_clk_gen;

   reg  clk_p = 0;
   reg  clk_n = 1;
   reg  reset = 1;

   wire clk40, clk100_gpif, clk100_bus, locked;

   integer errors = 0;

   // 40 MHz differential reference
   always #12.5 clk_p = ~clk_p;
   always #12.5 clk_n = ~clk_n;

   b200_clk_gen dut (
      .clk_in1_p         (clk_p),
      .clk_in1_n         (clk_n),
      .CLK_OUT1_40_int   (clk40),
      .CLK_OUT2_100_gpif (clk100_gpif),
      .CLK_OUT3_100_bus  (clk100_bus),
      .reset             (reset),
      .locked            (locked)
   );

   // --- period measurement ------------------------------------------------
   time t40, t100g, t100b;
   time p40 = 0, p100g = 0, p100b = 0;

   initial begin t40 = 0; t100g = 0; t100b = 0; end

   always @(posedge clk40) begin
      if (t40 != 0) p40 = $time - t40;
      t40 = $time;
   end
   always @(posedge clk100_gpif) begin
      if (t100g != 0) p100g = $time - t100g;
      t100g = $time;
   end
   always @(posedge clk100_bus) begin
      if (t100b != 0) p100b = $time - t100b;
      t100b = $time;
   end

   task check(input cond, input [8*64-1:0] what);
      begin
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", what);
         end
      end
   endtask

   initial begin
      repeat (10) @(posedge clk_p);
      reset = 0;
      repeat (120) @(posedge clk_p);   // MMCM model locks after 64 ref clocks

      $display("  locked=%b  40MHz period=%0t  100MHz periods=%0t / %0t",
               locked, p40, p100g, p100b);

      check(locked === 1'b1,                       "MMCM reports LOCKED");
      check(p40 == 25,                             "CLK_OUT1 is 25 ns (40 MHz)");
      check(p100g == 10,                           "CLK_OUT2 is 10 ns (100 MHz, GPIF)");
      check(p100b == 10,                           "CLK_OUT3 is 10 ns (100 MHz, bus)");

      if (errors == 0) $display("PASS: b200_clk_gen 40/100/100 MHz plan (4 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #5000;
      $display("FAIL: timeout waiting for clocks");
      $finish;
   end

endmodule
