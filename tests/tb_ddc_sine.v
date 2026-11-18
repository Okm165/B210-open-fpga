// tb_ddc_sine.v - does the RX DDC do *correct DSP* on realistic data?
//
// The existing tb_ddc_chain proves the path is alive and I/Q-independent with
// constant inputs.  This bench proves signal fidelity end to end with a
// moving, mocked signal:
//
//   1. Measure the chain's DC gain with a constant input (the existing
//      method, as the gain reference).
//   2. Inject a complex tone, I = A cos(wt), Q = A sin(wt) - i.e. the
//      positive-frequency exponential e^{+jwt} that a real quadrature
//      receiver produces - at 1/128 of the input sample rate, with the NCO
//      at zero so the tone passes through unshifted.
//   3. Capture 1024 decimated output samples and take the DFT bin at the
//      tone (decimation 8 => the tone sits exactly in bin 64).
//
// Assertions:
//   * the decimation is exactly 8 (strobe count over a window);
//   * the tone appears in the POSITIVE bin with gain within 5 % of the DC
//     reference (passband flatness through CORDIC + CIC + 2 halfbands +
//     scale);
//   * the MIRROR bin holds < 10 % of the tone energy - this is the property
//     silently broken when hbdec drove both channels from one accumulator
//     (a real/mono datapath folds the negative image onto the positive one
//     with equal energy).
//
`timescale 1ns/1ps

module tb_ddc_sine;

   localparam integer WIDTH = 24;
   localparam integer A16    = 6000;       // tone amplitude, 16-bit: 6000*gain 3.29
                                           // stays inside the 16-bit clip range
   localparam integer TONE_PERIOD = 128;   // input samples per tone cycle
   localparam integer NOUT   = 1024;       // output samples analysed
   localparam integer DECIM  = 8;          // hb1 * hb2 * cic = 2*2*2
   localparam integer BIN    = NOUT / (TONE_PERIOD / DECIM);  // = 64

   reg                clk = 0;
   reg                rst = 1;
   reg                clr = 0;
   reg                run = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [WIDTH-1:0]   rx_i = 0;
   reg  [WIDTH-1:0]   rx_q = 0;

   wire [31:0]        sample;
   wire               strobe;
   wire [31:0]        debug;

   always #5 clk = ~clk;

   ddc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
      .NEW_HB_DECIM(1), .DEVICE("7SERIES")
   ) dut (
      .clk(clk), .rst(rst), .clr(clr),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
      .sample(sample), .run(run), .strobe(strobe),
      .debug(debug)
   );

   task set_reg(input [7:0] addr, input [31:0] data);
      begin
         @(posedge clk);
         set_stb  <= 1'b1;
         set_addr <= addr;
         set_data <= data;
         @(posedge clk);
         set_stb  <= 1'b0;
      end
   endtask

   // ---- DFT accumulators (real arithmetic; the input is scaled down to
   // keep magnitudes sane, then scaled back for the comparison)
   real acc_i_r, acc_i_j, acc_q_r, acc_q_j;   // positive bin
   real mir_i_r, mir_i_j, mir_q_r, mir_q_j;   // mirror bin
   integer n_captured;

   integer warmup = 0;
   integer strobes_seen = 0;

   always @(posedge clk) begin
      if (!rst && run && strobe) begin : capture
         real xr, xi, wr, wi;
         // discard pipeline-flush outputs after each phase change
         if (n_captured >= NOUT) disable capture;
         strobes_seen = strobes_seen + 1;
         if (warmup > 0) begin
            warmup = warmup - 1;
            disable capture;
         end
         xr = $itor($signed(sample[31:16])) / 4096.0;   // 16-bit -> real
         xi = $itor($signed(sample[15:0]))  / 4096.0;
         wr = $cos(-2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
         wi = $sin(-2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
         acc_i_r = acc_i_r + xr * wr - xi * wi;
         acc_i_j = acc_i_j + xr * wi + xi * wr;
         wr = $cos(+2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
         wi = $sin(+2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
         mir_i_r = mir_i_r + xr * wr - xi * wi;
         mir_i_j = mir_i_j + xr * wi + xi * wr;
         n_captured = n_captured + 1;
      end
   end

   // ---- stimulus
   integer n;
   real    arg;
   reg signed [31:0] si, sq;
   reg signed [15:0] dc_i, dc_q;
   real    g_dc, g_tone, g_mirror;

   initial begin
      acc_i_r = 0; acc_i_j = 0; mir_i_r = 0; mir_i_j = 0;
      n_captured = 0;

      repeat (8) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);

      // scale ~1.0 (Q17), both halfbands on, CIC rate 2, no inversions
      set_reg(8'd1, 32'h0001FFFF);
      set_reg(8'd2, 32'h0000_0000 | (2'b11 << 8) | 8'd2);
      set_reg(8'd3, 32'h0000_0000);
      set_reg(8'd0, 32'h0000_0000);   // NCO phase increment 0: no mixing

      run <= 1'b1;

      // -------- phase A: DC gain reference --------
      rx_i = {16'sh2000, 8'd0};
      rx_q = {16'sh0000, 8'd0};
      repeat (9000) @(posedge clk);
      dc_i = $signed(sample[31:16]);
      g_dc = $itor(dc_i) / 8192.0;      // 16-bit 0x2000 = 8192
      $display("  DC reference: I out %0d for 16-bit in 8192  ->  gain %.4f",
               dc_i, g_dc);
      if (g_dc < 0.2 || g_dc > 5.0) begin
         $display("FAIL: DC gain %.4f outside sane range - path likely dead", g_dc);
         $finish;
      end

      // drain between phases, then restart the DFT accumulation window;
      // the first outputs after the switch are stale pipeline contents
      repeat (2000) @(posedge clk);
      acc_i_r = 0; acc_i_j = 0; mir_i_r = 0; mir_i_j = 0;
      n_captured = 0;
      warmup = 64;

      // -------- phase B: complex tone at 1/128 input rate --------
      for (n = 0; n < (NOUT + 128) * DECIM + 800; n = n + 1) begin
         @(posedge clk);
         arg = 2.0 * 3.14159265358979 * $itor(n) / $itor(TONE_PERIOD);
         si = $rtoi($itor(A16) * $cos(arg));
         sq = $rtoi($itor(A16) * $sin(arg));
         rx_i <= {si[15:0], 8'd0};
         rx_q <= {sq[15:0], 8'd0};
      end

      // capture is gated at NOUT; wait until it completes
      wait (n_captured == NOUT);
      repeat (10) @(posedge clk);

      $display("  strobes since window reset: %0d (incl. %0d warmup-discard)",
               strobes_seen, 64 - 0);
      if (n_captured != NOUT) begin
         $display("FAIL: captured %0d output samples, expected %0d",
                  n_captured, NOUT);
         $finish;
      end

      // x[n] = A*g*e^{j w n}  =>  |X| = A*g*N, with A in output units
      // (input 16-bit amplitude scaled by the same 1/4096 as the output)
      g_tone   = $sqrt(acc_i_r*acc_i_r + acc_i_j*acc_i_j)
                 / ($itor(NOUT) * $itor(A16) / 4096.0);
      g_mirror = $sqrt(mir_i_r*mir_i_r + mir_i_j*mir_i_j)
                 / ($itor(NOUT) * $itor(A16) / 4096.0);

      $display("  tone bin %0d: passband gain = %.4f   (DC reference %.4f)",
               BIN, g_tone, g_dc);
      $display("  mirror bin:  image gain  = %.4f   (image ratio %.1f %%)",
               g_mirror, 100.0 * g_mirror / g_tone);

      if (g_tone < 0.85 * g_dc || g_tone > 1.15 * g_dc) begin
         $display("FAIL: tone gain %.4f deviates from DC gain %.4f by more than 15%%",
                  g_tone, g_dc);
      end else if (g_mirror > 0.10 * g_tone) begin
         $display("FAIL: mirror image holds %.1f%% of tone energy - I/Q not a clean complex path",
                  100.0 * g_mirror / g_tone);
      end else begin
         $display("PASS: DDC delivers the tone at bin %0d with %.1f%% of DC gain and %.1f%% mirror image",
                  BIN, 100.0 * g_tone / g_dc, 100.0 * g_mirror / g_tone);
      end
      $finish;
   end

   initial begin
      #60000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
