// tb_hbdec_netlist - the receive halfband decimators against the vendor cores.
//
// hbdec1 and hbdec2 (src/rtl/dsp/) replace two Xilinx FIR Compiler cores.
// Upstream ships those cores as gate-level Verilog netlists
// (fpga/usrp3/top/b200/coregen_dsp/hbdec1.v, hbdec2.v in a UHD checkout).
// With the cell models of tests/sim/spartan6_prim_sim.v Icarus simulates the
// netlists themselves, and this bench runs each next to its replacement on
// the same inputs:
//
//   every clock        data_valid, rdy and rfd must be equal
//   every valid output both 47-bit paths must be equal
//
// under random data with full-scale words mixed in, periodic, random and
// too-fast sample spacings, ce gaps and sclr pulses.
//
// The netlists are Xilinx's and are not kept in this repository, so this
// bench is not part of `make test`; run `make test-dsp-netlist UHD_FPGA=<uhd>/fpga`.
// tests/mk_ettus_ref.py --netlists prefixes their module names with `ettus_`.
`timescale 1ns/1ps

module hbdec_netlist_check #(
   parameter integer WHICH = 1,        // 1: hbdec1, 2: hbdec2
   parameter integer MINP  = 1,        // clocks per sample the core is built for
   parameter integer NCYC  = 150000,
   parameter integer SEED0 = 1
) (
   input  wire clk,
   output reg  done = 1'b0,
   output reg  ok   = 1'b0
);
   reg         sclr = 1'b0, ce = 1'b1, nd = 1'b0;
   reg  [23:0] din1 = 24'd0, din2 = 24'd0;
   wire        rfd_n, rdy_n, dv_n, rfd_m, rdy_m, dv_m;
   wire [46:0] d1_n, d2_n, d1_m, d2_m;

   generate
      if (WHICH == 1) begin : g1
         ettus_hbdec1 net (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                           .rfd(rfd_n), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy_n), .data_valid(dv_n),
                           .dout_1(d1_n), .dout_2(d2_n));
         hbdec1 dut (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                     .rfd(rfd_m), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy_m), .data_valid(dv_m),
                     .dout_1(d1_m), .dout_2(d2_m));
      end else begin : g2
         ettus_hbdec2 net (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                           .rfd(rfd_n), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy_n), .data_valid(dv_n),
                           .dout_1(d1_n), .dout_2(d2_n));
         hbdec2 dut (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                     .rfd(rfd_m), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy_m), .data_valid(dv_m),
                     .dout_1(d1_m), .dout_2(d2_m));
      end
   endgenerate

   integer errs = 0, nvalid = 0, nsclr = 0;
   always @(posedge clk) begin
      if (dv_n !== dv_m || rdy_n !== rdy_m || rfd_n !== rfd_m) begin
         errs = errs + 1;
         if (errs < 10) $display("hbdec%0d: handshake differs at %0t: dv %b/%b rdy %b/%b rfd %b/%b (netlist/replacement)",
                                 WHICH, $time, dv_n, dv_m, rdy_n, rdy_m, rfd_n, rfd_m);
      end
      if (dv_n === 1'b1) begin
         nvalid = nvalid + 1;
         if (d1_n !== d1_m || d2_n !== d2_m) begin
            errs = errs + 1;
            if (errs < 10) $display("hbdec%0d: output differs at %0t: %0d/%0d  %0d/%0d (netlist/replacement)",
                                    WHICH, $time, $signed(d1_n), $signed(d1_m), $signed(d2_n), $signed(d2_m));
         end
      end
   end

   integer seed, cyc, mode, period, cnt;
   reg     sclr_q = 1'b0;
   initial begin
      seed = SEED0; mode = 0; period = MINP; cnt = 0;
      for (cyc = 0; cyc < NCYC; cyc = cyc + 1) begin
         if (($random(seed) & 1023) == 0) begin
            mode = ($random(seed) >> 4) & 3;
            period = MINP + (($random(seed) >> 4) & 7);
            if ((($random(seed) >> 4) & 3) == 0) period = MINP;
         end
         case (mode)
           0, 1: begin cnt = (cnt + 1 >= period) ? 0 : cnt + 1; nd = (cnt == 0); end
           2: begin
              if (cnt > 0) begin cnt = cnt - 1; nd = 1'b0; end
              else begin nd = (($random(seed) >> 4) & 3) == 0; if (nd) cnt = MINP - 1; end
           end
           default: nd = ($random(seed) >> 4) & 1;       // faster than the core accepts
         endcase
         din1 = $random(seed); din2 = $random(seed);
         if ((($random(seed) >> 3) & 63) == 0) begin din1 = 24'h7fffff; din2 = 24'h800000; end
         ce   = !((($random(seed) >> 5) & 255) < 6);
         sclr = ((($random(seed) >> 5) & 4095) == 0) || (sclr && (($random(seed) >> 5) & 1));
         if (sclr && !sclr_q) nsclr = nsclr + 1;
         sclr_q = sclr;
         @(negedge clk);
      end
      ok = (errs == 0) && (nvalid > NCYC / 16) && (nsclr > 10);
      $display("hbdec%0d: %0d clocks, %0d valid outputs compared with the vendor netlist across %0d resets, %0d errors",
               WHICH, NCYC, nvalid, nsclr, errs);
      done = 1'b1;
   end
endmodule

module tb_hbdec_netlist;
   reg clk = 1'b0;
   always #5 clk = ~clk;

   wire done1, ok1, done2, ok2;
   hbdec_netlist_check #(.WHICH(1), .MINP(1), .SEED0(32'h0b210011)) c1 (.clk(clk), .done(done1), .ok(ok1));
   hbdec_netlist_check #(.WHICH(2), .MINP(2), .SEED0(32'h0b210012)) c2 (.clk(clk), .done(done2), .ok(ok2));

   initial begin
      wait (done1 && done2);
      if (ok1 && ok2) $display("PASS: hbdec1 and hbdec2 are cycle- and bit-identical to the Xilinx FIR Compiler netlists");
      else            $display("FAIL: halfband decimators differ from the Xilinx FIR Compiler netlists");
      $finish;
   end
endmodule
