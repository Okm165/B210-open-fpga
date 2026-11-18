`timescale 1ns/1ps
// The oscillator must satisfy sin(t) == cos(t - 90 degrees) on every phase
// word.  Both sides read the same ROM entry through the same mirroring, so the
// identity is required to hold bit-exactly; it fails if either path uses the
// wrong interpolation fraction in the mirrored quadrants (a real bug: the sine
// path used the un-mirrored fraction, producing a sawtooth error of up to one
// table step over half the circle).
module tb_dds_lut;
   reg clk = 0, rst = 1;
   reg [31:0] phase = 0;
   wire signed [17:0] sin_out, cos_out;
   always #5 clk = ~clk;

   dds_lut #(.WIDTH(24)) dut
     (.clk(clk), .rst(rst), .phase(phase), .sin_out(sin_out), .cos_out(cos_out));

   integer errors = 0, checks = 0, i;
   reg signed [17:0] s_q, c_q;

   // one phase word per cycle, compare the registered outputs one cycle later
   reg signed [17:0] s_d = 0, c_d = 0;
   always @(posedge clk) begin
      s_d <= sin_out;
      c_d <= cos_out;
   end

   reg signed [17:0] s_cap, c_cap;
   task check_pair(input [31:0] p);
      begin
         @(negedge clk); phase = p;
         @(posedge clk); #1; s_cap = sin_out;      // sin(p)
         @(negedge clk); phase = p - 32'h4000_0000;
         @(posedge clk); #1; c_cap = cos_out;      // cos(p - 90 deg)
         checks = checks + 1;
         if (s_cap !== c_cap) begin
            errors = errors + 1;
            if (errors < 5)
              $display("FAIL: sin(%08x)=%0d but cos(%08x)=%0d",
                       p, s_cap, p - 32'h4000_0000, c_cap);
         end
      end
   endtask

   initial begin
      repeat(4) @(posedge clk);
      rst <= 0;
      repeat(2) @(posedge clk);
      // sweep all quadrants, including both sides of every table knot region
      for (i = 0; i < 4096; i = i + 1)
        check_pair(32'h0000_0000 + i * 32'h0010_0001);
      for (i = 0; i < 1024; i = i + 1)
        check_pair(32'h3000_0000 + i * 32'h0001_0003);
      if (errors == 0)
        $display("PASS: dds_lut sin(t) == cos(t-90deg) bit-exactly (%0d checks)", checks);
      else
        $display("FAIL: %0d of %0d checks", errors, checks);
      $finish;
   end
endmodule
