// tb_yosys_dsp_signext - each module of yosys_dsp_signext.v against the
// netlist yosys makes of it (modules <name>_syn, written by tests/postsyn.sh).
//
// Same clock, same operands, the 36-bit products compared on every clock.
// The bench does not judge: it reports, per module, how many products
// differ.  tests/check_dsp_packing.py puts that next to what yosys' `check`
// said about the same netlist.
`timescale 1ns/1ps

module signext_compare #(parameter integer WHICH = 0) (input wire clk, output reg done = 1'b0);
   reg               rst = 1'b1, en = 1'b1;
   reg signed [16:0] a = 17'sd0;
   reg signed [17:0] b = 18'sd0;
   wire signed [35:0] p_rtl, p_syn;

   generate
      if (WHICH == 0) begin : g
         signext_plain     rtl (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_rtl));
         signext_plain_syn syn (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_syn));
      end else if (WHICH == 1) begin : g
         signext_rst       rtl (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_rtl));
         signext_rst_syn   syn (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_syn));
      end else begin : g
         signext_en        rtl (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_rtl));
         signext_en_syn    syn (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .p(p_syn));
      end
   endgenerate

   integer k, n = 0, bad = 0, seed;
   reg signed [16:0] a1, a2;
   reg signed [17:0] b1, b2;
   always @(posedge clk) begin
      a1 <= a; a2 <= a1; b1 <= b; b2 <= b1;
      if (!rst && (^p_rtl) !== 1'bx) begin
         n = n + 1;
         if (p_rtl !== p_syn) begin
            bad = bad + 1;
            if (bad <= 2)
              $display("  %0s: %0d * %0d = %0d in RTL (%h), %0d in the netlist (%h)",
                       (WHICH == 0) ? "signext_plain" : (WHICH == 1) ? "signext_rst" : "signext_en",
                       a2, b2, p_rtl, p_rtl, p_syn, p_syn);
         end
      end
   end

   initial begin
      seed = 32'h51610 + WHICH;
      repeat (4) @(negedge clk);
      rst = 1'b0;
      for (k = 0; k < 2000; k = k + 1) begin
         case (k)
           0: begin a =  17'sd3; b =  18'sd5; end
           1: begin a = -17'sd3; b =  18'sd5; end
           2: begin a =  17'sd3; b = -18'sd5; end
           3: begin a = -17'sd3; b = -18'sd5; end
           default: begin a = $random(seed); b = $random(seed); end
         endcase
         @(negedge clk);
      end
      repeat (4) @(negedge clk);
      $display("SIGNEXT %0s: %0d products compared, %0d differ",
               (WHICH == 0) ? "signext_plain" : (WHICH == 1) ? "signext_rst" : "signext_en", n, bad);
      done = 1'b1;
   end
endmodule

module tb_yosys_dsp_signext;
   reg clk = 1'b0;
   always #5 clk = ~clk;
   wire d0, d1, d2;
   signext_compare #(.WHICH(0)) c0 (.clk(clk), .done(d0));
   signext_compare #(.WHICH(1)) c1 (.clk(clk), .done(d1));
   signext_compare #(.WHICH(2)) c2 (.clk(clk), .done(d2));
   initial begin
      wait (d0 && d1 && d2);
      $finish;
   end
endmodule
