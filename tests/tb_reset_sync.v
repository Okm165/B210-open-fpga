//
// reset_sync: the reset that gates every flop in both radios.
//
// It is a 10-stage synchroniser with INITIAL_VAL=1 followed by an output
// register, and its result now reaches the radios through a BUFG (F27).  Two
// properties matter and neither was tested:
//
//   1. power-up asserts the reset without waiting for a clock edge sequence -
//      the stages initialise to 1, so downstream logic starts in reset;
//   2. deassertion is *deliberately slow*: the release has to travel through
//      ten stages, which lets the clock settle and the reset reach every
//      flop before anything runs.  A "faster" reset is a regression, not an
//      optimisation.
//
`timescale 1ns/1ps

module tb_reset_sync;

   localparam STAGES = 10;

   reg  clk = 0;
   reg  reset_in = 1;
   integer cycles_to_release;
   integer cycles_to_assert;
   integer errors = 0;

   wire reset_out;

   always #5 clk = ~clk;

   reset_sync dut (.clk(clk), .reset_in(reset_in), .reset_out(reset_out));

   initial begin
      // ---- power-up: reset asserted without any help from reset_in ---------
      // The ten synchroniser stages initialise to 1 (INITIAL_VAL), but the
      // final output register has no initial value, so reset_out reads x for
      // the first simulation cycle and 0 for the first cycle in silicon.  That
      // is harmless: reset_in is !clocks_ready, so no radio clock edge exists
      // until the MMCM locks, long after the stages are 1.  The first edge is
      // what matters, and it must load 1.
      @(posedge clk); #1;
      if (reset_out !== 1'b1) begin
         errors = errors + 1;
         $display("FAIL: reset_out is not asserted after the first clock");
      end

      repeat (20) @(posedge clk);
      if (reset_out !== 1'b1) begin
         errors = errors + 1;
         $display("FAIL: reset_out deasserted while reset_in is high");
      end

      // ---- release: must take at least STAGES clocks -----------------------
      @(negedge clk);
      reset_in = 1'b0;
      cycles_to_release = 0;
      while (reset_out === 1'b1 && cycles_to_release <= 40) begin
         @(posedge clk); #1;
         cycles_to_release = cycles_to_release + 1;
      end
      if (reset_out === 1'b1) begin
         errors = errors + 1;
         $display("FAIL: reset_out never released");
      end else if (cycles_to_release < STAGES) begin
         errors = errors + 1;
         $display("FAIL: reset released after %0d cycles, expected at least %0d",
                  cycles_to_release, STAGES);
      end

      repeat (5) @(posedge clk);
      if (reset_out !== 1'b0) begin
         errors = errors + 1;
         $display("FAIL: reset_out re-asserted with reset_in low");
      end

      // ---- re-assertion goes through the same chain ------------------------
      @(negedge clk);
      reset_in = 1'b1;
      cycles_to_assert = 0;
      while (reset_out === 1'b0 && cycles_to_assert <= 40) begin
         @(posedge clk); #1;
         cycles_to_assert = cycles_to_assert + 1;
      end
      if (reset_out === 1'b0) begin
         errors = errors + 1;
         $display("FAIL: reset_out never asserted again");
      end else if (cycles_to_assert < STAGES) begin
         errors = errors + 1;
         $display("FAIL: reset asserted after only %0d cycles, expected %0d",
                  cycles_to_assert, STAGES);
      end

      if (errors == 0)
         $display("PASS: reset_sync asserts at power-up, releases after %0d cycles, re-asserts in %0d",
                  cycles_to_release, cycles_to_assert);
      else
         $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #100000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
