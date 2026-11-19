// tb_roundtrip.v - TX -> RX digital loopback: are the two datapaths symmetric?
//
// Every other bench tests one direction.  The symmetry claim ("both sides share
// one NCO, one mixer convention, one gain") is only directly testable by
// putting the transmit chain's 24-bit output into the receive chain's 24-bit
// input and measuring the round trip:
//
//   host 16-bit  -> duc_chain (bypass, LO 0, scale 0x8000) -> 24-bit
//                -> ddc_chain (LO 0, unit scale)          -> host 16-bit
//
// In bypass the TX gain is x256 (in16 << 8) and the RX gain is 1/256
// (24-bit >> 8 at the output quantiser), so the round trip must be 1.00000.
//
// A complex tone I=cos, Q=sin is e^{+j theta}.  A single-bin DFT at the
// reference e^{-j theta} measures the gain; the same DFT at e^{+j theta}
// measures the energy at the *mirror* frequency, which is zero for a correct
// path and is the whole signal for a conjugated path (Q = -sin).  So one
// complex correlation separates three failure classes:
//
//   * gain error            -> |C_pos| != A
//   * I/Q imbalance / skew  -> |C_neg| != 0      (reported as image rejection)
//   * conjugate / I-Q swap  -> |C_neg| >> |C_pos|
`timescale 1ns/1ps

module tb_roundtrip;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   // ---------------- RX ----------------
   reg        r_stb = 0;
   reg  [7:0] r_addr = 0;
   reg [31:0] r_data = 0;
   wire [31:0] rx_sample;
   wire        rx_strobe;

   // TX output feeds RX input
   wire [23:0] tx_i, tx_q;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r_stb), .set_addr(r_addr), .set_data(r_data),
      .rx_fe_i(tx_i), .rx_fe_q(tx_q),
      .sample(rx_sample), .run(1'b1), .strobe(rx_strobe), .debug());

   // ---------------- TX ----------------
   reg        t_stb = 0;
   reg  [7:0] t_addr = 0;
   reg [31:0] t_data = 0;
   reg [31:0] tx_sample = 0;
   reg        tx_run = 1;
   wire        tx_strobe;
   wire [31:0] tx_debug;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t_stb), .set_addr(t_addr), .set_data(t_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
      .sample(tx_sample), .run(tx_run), .strobe(tx_strobe), .debug(tx_debug));

   task rwr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); r_stb = 1; r_addr = a; r_data = d;
         @(negedge clk); r_stb = 0;
      end
   endtask
   task twr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); t_stb = 1; t_addr = a; t_data = d;
         @(negedge clk); t_stb = 0;
      end
   endtask

   // ---------------- stimulus generator ----------------
   // mode 0: DC (I = amp, Q = 0); mode 1: complex tone e^{+j 2 pi pidx/Nper}
   integer mode = 0;
   integer Nper = 64;
   integer amp  = 1000;
   integer pidx = 0;
   real    ang;
   always @(negedge clk) begin
      if (mode == 0) begin
         tx_sample[31:16] <= amp[15:0];
         tx_sample[15:0]  <= 16'd0;
      end else begin
         ang = 2.0 * 3.14159265358979323846 * pidx / Nper;
         tx_sample[31:16] <= $rtoi(amp * $cos(ang));
         tx_sample[15:0]  <= $rtoi(amp * $sin(ang));
         pidx <= (pidx == Nper-1) ? 0 : pidx + 1;
      end
   end

   // ---------------- measurement ----------------
   integer L, m, errors;
   real cre, cim, nre, nim, th, ci, cq, gpos, gneg, gin, rej_db, gain_db;
   real sum_i, sum_q;

   // capture L clocks and correlate against e^{-j th} (pos) and e^{+j th} (neg)
   // Correlate both the driven input word and the RX output word against the
   // same reference.  The stimulus generator truncates (rtoi toward zero), so
   // its own amplitude is a fraction of a count low; taking out/in cancels the
   // generator and measures the datapath only.
   task measure_tone(input integer N, output real gp_o, output real gn_o,
                     output real gp_i);
      integer k;
      real a_, b_, c_, d_, ai_, bi_;
      real ri, rq;
      begin
         L = 16 * N;
         a_ = 0.0; b_ = 0.0; c_ = 0.0; d_ = 0.0; ai_ = 0.0; bi_ = 0.0;
         for (k = 0; k < L; k = k + 1) begin
            @(posedge clk); #1;
            ci = $itor($signed(rx_sample[31:16]));
            cq = $itor($signed(rx_sample[15:0]));
            ri = $itor($signed(tx_sample[31:16]));
            rq = $itor($signed(tx_sample[15:0]));
            th = 2.0 * 3.14159265358979323846 * k / N;
            a_  = a_  + ci*$cos(th) + cq*$sin(th);   // Re C_pos, output
            b_  = b_  + cq*$cos(th) - ci*$sin(th);   // Im C_pos, output
            c_  = c_  + ci*$cos(th) - cq*$sin(th);   // Re C_neg, output
            d_  = d_  + cq*$cos(th) + ci*$sin(th);   // Im C_neg, output
            ai_ = ai_ + ri*$cos(th) + rq*$sin(th);   // Re C_pos, input
            bi_ = bi_ + rq*$cos(th) - ri*$sin(th);   // Im C_pos, input
         end
         gp_o = $sqrt(a_*a_ + b_*b_) / L;
         gn_o = $sqrt(c_*c_ + d_*d_) / L;
         gp_i = $sqrt(ai_*ai_ + bi_*bi_) / L;
      end
   endtask

   task measure_dc(output real mi, output real mq);
      integer k;
      real a_, b_;
      begin
         a_ = 0.0; b_ = 0.0;
         for (k = 0; k < 1024; k = k + 1) begin
            @(posedge clk); #1;
            a_ = a_ + $itor($signed(rx_sample[31:16]));
            b_ = b_ + $itor($signed(rx_sample[15:0]));
         end
         mi = a_ / 1024.0;
         mq = b_ / 1024.0;
      end
   endtask

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;

      // TX: LO at DC, scale unity, interpolation bypass (no halfbands, rate 1)
      twr(8'd0, 32'd0);
      twr(8'd1, 32'h0000_8000);
      twr(8'd2, 32'd1);
      // RX: LO at DC
      rwr(8'd0, 32'd0);
      rwr(8'd3, 32'd0);

      // ---- case 1: DC, I = 1000, Q = 0 ----
      mode = 0; amp = 1000;
      repeat (400) @(posedge clk);
      measure_dc(sum_i, sum_q);
      $display("ROUNDTRIP: DC   I %.3f Q %.3f (expect 1000, 0)", sum_i, sum_q);
      if (sum_i < 999.0 || sum_i > 1001.0 || sum_q < -1.0 || sum_q > 1.0) begin
         errors = errors + 1;
         $display("ROUNDTRIP: FAIL - DC gain or I/Q isolation wrong");
      end

      // ---- case 2: complex tone at fs/64 ----
      mode = 1; Nper = 64; amp = 1000; pidx = 0;
      repeat (400) @(posedge clk);
      measure_tone(64, gpos, gneg, gin);
      gain_db = 20.0*$log10(gpos/gin);
      rej_db  = (gneg < 1.0e-9) ? -180.0 : 20.0*$log10(gneg/gpos);
      $display("ROUNDTRIP: fs/64 out/in %.6f (%.5f dB) mirror %.3f dB (in %.3f, out %.3f)",
               gpos/gin, gain_db, rej_db, gin, gpos);
      if (gain_db < -0.01 || gain_db > 0.01) begin
         errors = errors + 1;
         $display("ROUNDTRIP: FAIL - tone gain outside +-0.01 dB");
      end
      if (rej_db > -60.0) begin
         errors = errors + 1;
         $display("ROUNDTRIP: FAIL - mirror energy %.1f dB (conjugate or I/Q imbalance)", rej_db);
      end

      // ---- case 3: complex tone at fs/16 ----
      mode = 1; Nper = 16; amp = 1000; pidx = 0;
      repeat (400) @(posedge clk);
      measure_tone(16, gpos, gneg, gin);
      gain_db = 20.0*$log10(gpos/gin);
      rej_db  = (gneg < 1.0e-9) ? -180.0 : 20.0*$log10(gneg/gpos);
      $display("ROUNDTRIP: fs/16 out/in %.6f (%.5f dB) mirror %.3f dB", gpos/gin, gain_db, rej_db);
      if (gain_db < -0.01 || gain_db > 0.01) begin
         errors = errors + 1;
         $display("ROUNDTRIP: FAIL - tone gain outside +-0.01 dB at fs/16");
      end
      if (rej_db > -60.0) begin
         errors = errors + 1;
         $display("ROUNDTRIP: FAIL - mirror energy at fs/16 (conjugate or I/Q imbalance)");
      end

      if (errors == 0)
         $display("ROUNDTRIP: PASS - TX->RX is transparent: unity gain, correct rotation, no conjugate, no I/Q leakage");
      else
         $display("ROUNDTRIP: FAIL - %0d checks wrong", errors);
      $finish;
   end

   // strobe sanity: in bypass the DUC must consume one host sample per clock
   integer stb_high = 0, stb_clocks = 0;
   always @(posedge clk) begin
      stb_clocks = stb_clocks + 1;
      if (tx_strobe) stb_high = stb_high + 1;
   end

endmodule
