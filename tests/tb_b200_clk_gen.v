// Validates b200_clk_gen and, at the same time, the MMCME2_ADV/BUFG/IBUFDS
// models in tests/sim/xilinx_prim_sim.v.
//
// Clock plan: 40 MHz differential in, VCO 1200 MHz, bus clock = VCO / BUS_DIVIDE
// (12 -> 100 MHz as built, 15 -> 80 MHz).
`timescale 1ns/1ps

module tb_b200_clk_gen;

   reg  clk_p = 0;
   reg  clk_n = 1;
   reg  reset = 1;

   wire clk80, locked80, clk100, locked100;

   integer errors = 0;

   // 40 MHz differential reference
   always #12.5 clk_p = ~clk_p;
   always #12.5 clk_n = ~clk_n;

   // the plan the design builds with
   b200_clk_gen dut_default (
      .clk_in1_p(clk_p), .clk_in1_n(clk_n),
      .bus_clk(clk100), .reset(reset), .locked(locked100));

   b200_clk_gen #(.BUS_DIVIDE(15)) dut80 (
      .clk_in1_p(clk_p), .clk_in1_n(clk_n),
      .bus_clk(clk80), .reset(reset), .locked(locked80));

   // --- period measurement, in picoseconds ---------------------------------
   realtime t80 = 0, t100 = 0;
   integer  p80 = 0, p100 = 0;

   always @(posedge clk80) begin
      if (t80 != 0) p80 = ($realtime - t80) * 1000.0;
      t80 = $realtime;
   end
   always @(posedge clk100) begin
      if (t100 != 0) p100 = ($realtime - t100) * 1000.0;
      t100 = $realtime;
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

      $display("  locked=%b/%b  periods %0d ps / %0d ps", locked80, locked100, p80, p100);

      check(locked80 === 1'b1 && locked100 === 1'b1, "both MMCMs report LOCKED");
      check(p100 == 10000,                           "the default plan gives 10 ns (100 MHz)");
      check(p80 == 12500,                            "BUS_DIVIDE 15 gives 12.5 ns (80 MHz)");

      if (errors == 0) $display("PASS: b200_clk_gen clock plans (3 checks)");
      else             $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #5000;
      $display("FAIL: timeout waiting for clocks");
      $finish;
   end

endmodule
