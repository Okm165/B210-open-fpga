// tb_loopback2.v - two-channel, bidirectional digital loopback of the complete
// transmit and receive datapaths, at once.
//
// This is the closest software can get to "TX antenna -> air -> RX antenna":
// the transmit chain's 24-bit pin word is wired straight into the receive
// chain's 24-bit pin word, on both channels, while two different signals run
// simultaneously.  A second compile mode (-DREVERSE) wires the other way:
// the receive chain's 16-bit host word feeds the transmit chain's 16-bit host
// word, i.e. ADC -> RX -> TX -> DAC.
//
//   forward: host16 -> duc (bypass) -> 24b -> ddc (LO 0) -> host16
//            gain must be 1 (duc x256, ddc /256)
//   reverse: ADC24  -> ddc (LO 0)  -> host16 -> duc (bypass) -> 24b
//            gain must be 1 (ddc /256, duc x256)
//
// Per channel and per direction the bench measures, with one coherent complex
// DFT over 16 periods of the channel's tone:
//
//   gain      |C_pos| / |C_pos_in|           unity
//   mirror    |C_neg| / |C_pos|              conjugate / I-Q imbalance
//   EVM       sqrt((mean power - |C_pos|^2 - |C_neg|^2) / |C_pos|^2)
//                                            everything that is not the tone
//   crosstalk |DFT of channel 0 at channel 1's frequency| / |C_pos|0|
//
// The two channels use different frequencies (fs/64 and fs/16), so a shared
// resource or a wiring mistake shows up as energy at the wrong frequency.
// The air path itself (delay, Doppler, AWGN, antenna coupling) is not modelled:
// that is the hardware session's job, and faking it would measure the model.
`timescale 1ns/1ps

module tb_loopback2;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   // two TX chains
   reg        t0_stb = 0; reg [7:0] t0_addr = 0; reg [31:0] t0_data = 0;
   reg        t1_stb = 0; reg [7:0] t1_addr = 0; reg [31:0] t1_data = 0;
   wire [23:0] tx0_i, tx0_q, tx1_i, tx1_q;
   wire        tx0_strobe, tx1_strobe;
   wire [31:0] tx0_debug, tx1_debug;

   // two RX chains
   reg        r0_stb = 0; reg [7:0] r0_addr = 0; reg [31:0] r0_data = 0;
   reg        r1_stb = 0; reg [7:0] r1_addr = 0; reg [31:0] r1_data = 0;
   wire [31:0] rx0_sample, rx1_sample;
   wire        rx0_strobe, rx1_strobe;

`ifdef REVERSE
   // RX -> TX: the TX consumes the RX host word; the RX input is the stimulus.
   wire [31:0] tx0_sample = rx0_sample;
   wire [31:0] tx1_sample = rx1_sample;
   reg  [23:0] rx0_i, rx0_q, rx1_i, rx1_q;
`else
   // TX -> RX: the RX consumes the TX pin word; the TX input is the stimulus.
   reg  [31:0] tx0_sample;
   reg  [31:0] tx1_sample;
   wire [23:0] rx0_i = tx0_i;
   wire [23:0] rx0_q = tx0_q;
   wire [23:0] rx1_i = tx1_i;
   wire [23:0] rx1_q = tx1_q;
`endif

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx0 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r0_stb), .set_addr(r0_addr), .set_data(r0_data),
      .rx_fe_i(rx0_i), .rx_fe_q(rx0_q),
      .sample(rx0_sample), .run(1'b1), .strobe(rx0_strobe), .debug());

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx1 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r1_stb), .set_addr(r1_addr), .set_data(r1_data),
      .rx_fe_i(rx1_i), .rx_fe_q(rx1_q),
      .sample(rx1_sample), .run(1'b1), .strobe(rx1_strobe), .debug());

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx0 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t0_stb), .set_addr(t0_addr), .set_data(t0_data),
      .tx_fe_i(tx0_i), .tx_fe_q(tx0_q),
      .sample(tx0_sample), .run(1'b1), .strobe(tx0_strobe), .debug(tx0_debug));

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx1 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t1_stb), .set_addr(t1_addr), .set_data(t1_data),
      .tx_fe_i(tx1_i), .tx_fe_q(tx1_q),
      .sample(tx1_sample), .run(1'b1), .strobe(tx1_strobe), .debug(tx1_debug));

   // ---------------- register writes ----------------
   task twr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch == 0) begin t0_stb = 1; t0_addr = a; t0_data = d; end
         else         begin t1_stb = 1; t1_addr = a; t1_data = d; end
         @(negedge clk);
         t0_stb = 0; t1_stb = 0;
      end
   endtask
   task rwr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch == 0) begin r0_stb = 1; r0_addr = a; r0_data = d; end
         else         begin r1_stb = 1; r1_addr = a; r1_data = d; end
         @(negedge clk);
         r0_stb = 0; r1_stb = 0;
      end
   endtask

   // ---------------- stimulus ----------------
   // channel 0: fs/64, channel 1: fs/16; amplitudes chosen for ~ -12 dBFS
   integer N0 = 64, N1 = 16;
   integer amp16 = 8000;              // host-domain amplitude
   integer amp24 = 8000 * 256;        // ADC-domain amplitude (same level)
   integer p0 = 0, p1 = 0;
   real    a0, a1;

`ifndef REVERSE
   always @(negedge clk) begin
      a0 = 2.0 * 3.14159265358979323846 * p0 / N0;
      a1 = 2.0 * 3.14159265358979323846 * p1 / N1;
      tx0_sample[31:16] <= $rtoi(amp16 * $cos(a0));
      tx0_sample[15:0]  <= $rtoi(amp16 * $sin(a0));
      tx1_sample[31:16] <= $rtoi(amp16 * $cos(a1));
      tx1_sample[15:0]  <= $rtoi(amp16 * $sin(a1));
      p0 <= (p0 == N0-1) ? 0 : p0 + 1;
      p1 <= (p1 == N1-1) ? 0 : p1 + 1;
   end
`else
   always @(negedge clk) begin
      a0 = 2.0 * 3.14159265358979323846 * p0 / N0;
      a1 = 2.0 * 3.14159265358979323846 * p1 / N1;
      rx0_i <= $rtoi(amp24 * $cos(a0));
      rx0_q <= $rtoi(amp24 * $sin(a0));
      rx1_i <= $rtoi(amp24 * $cos(a1));
      rx1_q <= $rtoi(amp24 * $sin(a1));
      p0 <= (p0 == N0-1) ? 0 : p0 + 1;
      p1 <= (p1 == N1-1) ? 0 : p1 + 1;
   end
`endif

   // ---------------- measurement ----------------
   integer L, k, errors;
   real ci, cq, ri, rq, th;
   real ap, bp, an, bn, aip, bip, pw;
   real gin, gout, gout0, gmir, evm_db, xt_energy, xt_db, gain_db;
   real xt_re, xt_im;

   // one coherent DFT over 16 periods; `which` selects the channel
   task measure(input integer which, input integer N,
                output real g_in, output real g_out, output real g_mir,
                output real e_db);
      integer kk;
      real a_, b_, c_, d_, ai_, bi_, p_;
      begin
         L = 16 * N;
         a_ = 0.0; b_ = 0.0; c_ = 0.0; d_ = 0.0; ai_ = 0.0; bi_ = 0.0; p_ = 0.0;
         for (kk = 0; kk < L; kk = kk + 1) begin
            @(posedge clk); #1;
            if (which == 0) begin
`ifdef REVERSE
               ci = $itor($signed(tx0_i));  cq = $itor($signed(tx0_q));
               ri = $itor($signed(rx0_i));  rq = $itor($signed(rx0_q));
`else
               ci = $itor($signed(rx0_sample[31:16])); cq = $itor($signed(rx0_sample[15:0]));
               ri = $itor($signed(tx0_sample[31:16])); rq = $itor($signed(tx0_sample[15:0]));
`endif
            end else begin
`ifdef REVERSE
               ci = $itor($signed(tx1_i));  cq = $itor($signed(tx1_q));
               ri = $itor($signed(rx1_i));  rq = $itor($signed(rx1_q));
`else
               ci = $itor($signed(rx1_sample[31:16])); cq = $itor($signed(rx1_sample[15:0]));
               ri = $itor($signed(tx1_sample[31:16])); rq = $itor($signed(tx1_sample[15:0]));
`endif
            end
            th = 2.0 * 3.14159265358979323846 * kk / N;
            a_  = a_  + ci*$cos(th) + cq*$sin(th);   // Re C_pos, output
            b_  = b_  + cq*$cos(th) - ci*$sin(th);   // Im C_pos, output
            c_  = c_  + ci*$cos(th) - cq*$sin(th);   // Re C_neg, output
            d_  = d_  + cq*$cos(th) + ci*$sin(th);   // Im C_neg, output
            ai_ = ai_ + ri*$cos(th) + rq*$sin(th);   // Re C_pos, input
            bi_ = bi_ + rq*$cos(th) - ri*$sin(th);   // Im C_pos, input
            p_  = p_  + ci*ci + cq*cq;               // total power
         end
         g_out = $sqrt(a_*a_ + b_*b_) / L;
         g_mir = $sqrt(c_*c_ + d_*d_) / L;
         g_in  = $sqrt(ai_*ai_ + bi_*bi_) / L;
         // residual power = total - positive - negative frequency components
         e_db  = 10.0*$log10(((p_/L) - g_out*g_out - g_mir*g_mir) / (g_out*g_out));
      end
   endtask

   // energy of channel `out_ch` at the OTHER channel's frequency, relative to
   // its own tone - the crosstalk / shared-resource check
   task crosstalk(input integer out_ch, input integer Nother, output real xt);
      integer kk;
      real a_, b_, ci_, cq_, t_;
      begin
         L = 16 * Nother;
         a_ = 0.0; b_ = 0.0;
         for (kk = 0; kk < L; kk = kk + 1) begin
            @(posedge clk); #1;
            if (out_ch == 0) begin
`ifdef REVERSE
               ci_ = $itor($signed(tx0_i)); cq_ = $itor($signed(tx0_q));
`else
               ci_ = $itor($signed(rx0_sample[31:16])); cq_ = $itor($signed(rx0_sample[15:0]));
`endif
            end else begin
`ifdef REVERSE
               ci_ = $itor($signed(tx1_i)); cq_ = $itor($signed(tx1_q));
`else
               ci_ = $itor($signed(rx1_sample[31:16])); cq_ = $itor($signed(rx1_sample[15:0]));
`endif
            end
            t_ = 2.0 * 3.14159265358979323846 * kk / Nother;
            a_ = a_ + ci_*$cos(t_) + cq_*$sin(t_);
            b_ = b_ + cq_*$cos(t_) - ci_*$sin(t_);
         end
         xt = $sqrt(a_*a_ + b_*b_) / L;
      end
   endtask

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;

      twr(0, 8'd0, 32'd0); twr(0, 8'd1, 32'h0000_8000); twr(0, 8'd2, 32'd1);
      twr(1, 8'd0, 32'd0); twr(1, 8'd1, 32'h0000_8000); twr(1, 8'd2, 32'd1);
      rwr(0, 8'd0, 32'd0); rwr(0, 8'd3, 32'd0);
      rwr(1, 8'd0, 32'd0); rwr(1, 8'd3, 32'd0);

      repeat (400) @(posedge clk);

      measure(0, N0, gin, gout, gmir, evm_db);
      gout0 = gout;
      gain_db = 20.0*$log10(gout/gin);
`ifdef REVERSE
      $display("LOOP2-REV: ch0 fs/64  gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
`else
      $display("LOOP2-FWD: ch0 fs/64  gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
`endif
      if (gain_db < -0.01 || gain_db > 0.01) begin
         errors = errors + 1; $display("  FAIL ch0 gain"); end
      if (20.0*$log10(gmir/gout) > -60.0) begin
         errors = errors + 1; $display("  FAIL ch0 mirror/conjugate"); end
      if (evm_db > -60.0) begin
         errors = errors + 1; $display("  FAIL ch0 EVM"); end

      measure(1, N1, gin, gout, gmir, evm_db);
      gain_db = 20.0*$log10(gout/gin);
`ifdef REVERSE
      $display("LOOP2-REV: ch1 fs/16  gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
`else
      $display("LOOP2-FWD: ch1 fs/16  gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
`endif
      if (gain_db < -0.01 || gain_db > 0.01) begin
         errors = errors + 1; $display("  FAIL ch1 gain"); end
      if (20.0*$log10(gmir/gout) > -60.0) begin
         errors = errors + 1; $display("  FAIL ch1 mirror/conjugate"); end
      if (evm_db > -60.0) begin
         errors = errors + 1; $display("  FAIL ch1 EVM"); end

      // ---- third case: non-zero LO on both sides (fs/8) ----
      // The TX mixer is e^{+j theta} and the RX mixer e^{-j theta}; writing
      // the same phase increment to both must cancel exactly, returning the
      // tone to its baseband frequency.  If either sign were wrong the output
      // would sit at 2*fs/8 +- f and the DFT below would find nothing.
      twr(0, 8'd0, 32'h2000_0000); twr(1, 8'd0, 32'h2000_0000);
      rwr(0, 8'd0, 32'h2000_0000); rwr(1, 8'd0, 32'h2000_0000);
      repeat (400) @(posedge clk);
      measure(0, N0, gin, gout, gmir, evm_db);
      gain_db = 20.0*$log10(gout/gin);
      $display("  LO fs/8: ch0 gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
      if (gain_db < -0.01 || gain_db > 0.01 || 20.0*$log10(gmir/gout) > -60.0) begin
         errors = errors + 1; $display("  FAIL NCO cancellation ch0"); end
      measure(1, N1, gin, gout, gmir, evm_db);
      gain_db = 20.0*$log10(gout/gin);
      $display("  LO fs/8: ch1 gain %.6f (%.5f dB) mirror %.1f dB EVM %.1f dB",
               gout/gin, gain_db, 20.0*$log10(gmir/gout), evm_db);
      if (gain_db < -0.01 || gain_db > 0.01 || 20.0*$log10(gmir/gout) > -60.0) begin
         errors = errors + 1; $display("  FAIL NCO cancellation ch1"); end

      crosstalk(0, N1, xt_energy);  // ch0 output at ch1's frequency
      xt_db = 20.0*$log10(xt_energy/gout0 + 1.0e-30);
      $display("  cross: ch0 at fs/16 relative to its own tone: %.1f dB", xt_db);

      // two independent chains: the only leakage is arithmetic noise, so this
      // is a sanity bound, not a hard spec
      if (xt_db > -60.0) begin
         errors = errors + 1; $display("  FAIL crosstalk"); end

      if (errors == 0) begin
`ifdef REVERSE
         $display("LOOP2-REV: PASS - RX->TX on both channels at once: unity gain, no conjugate, EVM at the dither floor");
`else
         $display("LOOP2-FWD: PASS - TX->RX on both channels at once: unity gain, no conjugate, no crosstalk");
`endif
      end else
         $display("LOOP2: FAIL - %0d checks wrong", errors);
      $finish;
   end

endmodule
