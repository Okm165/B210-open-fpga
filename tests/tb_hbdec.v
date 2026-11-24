// tb_hbdec - the receive halfband decimators against their definition.
//
// hbdec1 and hbdec2 (src/rtl/dsp/) replace the two Xilinx FIR Compiler cores
// of the stock B200 receive chain.  This bench checks them against a model
// that shares nothing with the RTL: the 47 coefficients of hb47.coe written
// out in full, a history of the accepted samples, and one 64-bit sum per
// output.  The handshake contract the model follows is the one measured on
// the vendor netlists (see hbdec47.v; the netlists themselves are compared in
// tb_hbdec_netlist.v when they are available):
//
//   output every second accepted sample, LATENCY enabled clocks later;
//   data_valid low for the first 23 outputs after sclr, rdy high for all;
//   sclr drops what is in the pipeline; ce = 0 freezes; hbdec2 refuses a
//   sample in the clock after one it took.
//
// Every clock: data_valid, rdy and rfd must equal the model's.  Every valid
// output: both 47-bit paths must equal the model's sum exactly.  The stimulus
// is random data with full-scale words mixed in, at periodic, random and
// too-fast sample spacings, with ce gaps and sclr pulses, plus one directed
// block that drives the largest sum the coefficients allow.
//
// -DPOSTSYN: the devices under test are not the RTL but the netlists yosys
// makes of hbdec1 and hbdec2 with the build's flags (modules hbdec1_syn and
// hbdec2_syn).  All 47 output bits are compared here; the receive chain only
// reads bits [41:18], so a synthesis fault in the top bits - which is where
// a lost sign extension shows - is invisible in the chain benches and visible
// in this one.  +NCYC=<n> sets the length of the random part.
`timescale 1ns/1ps

`ifdef POSTSYN
 `define HBDEC1 hbdec1_syn
 `define HBDEC2 hbdec2_syn
 `define DUT_NAME "the yosys netlists of hbdec1 and hbdec2"
`else
 `define HBDEC1 hbdec1
 `define HBDEC2 hbdec2
 `define DUT_NAME "hbdec1 and hbdec2"
`endif

module hbdec_check #(
   parameter integer WHICH   = 1,      // 1: hbdec1, 2: hbdec2
   parameter integer LATENCY = 22,
   parameter integer MINP    = 1,      // clocks per sample the core is built for
   parameter integer SEED0   = 1
) (
   input  wire clk,
   output reg  done = 1'b0,
   output reg  ok   = 1'b0
);
   reg         sclr = 1'b0, ce = 1'b1, nd = 1'b0;
   reg  [23:0] din1 = 24'd0, din2 = 24'd0;
   wire        rfd, rdy, dv;
   wire [46:0] d1, d2;

   generate
      if (WHICH == 1) begin : g1
         `HBDEC1 dut (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                     .rfd(rfd), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy), .data_valid(dv),
                     .dout_1(d1), .dout_2(d2));
      end else begin : g2
         `HBDEC2 dut (.clk(clk), .sclr(sclr), .ce(ce), .coef_ld(1'b0), .coef_we(1'b0), .coef_din(18'd0),
                     .rfd(rfd), .nd(nd), .din_1(din1), .din_2(din2), .rdy(rdy), .data_valid(dv),
                     .dout_1(d1), .dout_2(d2));
      end
   endgenerate

   // hb47.coe, all 47 taps (fpga/usrp3/top/b200/coregen_dsp/hb47.coe upstream)
   function integer h;
      input integer k;
      case (k)
        0, 46:  h = -62;       2, 44:  h = 194;      4, 42:  h = -440;
        6, 40:  h = 855;       8, 38:  h = -1505;    10, 36: h = 2478;
        12, 34: h = -3900;     14, 32: h = 5990;     16, 30: h = -9187;
        18, 28: h = 14632;     20, 26: h = -26536;   22, 24: h = 83009;
        23:     h = 131071;
        default: h = 0;
      endcase
   endfunction

   // ------------------------------------------------------------- the model ---
   reg signed [23:0] x1 [0:63], x2 [0:63];      // accepted samples, circular
   integer           wr = 0;                    // next write position
   reg               m_second = 1'b0, m_hold = 1'b0;
   integer           m_flush = 0;
   integer           tick = 0;                  // enabled clocks
   // outputs on their way: due tick, visible or suppressed, both sums
   integer           q_due [0:63];
   reg               q_vis [0:63];
   reg signed [63:0] q_y1 [0:63], q_y2 [0:63];
   integer           q_rd = 0, q_wr = 0;
   reg               m_dv = 1'b0, m_rdy = 1'b0;
   reg signed [63:0] m_y1 = 64'sd0, m_y2 = 64'sd0;

   integer errs = 0, nvalid = 0, nflush = 0, k;
   reg signed [63:0] y1, y2, peak;
   reg               take;
   initial peak = 64'sd0;

   function signed [63:0] mag(input signed [63:0] v);
      mag = (v < 0) ? -v : v;
   endfunction

   always @(posedge clk) begin
      // what the dut shows now is what the model decided at the last edge
      if (dv !== m_dv || rdy !== m_rdy || rfd !== ((MINP == 2) ? ~m_hold : 1'b1)) begin
         errs = errs + 1;
         if (errs < 10) $display("hbdec%0d: handshake differs at %0t: dv %b/%b rdy %b/%b rfd %b (dut/model)",
                                 WHICH, $time, dv, m_dv, rdy, m_rdy, rfd);
      end
      if (m_dv) begin
         nvalid = nvalid + 1;
         if (mag(m_y1) > peak) peak = mag(m_y1);
         if ($signed(d1) !== m_y1[46:0] || $signed(d2) !== m_y2[46:0] ||
             m_y1 !== {{17{d1[46]}}, d1} || m_y2 !== {{17{d2[46]}}, d2}) begin
            errs = errs + 1;
            if (errs < 10) $display("hbdec%0d: output differs at %0t: %0d/%0d  %0d/%0d (dut/model)",
                                    WHICH, $time, $signed(d1), m_y1, $signed(d2), m_y2);
         end
      end

      // this edge
      if (sclr) begin
         m_second = 1'b0; m_hold = 1'b0; m_flush = 0;
         q_rd = q_wr; m_dv = 1'b0; m_rdy = 1'b0;
      end else if (ce) begin
         tick = tick + 1;
         take = nd & ~((MINP == 2) & m_hold);
         m_hold = take;
         m_dv = 1'b0; m_rdy = 1'b0;
         if (q_rd != q_wr && q_due[q_rd] == tick) begin
            m_rdy = 1'b1; m_dv = q_vis[q_rd];
            m_y1 = q_y1[q_rd]; m_y2 = q_y2[q_rd];
            q_rd = (q_rd + 1) % 64;
         end
         if (take) begin
            x1[wr] = din1; x2[wr] = din2;
            if (m_second) begin
               y1 = 64'sd0; y2 = 64'sd0;
               for (k = 0; k < 47; k = k + 1) begin
                  y1 = y1 + h(k) * x1[(wr + 64 - k) % 64];
                  y2 = y2 + h(k) * x2[(wr + 64 - k) % 64];
               end
               q_due[q_wr] = tick + LATENCY; q_vis[q_wr] = (m_flush == 23);
               q_y1[q_wr] = y1; q_y2[q_wr] = y2;
               q_wr = (q_wr + 1) % 64;
               if (m_flush != 23) begin m_flush = m_flush + 1; nflush = nflush + 1; end
            end
            m_second = ~m_second;
            wr = (wr + 1) % 64;
         end
      end
   end

   // -------------------------------------------------------------- stimulus ---
   integer seed, cyc, mode, period, cnt, j, NCYC;
   initial begin
      if (!$value$plusargs("NCYC=%d", NCYC)) NCYC = 120000;
      seed = SEED0; mode = 0; period = MINP; cnt = 0;
      for (j = 0; j < 64; j = j + 1) begin x1[j] = 24'sd0; x2[j] = 24'sd0; end

      // Directed: the largest sum.  After a reset and its 23 suppressed
      // outputs, 47 samples whose signs follow the coefficients of the
      // output they complete (sample i meets tap 46 - i).
      @(negedge clk); sclr = 1'b1; @(negedge clk); sclr = 1'b0;
      for (j = 0; j < 46; j = j + 1) begin          // pairs 0..22: suppressed
         nd = 1'b1; din1 = 24'd0; din2 = 24'd0; @(negedge clk);
         nd = 1'b0; repeat (MINP - 1) @(negedge clk);
      end
      for (j = 0; j < 48; j = j + 1) begin          // 47 taps, completing on an odd sample
         nd = 1'b1;
         din1 = (j == 0) ? 24'd0 : (h(47 - j) < 0) ? 24'h800000 : 24'h7fffff;
         din2 = (j == 0) ? 24'd0 : (h(47 - j) < 0) ? 24'h7fffff : 24'h800000;
         @(negedge clk);
         nd = 1'b0; repeat (MINP - 1) @(negedge clk);
      end
      repeat (LATENCY + 4) @(negedge clk);

      // Random.
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
         if (cyc == NCYC / 2) sclr = 1'b1;          // at least one reset in mid-stream, however short the run
         @(negedge clk);
      end
      nd = 1'b0; ce = 1'b1; sclr = 1'b0;
      repeat (LATENCY + 4) @(negedge clk);

      // 428647 is the sum of |h|; the directed block must have reached it.
      ok = (errs == 0) && (nvalid > NCYC / 16) && (nflush > 23) &&
           (peak >= 64'sd428647 * 64'sd8388607);
      $display("hbdec%0d: %0d valid outputs and %0d suppressed ones checked, %0d errors, largest |sum| %0d (limit %0d)",
               WHICH, nvalid, nflush, errs, peak, 64'sd428647 * 64'sd8388608);
      done = 1'b1;
   end
endmodule

module tb_hbdec;
   reg clk = 1'b0;
   always #5 clk = ~clk;

   wire done1, ok1, done2, ok2;
   hbdec_check #(.WHICH(1), .LATENCY(22), .MINP(1), .SEED0(32'h0b210001)) c1 (.clk(clk), .done(done1), .ok(ok1));
   hbdec_check #(.WHICH(2), .LATENCY(21), .MINP(2), .SEED0(32'h0b210002)) c2 (.clk(clk), .done(done2), .ok(ok2));

   initial begin
      wait (done1 && done2);
      if (ok1 && ok2) $display("PASS: %0s equal the 47-tap halfband sum on every output, with the vendor cores' handshake", `DUT_NAME);
      else            $display("FAIL: %0s differ from the 47-tap halfband sum", `DUT_NAME);
      $finish;
   end
endmodule
