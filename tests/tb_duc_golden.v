// tb_duc_golden - the transmit DSP against the original Ettus chain.
//
// Two transmit chains run side by side on one clock and one settings bus:
//
//   ref   the Ettus Research duc_chain, compiled from the untouched upstream
//         sources in tests/ref/ettus_dsp/ (module names prefixed `ettus_` by
//         tests/mk_ettus_ref.py so both fit in one simulation), configured as
//         the stock B200 image configures it (NEW_HB_INTERP = 1)
//   dut   src/rtl/dsp/duc_chain.v, the chain this design builds
//
// For every rate in the table the bench writes the registers exactly as UHD's
// tx_dsp_core_3000 does (frequency word, the scale that cancels the CORDIC
// and CIC gain, the interpolation word with its two halfband bits), feeds
// each chain the same host tone on that chain's own strobe, and requires
//
//   * the same strobe on every clock - so the same host sample rate
//   * the same 24-bit I and Q towards the DAC on every clock - bit for bit
//   * a strobe period of exactly the requested interpolation
//   * the same tone level within 0.1 dB (reported; with identical outputs it
//     is 0.000) and a level within a decibel of the input, so a chain that
//     is merely identical to a broken reference cannot pass
//
// One place where the dut is not the upstream text: its CORDIC has a guard
// bit and clips where upstream wraps (rotating an input above 1.22 of full
// scale).  Nothing here drives it that hard, so the outputs must still be
// identical; tb_tx_dc drives the overload itself.
//
// Each chain is fed on its own strobe so that a chain with a different
// cadence or gain still gets a fair level measurement: the level column then
// says by how much it is off.
//
// +NEG_SCALE_REG gives the dut the scale word times 1.2143 (the inverse of
// the CORDIC's 0.8235), which is what a chain with a unity-gain mixer in
// place of the CORDIC puts out: 1.69 dB above the stock level.  That run
// must FAIL; the justfile checks that it does.  +NCFG=<n> stops after the
// first n configurations, +CFGMASK=<hex> runs only the configurations whose
// bit is set, +NSETTLE=<n> / +NMEAS=<n> shorten a run.
//
// -DPOSTSYN: the dut is not the RTL but the netlist yosys makes of it with
// the build's own flags (a flat module `duc_chain_syn` without parameters, BASE
// fixed at synthesis).  See tb_ddc_golden.v.
`timescale 1ns/1ps

`ifdef POSTSYN
 `define DUT_NAME "transmit chain (yosys netlist)"
`else
 `define DUT_NAME "transmit chain"
`endif

module tb_duc_golden;

   localparam [7:0] BASE = 8'd184;          // SR_TX_DSP in radio_legacy.v
   integer N_SETTLE = 64;                   // host samples before measuring
   integer N_MEAS   = 128;                  // host samples measured
   integer settle;
   localparam real    AMP      = 22938.0;   // 0.7 of full scale
   localparam real    F_HOST   = 0.11;      // tone, cycles per host sample
   localparam real    TWO_PI   = 6.283185307179586;

   reg clk = 1'b0;
   always #8.138 clk = ~clk;                // 61.44 MHz, the fastest radio clock

   reg         rst = 1'b1;
   reg         run = 1'b0;
   reg         set_stb = 1'b0;
   reg  [7:0]  set_addr = 8'd0;
   reg  [31:0] set_data = 32'd0, set_data_dut = 32'd0;

   reg  [31:0] smp_ref = 32'd0, smp_dut = 32'd0;
   wire        stb_ref, stb_dut;
   wire [23:0] i_ref, q_ref, i_dut, q_dut;

   ettus_duc_chain #(.BASE(BASE), .DSPNO(0), .WIDTH(24), .NEW_HB_INTERP(1), .DEVICE("7SERIES")) ref_i
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(i_ref), .tx_fe_q(q_ref),
      .sample(smp_ref), .run(run), .strobe(stb_ref), .debug());

`ifdef POSTSYN
   duc_chain_syn dut_i
`else
   duc_chain #(.BASE(BASE), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut_i
`endif
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data_dut),
      .tx_fe_i(i_dut), .tx_fe_q(q_dut),
      .sample(smp_dut), .run(run), .strobe(stb_dut), .debug());

   // Upstream hb47_int leaves four registers without reset or initial value
   // (and the rounder and clipper behind them start undefined too).  In the
   // FPGA they configure to 0; in a simulator they start at X, and the first
   // X that reaches a CIC integrator stays there.  Give the reference the
   // power-up state of the hardware.  (The dut has it in its own source.)
`define POWER_UP(hb) begin \
      hb.data_out = 0; hb.partial_result_a = 0; hb.partial_result_b = 0; hb.result = 0; \
      hb.final_round.out = 0; hb.final_round.err = 0; hb.final_clip.out = 0; \
   end
   initial begin
      `POWER_UP(ref_i.new_hb.hb1_i0)
      `POWER_UP(ref_i.new_hb.hb1_q0)
      `POWER_UP(ref_i.new_hb.hb2_i0)
      `POWER_UP(ref_i.new_hb.hb2_q0)
   end

   // ------------------------------------------------------------- settings ---
   task poke(input [7:0] addr, input [31:0] data, input [31:0] data_dut);
      begin
         @(negedge clk);
         set_addr = addr; set_data = data; set_data_dut = data_dut; set_stb = 1'b1;
         @(negedge clk);
         set_stb = 1'b0;
      end
   endtask

   localparam integer N_CFG = 14;
   reg [9:0]   cfg_total;
   reg         cfg_tune;
   task select_cfg(input integer idx);
      begin
         cfg_tune = 1'b0;
         case (idx)
           0:  cfg_total = 10'd1;
           1:  cfg_total = 10'd2;
           2:  cfg_total = 10'd3;
           3:  cfg_total = 10'd4;
           4:  cfg_total = 10'd8;
           5:  cfg_total = 10'd16;
           6:  cfg_total = 10'd61;
           7:  cfg_total = 10'd128;
           8:  cfg_total = 10'd512;
           9:  cfg_total = 10'd6;
           10: cfg_total = 10'd12;
           11: cfg_total = 10'd254;
           // with the CORDIC turning
           12: begin cfg_total = 10'd1; cfg_tune = 1'b1; end
           default: begin cfg_total = 10'd8; cfg_tune = 1'b1; end
         endcase
      end
   endtask

   // ------------------------------------------------------ the host sample ---
   // The chain takes `sample` on the clock its strobe is high; the next one
   // must be there by the next strobe.
   integer n_ref, n_dut;
   function [31:0] host_sample(input integer k);
      real ph;
      reg [15:0] hi, hq;
      begin
         ph = TWO_PI * F_HOST * k;
         hi = $rtoi(AMP * $cos(ph));
         hq = $rtoi(AMP * $sin(ph));
         host_sample = {hi, hq};
      end
   endfunction

   // --------------------------------------------------------------- checks ---
   integer n;
   integer cnt_ref, cnt_dut, last_ref, last_dut;
   integer pmin_ref, pmax_ref, pmin_dut, pmax_dut;
   integer stb_mis, dat_mis;
   integer meas_ref, meas_dut, mclk_ref, mclk_dut;
   real    pwr_ref, pwr_dut;
   reg     checking = 1'b0;

   function real sq(input [23:0] v);
      real r;
      begin
         r = $signed(v);
         sq = r * r;
      end
   endfunction

   always @(posedge clk) if (checking) begin
      if (stb_ref !== stb_dut) stb_mis = stb_mis + 1;
      if (i_ref !== i_dut || q_ref !== q_dut) dat_mis = dat_mis + 1;

      // measure over the clocks spanned by N_MEAS host samples of each chain
      if (cnt_ref >= settle && meas_ref < N_MEAS) begin
         pwr_ref = pwr_ref + sq(i_ref) + sq(q_ref); mclk_ref = mclk_ref + 1;
      end
      if (cnt_dut >= settle && meas_dut < N_MEAS) begin
         pwr_dut = pwr_dut + sq(i_dut) + sq(q_dut); mclk_dut = mclk_dut + 1;
      end

      if (stb_ref === 1'b1) begin
         if (cnt_ref > 0) begin
            if (n - last_ref < pmin_ref) pmin_ref = n - last_ref;
            if (n - last_ref > pmax_ref) pmax_ref = n - last_ref;
         end
         last_ref = n;
         if (cnt_ref >= settle && meas_ref < N_MEAS) meas_ref = meas_ref + 1;
         cnt_ref = cnt_ref + 1;
         n_ref = n_ref + 1;
         smp_ref <= host_sample(n_ref);
      end
      if (stb_dut === 1'b1) begin
         if (cnt_dut > 0) begin
            if (n - last_dut < pmin_dut) pmin_dut = n - last_dut;
            if (n - last_dut > pmax_dut) pmax_dut = n - last_dut;
         end
         last_dut = n;
         if (cnt_dut >= settle && meas_dut < N_MEAS) meas_dut = meas_dut + 1;
         cnt_dut = cnt_dut + 1;
         n_dut = n_dut + 1;
         smp_dut <= host_sample(n_dut);
      end
   end

   // ------------------------------------------------------------- stimulus ---
   integer idx, interp, hb0, hb1, scale, scale_dut, freq_word, limit, fails, cfg_fail;
   reg [9:0] rate_word;
   reg       neg_scale_reg;
   integer   n_cfg, n_run;
   reg [31:0] cfg_mask;
   real    rate_pow, scaling, f_nco, g_ref, g_dut;

   initial begin
      fails = 0;
      neg_scale_reg = $test$plusargs("NEG_SCALE_REG");
      if (!$value$plusargs("NCFG=%d", n_cfg)) n_cfg = N_CFG;
      if (!$value$plusargs("CFGMASK=%h", cfg_mask)) cfg_mask = {32{1'b1}};
      if ($value$plusargs("NSETTLE=%d", idx)) N_SETTLE = idx;
      if ($value$plusargs("NMEAS=%d", idx)) N_MEAS = idx;
      n_run = 0;
      repeat (12) @(negedge clk);
      rst = 1'b0;
      repeat (4) @(negedge clk);

      for (idx = 0; idx < n_cfg; idx = idx + 1) if (cfg_mask[idx]) begin
         select_cfg(idx);
         n_run = n_run + 1;

         // tx_dsp_core_3000::set_host_rate / update_scalar / set_freq
         interp = cfg_total; hb0 = 0; hb1 = 0;
         if (interp % 2 == 0) begin hb0 = 1; interp = interp / 2; end
         if (interp % 2 == 0) begin hb1 = 1; interp = interp / 2; end
         rate_word = (hb1 << 9) | (hb0 << 8) | (interp & 255);
         rate_pow = $pow(1.0 * interp, 3);
         scaling  = $pow(2.0, $ceil($ln(rate_pow) / $ln(2.0))) / (1.648 * rate_pow);
         scale    = $rtoi(65536.0 * scaling + 0.5);
         scale_dut = neg_scale_reg ? $rtoi(scale * 1.2143 + 0.5) : scale;
         f_nco    = cfg_tune ? 0.07 : 0.0;                   // cycles per clock
         freq_word = $rtoi(f_nco * 4294967296.0 + (cfg_tune ? 0.5 : 0.0));

         poke(BASE + 8'd0, freq_word, freq_word);
         poke(BASE + 8'd1, scale, scale_dut);
         poke(BASE + 8'd2, rate_word, rate_word);
         repeat (8) @(negedge clk);

         n = 0; cnt_ref = 0; cnt_dut = 0; last_ref = 0; last_dut = 0;
         pmin_ref = 1 << 30; pmax_ref = 0; pmin_dut = 1 << 30; pmax_dut = 0;
         stb_mis = 0; dat_mis = 0; meas_ref = 0; meas_dut = 0; mclk_ref = 0; mclk_dut = 0;
         pwr_ref = 0.0; pwr_dut = 0.0;
         n_ref = 0; n_dut = 0;
         smp_ref = host_sample(0); smp_dut = host_sample(0);
         // the chain is some 40 clocks deep whatever the rate: let that pass too
         settle = N_SETTLE + 96 / cfg_total;
         limit = (settle + N_MEAS + 32) * cfg_total + 400;

         run = 1'b1; checking = 1'b1;
         while (n < limit && (meas_ref < N_MEAS || meas_dut < N_MEAS)) begin
            @(negedge clk);
            n = n + 1;
         end
         run = 1'b0;
         repeat (64) begin @(negedge clk); n = n + 1; end     // drain, still compared
         checking = 1'b0;

         // 24-bit DAC word against the 16-bit host word: 8 bits of alignment
         g_ref = (mclk_ref > 0) ? 10.0 * $log10(pwr_ref / mclk_ref / (AMP * AMP * 65536.0)) : -999.0;
         g_dut = (mclk_dut > 0) ? 10.0 * $log10(pwr_dut / mclk_dut / (AMP * AMP * 65536.0)) : -999.0;

         cfg_fail = 0;
         if (stb_mis != 0 || dat_mis != 0) cfg_fail = 1;
         if (meas_ref < N_MEAS || meas_dut < N_MEAS) cfg_fail = 1;
         if (pmin_dut != cfg_total || pmax_dut != cfg_total) cfg_fail = 1;
         if (pmin_ref != cfg_total || pmax_ref != cfg_total) cfg_fail = 1;
         if (g_dut - g_ref > 0.1 || g_ref - g_dut > 0.1) cfg_fail = 1;
         if (g_dut > 0.2 || g_dut < -1.2) cfg_fail = 1;
         fails = fails + cfg_fail;

         $display("interp %3d  reg 0x%03x scale %5d nco %s | period ref %0d..%0d dut %0d..%0d clk | host samples ref %0d dut %0d | strobe mismatches %0d, output mismatches %0d | level ref %7.3f dB dut %7.3f dB, delta %6.3f dB | %s",
                  cfg_total, rate_word, scale, cfg_tune ? "0.07" : "0.00",
                  pmin_ref, pmax_ref, pmin_dut, pmax_dut, cnt_ref, cnt_dut,
                  stb_mis, dat_mis, g_ref, g_dut, g_dut - g_ref,
                  cfg_fail ? "FAIL" : "ok");
      end

      if (n_run == 0) $display("FAIL: no configuration selected");
      else if (fails == 0)
        $display("PASS: %0s is bit- and cycle-identical to the Ettus original at all %0d configurations", `DUT_NAME, n_run);
      else
        $display("FAIL: %0s differs from the Ettus original in %0d of %0d configurations", `DUT_NAME, fails, n_run);
      $finish;
   end

endmodule
