// Post-synthesis check of hello_led_core.
//
// Same cycle-exact expectations as tests/hello_world/tb_hello_led.v, but the
// device under test is the *netlist Yosys produced*, simulated with Yosys's
// simcells.v gate models.  The RTL bench proves the source is right; this one
// proves synthesis preserved it.  F26 showed the two can diverge: a tool that
// accepts ambiguous RTL may compile something the source does not say, and no
// amount of RTL simulation will see it.
//
// The Makefile synthesises hello_led_core (WIDTH=4, so a full period is 16
// clocks) with plain `synth` - no Xilinx primitives - and writes
// hello_postsynth.v next to this bench.
`timescale 1ns/1ps

module tb_hello_led_postsynth;

   reg  clk = 0;
   reg  rst = 1;
   wire led;
   wire tick;

   integer errors = 0;
   integer cyc = 0;

   always #5 clk = ~clk;

   hello_led_core dut (
      .clk  (clk),
      .rst  (rst),
      .led  (led),
      .tick (tick)
   );

   task check(input cond, input [8*64-1:0] what);
      begin
         if (!cond) begin
            errors = errors + 1;
            $display("FAIL at cycle %0d: %0s", cyc, what);
         end
      end
   endtask

   initial begin
      repeat (2) @(posedge clk);
      @(negedge clk) rst = 0;

      forever begin
         @(posedge clk);
         cyc <= cyc + 1;
         @(negedge clk);

         case (cyc)
           7:  check(led === 1'b0,            "led low at count 7");
           8:  check(led === 1'b1 && tick === 1'b0, "led rises at count 8");
           15: check(led === 1'b1 && tick === 1'b1, "led high and tick at count 15");
           16: check(led === 1'b0 && tick === 1'b0, "counter wraps at 16");
           24: check(led === 1'b1,            "led rises again one period later");
           31: check(tick === 1'b1,           "tick recurs every 16 counts");
           32: begin
               if (errors == 0) $display("PASS: post-synthesis netlist matches RTL (7 checks, 32 cycles)");
               else             $display("FAIL: %0d errors", errors);
               $finish;
            end
           64: begin
               $display("FAIL: timeout");
               $finish;
            end
         endcase
      end
   end

endmodule
