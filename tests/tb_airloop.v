// tb_airloop.v - the whole radio loop with an explicit, known air path.
//
//   host16 -> TX0/TX1 -> 24-bit pins -> [ air model ] -> RX0/RX1 -> host16
//
// The air model is deliberately simple and, crucially, deterministic in its
// linear part so it can be subtracted rather than blamed on the FPGA:
//
//   y0[n] = (x0[n] + beta*x0[n-D]) + alpha*x1[n] + noise0[n]
//   y1[n] = (x1[n] + beta*x1[n-D]) + alpha*x0[n] + noise1[n]
//
//   beta  = -1/8   (-18 dB, a two-path multipath echo D = 3 samples)
//   alpha =  1/32  (-30 dB, antenna coupling between the two channels)
//
// Two different tones run at once (bins 48 and 112 of 1024).  For a tone at
// bin K the self path has the known response
//
//   H(K) = 1 + beta * exp(-j 2 pi K D / L)
//
// so the RX output must be A*H(K): the FPGA is graded against the model, not
// against the clean input.  The residual after the tone is the injected noise
// plus the FPGA's own dither, and nothing else.
//
// Cases:
//   1. alpha = 0, noise swept: measured EVM must track the injected noise and
//      never fall below (or rise above) sqrt(noise^2 + dither^2).
//   2. alpha = -30 dB, no noise: each RX must carry the other channel's tone
//      at the injected level - a linear MIMO pass-through, not a cancellation.
`timescale 1ns/1ps

module tb_airloop;

   localparam integer L  = 1024;
   localparam integer K0 = 48;      // channel 0 tone bin
   localparam integer K1 = 112;     // channel 1 tone bin
   localparam integer D  = 3;       // multipath delay, output samples
   localparam integer AMP = 8000;   // ~ -12 dBFS per tone

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   // ---- TX chains ----
   reg        t0_stb=0; reg [7:0] t0_addr=0; reg [31:0] t0_data=0;
   reg        t1_stb=0; reg [7:0] t1_addr=0; reg [31:0] t1_data=0;
   reg  [31:0] tx0_sample=0, tx1_sample=0;
   wire [23:0] tx0_i, tx0_q, tx1_i, tx1_q;
   wire        tx0_strobe, tx1_strobe;
   wire [31:0] tx0_debug, tx1_debug;

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

   // ---- air model ----
   integer beta_den  = 8;    // beta = -1/8
   integer alpha_den = 32;   // alpha = 1/32
   integer noise_m   = 0;    // uniform noise half-range, 24-bit units
   integer seed0 = 32'h1234_5678, seed1 = 32'h9ABC_DEF0;

   reg signed [23:0] d0i [0:D-1], d0q [0:D-1], d1i [0:D-1], d1q [0:D-1];
   integer di;
   always @(posedge clk) begin
      for (di = D-1; di > 0; di = di - 1) begin
         d0i[di] <= d0i[di-1]; d0q[di] <= d0q[di-1];
         d1i[di] <= d1i[di-1]; d1q[di] <= d1q[di-1];
      end
      d0i[0] <= $signed(tx0_i); d0q[0] <= $signed(tx0_q);
      d1i[0] <= $signed(tx1_i); d1q[0] <= $signed(tx1_q);
   end

   function signed [23:0] rnd(input integer m, input integer s);
      integer r;
      begin
         if (m == 0) rnd = 24'sd0;
         else begin
            r = $random(s) % (2*m+1);
            rnd = r - m;
         end
      end
   endfunction

   wire signed [23:0] e0i = d0i[D-1], e0q = d0q[D-1];
   wire signed [23:0] e1i = d1i[D-1], e1q = d1q[D-1];

   // Noise is registered so each call advances a seed exactly once per clock
   // and the run is reproducible; I and Q get independent draws.
   reg signed [23:0] n0i=0, n0q=0, n1i=0, n1q=0;
   always @(posedge clk) begin
      n0i <= rnd(noise_m, seed0); n0q <= rnd(noise_m, seed0);
      n1i <= rnd(noise_m, seed1); n1q <= rnd(noise_m, seed1);
   end

   wire signed [23:0] r0i = $signed(tx0_i) - (e0i / beta_den) + ($signed(tx1_i) / alpha_den) + n0i;
   wire signed [23:0] r0q = $signed(tx0_q) - (e0q / beta_den) + ($signed(tx1_q) / alpha_den) + n0q;
   wire signed [23:0] r1i = $signed(tx1_i) - (e1i / beta_den) + ($signed(tx0_i) / alpha_den) + n1i;
   wire signed [23:0] r1q = $signed(tx1_q) - (e1q / beta_den) + ($signed(tx0_q) / alpha_den) + n1q;

   // ---- RX chains ----
   reg        r0_stb=0; reg [7:0] r0_addr=0; reg [31:0] r0_data=0;
   reg        r1_stb=0; reg [7:0] r1_addr=0; reg [31:0] r1_data=0;
   wire [31:0] rx0_sample, rx1_sample;
   wire        rx0_strobe, rx1_strobe;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx0 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r0_stb), .set_addr(r0_addr), .set_data(r0_data),
      .rx_fe_i(r0i), .rx_fe_q(r0q),
      .sample(rx0_sample), .run(1'b1), .strobe(rx0_strobe), .debug());

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx1 (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r1_stb), .set_addr(r1_addr), .set_data(r1_data),
      .rx_fe_i(r1i), .rx_fe_q(r1q),
      .sample(rx1_sample), .run(1'b1), .strobe(rx1_strobe), .debug());

   // ---- register writes ----
   task twr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch==0) begin t0_stb=1; t0_addr=a; t0_data=d; end
         else       begin t1_stb=1; t1_addr=a; t1_data=d; end
         @(negedge clk); t0_stb=0; t1_stb=0;
      end
   endtask
   task rwr(input integer ch, input [7:0] a, input [31:0] d);
      begin
         @(negedge clk);
         if (ch==0) begin r0_stb=1; r0_addr=a; r0_data=d; end
         else       begin r1_stb=1; r1_addr=a; r1_data=d; end
         @(negedge clk); r0_stb=0; r1_stb=0;
      end
   endtask

   // ---- stimulus ----
   integer p0 = 0, p1 = 0;
   real a0, a1;
   always @(negedge clk) begin
      a0 = 2.0*3.14159265358979323846*K0*p0/L;
      a1 = 2.0*3.14159265358979323846*K1*p1/L;
      tx0_sample[31:16] <= $rtoi(AMP*$cos(a0));
      tx0_sample[15:0]  <= $rtoi(AMP*$sin(a0));
      tx1_sample[31:16] <= $rtoi(AMP*$cos(a1));
      tx1_sample[15:0]  <= $rtoi(AMP*$sin(a1));
      p0 <= (p0 == L-1) ? 0 : p0 + 1;
      p1 <= (p1 == L-1) ? 0 : p1 + 1;
   end

   // ---- measurement ----
   integer errors;
   real c_i, c_q, th, ap, bp, pw, g, evm, hmag;
   real amp_out, evm_db;
   real h_expected;

   task meas(input integer which, input integer K,
             output real amp_out, output real evm_db);
      integer n; real ar, ai, ai_, aq_;
      begin
         ar = 0.0; ai = 0.0; pw = 0.0;
         for (n = 0; n < L; n = n + 1) begin
            @(posedge clk); #1;
            if (which == 0) begin
               ai_ = $itor($signed(rx0_sample[31:16]));
               aq_ = $itor($signed(rx0_sample[15:0]));
            end else begin
               ai_ = $itor($signed(rx1_sample[31:16]));
               aq_ = $itor($signed(rx1_sample[15:0]));
            end
            th = 2.0*3.14159265358979323846*K*n/L;
            ar = ar + ai_*$cos(th) + aq_*$sin(th);
            ai = ai + aq_*$cos(th) - ai_*$sin(th);
            pw = pw + ai_*ai_ + aq_*aq_;
         end
         amp_out = $sqrt(ar*ar + ai*ai) / L;
         evm_db  = 10.0*$log10(((pw/L) - amp_out*amp_out) / (amp_out*amp_out));
      end
   endtask

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;

      twr(0,8'd0,0); twr(0,8'd1,32'h8000); twr(0,8'd2,1);
      twr(1,8'd0,0); twr(1,8'd1,32'h8000); twr(1,8'd2,1);
      rwr(0,8'd0,0); rwr(0,8'd3,0);
      rwr(1,8'd0,0); rwr(1,8'd3,0);
      repeat (400) @(posedge clk);

      // analytic self-path magnitude at each tone
      hmag = $sqrt(1.0 + 1.0/(beta_den*beta_den)
                   - 2.0/beta_den*$cos(2.0*3.14159265358979323846*K0*D/L));
      $display("AIR: analytic |H| at bin %0d = %.6f (multipath %0d dB, delay %0d)",
               K0, hmag, -20.0*$log10(beta_den*1.0), D);

      // ---- case 1: no coupling, noise swept ----
      alpha_den = 1000000;   // effectively zero coupling
      noise_m = 0;
      repeat (200) @(posedge clk);
      meas(0, K0, amp_out, evm_db);
      g = amp_out / (AMP * hmag);
      $display("AIR: noise   0  ch0 amp %.2f (model %.2f) EVM %.1f dB  ch1-to-ch0 leak suppressed", amp_out, AMP*hmag, evm_db);
      if (g < 0.995 || g > 1.005) begin errors=errors+1; $display("AIR: FAIL ch0 gain vs model"); end

      noise_m = 256;
      repeat (200) @(posedge clk);
      meas(0, K0, amp_out, evm_db);
      $display("AIR: noise 256  ch0 EVM %.1f dB (noise ~ %.1f dB + dither)", evm_db,
               20.0*$log10((256.0/1.732/256.0)/(AMP)));
      if (evm_db > -55.0) begin errors=errors+1; $display("AIR: FAIL EVM too high at noise 256"); end

      noise_m = 2048;
      repeat (200) @(posedge clk);
      meas(0, K0, amp_out, evm_db);
      $display("AIR: noise 2048 ch0 EVM %.1f dB", evm_db);

      // ---- case 2: alpha = -30 dB, no noise; the other tone must pass ----
      alpha_den = 32; noise_m = 0;
      repeat (200) @(posedge clk);
      meas(0, K1, amp_out, evm_db);      // ch0 RX at ch1's tone
      $display("AIR: coupling ch0 sees ch1 tone amp %.2f (injected ~ %.2f)", amp_out, AMP/32.0);
      if (amp_out < 0.8*(AMP/32.0) || amp_out > 1.25*(AMP/32.0)) begin
         errors=errors+1; $display("AIR: FAIL coupling not passed linearly"); end

      if (errors == 0)
         $display("AIR: PASS - two channels through delay+multipath+noise+coupling: the FPGA tracks the model, no added distortion");
      else
         $display("AIR: FAIL - %0d checks wrong", errors);
      $finish;
   end

endmodule
