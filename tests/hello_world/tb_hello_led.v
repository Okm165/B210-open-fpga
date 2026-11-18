// Self-checking bench for hello_led_core, using WIDTH=4 so a full period
// is 16 clocks instead of 16 million.
`timescale 1ns/1ps

module tb_hello_led;

   reg  clk = 0;
   reg  rst = 1;
   wire led;
   wire tick;

   integer errors = 0;
   integer cyc = 0;

   always #5 clk = ~clk;

   hello_led_core #(.WIDTH(4)) dut (
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
         @(negedge clk);                 // let the counter settle

         case (cyc)
           7:  check(led === 1'b0,            "led low at count 7");
           8:  check(led === 1'b1 && tick === 1'b0, "led rises at count 8");
           15: check(led === 1'b1 && tick === 1'b1, "led high and tick at count 15");
           16: check(led === 1'b0 && tick === 1'b0, "counter wraps at 16");
           24: check(led === 1'b1,            "led rises again one period later");
           31: check(tick === 1'b1,           "tick recurs every 16 counts");
           32: begin
               if (errors == 0) $display("PASS: hello_led heartbeat (7 checks, 32 cycles)");
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
