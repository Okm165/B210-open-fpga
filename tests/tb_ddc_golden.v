// tb_ddc_golden - the receive DSP against the original Ettus chain.
//
// Two receive chains run side by side on one clock, one stimulus and one
// settings bus:
//
//   ref   the Ettus Research ddc_chain, compiled from the untouched upstream
//         sources in tests/ref/ettus_dsp/ (module names prefixed `ettus_` by
//         tests/mk_ettus_ref.py so both fit in one simulation), configured as
//         the stock B200 image configures it (NEW_HB_DECIM = 1)
//   dut   src/rtl/dsp/ddc_chain.v, the chain this design builds
//
// For every rate in the table the bench writes the registers exactly as UHD's
// rx_dsp_core_3000 does for a B200 (frequency word, the scale that cancels
// the CORDIC and CIC gain, the decimation word with its two halfband bits,
// the mux word), streams a tone, and requires
//
//   * the same strobe on every clock - so the same sample rate, and the same
//     latency to the clock
//   * the same 32-bit sample on every strobe - bit for bit
//   * a strobe period of exactly the requested decimation
//   * the same tone level within 0.1 dB (reported; with identical samples it
//     is 0.000) and a level within a decibel of the input, so a chain that
//     is merely identical to a broken reference cannot pass
//
// The two halfband decimators are Xilinx cores upstream.  In the default
// build the reference instantiates this repository's replacements (they are
// checked on their own in tb_hbdec.v); with the vendor netlists at hand
// (`make test-dsp-netlist UHD_FPGA=...`) it instantiates those instead and
// the reference is the complete stock datapath.
//
// +NEG_RATE_REG withholds the decimation word from the dut only, which is
// the defect this bench exists to catch: a chain that does not decode it.
// That run must FAIL; the Makefile checks that it does.  +NCFG=<n> stops
// after the first n configurations, +CFGMASK=<hex> runs only the
// configurations whose bit is set, +NSETTLE=<n> / +NMEAS=<n> shorten a run.
//
// -DPOSTSYN: the dut is not the RTL but the netlist yosys makes of it with
// the build's own flags (a flat module `ddc_chain_syn` without parameters, BASE
// fixed at synthesis).  The hardware runs that netlist, not the RTL, and a
// synthesis tool can get a signed product wrong where every RTL simulation
// is right; this is the same comparison one step closer to the board.
`timescale 1ns/1ps

`ifdef POSTSYN
 `define DUT_NAME "receive chain (yosys netlist)"
`else
 `define DUT_NAME "receive chain"
`endif

module tb_ddc_golden;

   localparam [7:0] BASE = 8'd144;          // SR_RX_DSP in radio_legacy.v
   integer N_SETTLE = 64;                   // output samples before measuring
   integer N_MEAS   = 128;                  // output samples measured
   integer settle;
   localparam real    AMP      = 22938.0;   // 0.7 of the 16-bit ADC word
   localparam real    F_OUT    = 0.11;      // tone, cycles per output sample
   localparam real    TWO_PI   = 6.283185307179586;

   reg clk = 1'b0;
   always #8.138 clk = ~clk;                // 61.44 MHz, the fastest radio clock

   reg         rst = 1'b1;
   reg         run = 1'b0;
   reg         set_stb = 1'b0, set_stb_dut = 1'b0;
   reg  [7:0]  set_addr = 8'd0;
   reg  [31:0] set_data = 32'd0;
   reg  [23:0] fe_i = 24'd0, fe_q = 24'd0;

   wire [31:0] s_ref, s_dut;
   wire        stb_ref, stb_dut;

   ettus_ddc_chain #(.BASE(BASE), .DSPNO(0), .WIDTH(24), .NEW_HB_DECIM(1), .DEVICE("7SERIES")) ref_i
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(fe_i), .rx_fe_q(fe_q),
      .sample(s_ref), .run(run), .strobe(stb_ref), .debug());

`ifdef POSTSYN
   ddc_chain_syn dut_i
`else
   ddc_chain #(.BASE(BASE), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut_i
`endif
     (.clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb_dut), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(fe_i), .rx_fe_q(fe_q),
      .sample(s_dut), .run(run), .strobe(stb_dut), .debug());

   // Upstream leaves the reset input of these four clip_reg instances
   // unconnected.  The vendor synthesiser ties a sourceless input to 0; a
   // simulator leaves it floating and the strobe that passes through turns
   // to X.  Tie them as the synthesiser does.  (The dut connects them.)
   initial begin
      force ref_i.new_hb.unscaled_clip_i.reset = 1'b0;
      force ref_i.new_hb.unscaled_clip_q.reset = 1'b0;
      force ref_i.new_hb.clip_i.reset = 1'b0;
      force ref_i.new_hb.clip_q.reset = 1'b0;
   end

   // The setting registers have a reset but no initial value: 0 in the FPGA,
   // X in a simulator until the first clock edge.  The vendor halfband
   // netlists (when the reference uses them) are gate level and latch that X
   // into control flops no reset reaches.  Start the reference's registers
   // the way the hardware does.
`define POWER_UP(sr) begin sr.out = 0; sr.changed = 1'b0; end
   initial begin
      `POWER_UP(ref_i.sr_0)
      `POWER_UP(ref_i.sr_1)
      `POWER_UP(ref_i.sr_2)
      `POWER_UP(ref_i.sr_3)
      `POWER_UP(ref_i.new_hb.sr_4)
   end

   // ------------------------------------------------------------- settings ---
   task poke(input [7:0] addr, input [31:0] data, input to_dut);
      begin
         @(negedge clk);
         set_addr = addr; set_data = data; set_stb = 1'b1; set_stb_dut = to_dut;
         @(negedge clk);
         set_stb = 1'b0; set_stb_dut = 1'b0;
      end
   endtask

   // The rate table: every decimation the task names, the remaining halfband
   // combinations (one halfband over an odd CIC rate), and the mux bits.
   localparam integer N_CFG = 16;
   reg [9:0]   cfg_total;
   reg [3:0]   cfg_mux;
   reg         cfg_tune;
   task select_cfg(input integer idx);
      begin
         cfg_mux = 4'd0; cfg_tune = 1'b1;
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
           12: cfg_total = 10'd256;
           // mux word: swap, invert Q, invert I; untuned so the tone stays in band
           13: begin cfg_total = 10'd8; cfg_mux = 4'b0001; cfg_tune = 1'b0; end
           14: begin cfg_total = 10'd8; cfg_mux = 4'b0100; cfg_tune = 1'b0; end
           default: begin cfg_total = 10'd4; cfg_mux = 4'b1001; cfg_tune = 1'b0; end
         endcase
      end
   endtask

   // --------------------------------------------------------------- checks ---
   integer n;                              // clocks since run went high
   integer cnt_ref, cnt_dut;               // strobes this run
   integer last_ref, last_dut;             // clock of the previous strobe
   integer pmin_ref, pmax_ref, pmin_dut, pmax_dut;
   integer stb_mis, dat_mis;
   integer meas_ref, meas_dut;
   real    pwr_ref, pwr_dut;
   reg     checking = 1'b0;

   function real sq(input [15:0] v);
      real r;
      begin
         r = $signed(v);
         sq = r * r;
      end
   endfunction

   always @(posedge clk) if (checking) begin
      if (stb_ref !== stb_dut) stb_mis = stb_mis + 1;
      if (stb_ref === 1'b1 && s_ref !== s_dut) dat_mis = dat_mis + 1;
      if (stb_ref === 1'b1) begin
         if (cnt_ref > 0) begin
            if (n - last_ref < pmin_ref) pmin_ref = n - last_ref;
            if (n - last_ref > pmax_ref) pmax_ref = n - last_ref;
         end
         last_ref = n;
         if (cnt_ref >= settle && meas_ref < N_MEAS) begin
            pwr_ref = pwr_ref + sq(s_ref[31:16]) + sq(s_ref[15:0]);
            meas_ref = meas_ref + 1;
         end
         cnt_ref = cnt_ref + 1;
      end
      if (stb_dut === 1'b1) begin
         if (cnt_dut > 0) begin
            if (n - last_dut < pmin_dut) pmin_dut = n - last_dut;
            if (n - last_dut > pmax_dut) pmax_dut = n - last_dut;
         end
         last_dut = n;
         if (cnt_dut >= settle && meas_dut < N_MEAS) begin
            pwr_dut = pwr_dut + sq(s_dut[31:16]) + sq(s_dut[15:0]);
            meas_dut = meas_dut + 1;
         end
         cnt_dut = cnt_dut + 1;
      end
   end

   // ------------------------------------------------------------- stimulus ---
   integer idx, decim, hb0, hb1, scale, freq_word, limit, fails, cfg_fail, seed;
   integer noise_i, noise_q;
   reg [15:0] adc_i, adc_q;
   reg [9:0]  rate_word;
   reg        neg_rate_reg;
   integer    n_cfg, n_run;
   reg [31:0] cfg_mask;
   real    rate_pow, scaling, f_nco, f_in, ph, g_ref, g_dut;

   initial begin
      fails = 0; seed = 32'h0b210ddc;
      neg_rate_reg = $test$plusargs("NEG_RATE_REG");
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

         // rx_dsp_core_3000::set_host_rate / update_scalar / set_freq / set_mux
         decim = cfg_total; hb0 = 0; hb1 = 0;
         if (decim % 2 == 0) begin hb0 = 1; decim = decim / 2; end
         if (decim % 2 == 0) begin hb1 = 1; decim = decim / 2; end
         rate_pow = $pow(1.0 * decim, 4);
         scaling  = $pow(2.0, $ceil($ln(rate_pow) / $ln(2.0))) / (1.648 * rate_pow);
         scale    = $rtoi(65536.0 * scaling + 0.5);
         f_nco    = cfg_tune ? -0.2 : 0.0;                   // cycles per clock
         freq_word = $rtoi(f_nco * 4294967296.0 - (cfg_tune ? 0.5 : 0.0));
         f_in     = F_OUT / cfg_total - f_nco;

         poke(BASE + 8'd0, freq_word, 1'b1);
         poke(BASE + 8'd1, scale, 1'b1);
         rate_word = (hb0 << 9) | (hb1 << 8) | (decim & 255);
         poke(BASE + 8'd2, rate_word, !neg_rate_reg);
         poke(BASE + 8'd3, cfg_mux, 1'b1);
         repeat (8) @(negedge clk);

         n = 0; cnt_ref = 0; cnt_dut = 0; last_ref = 0; last_dut = 0;
         pmin_ref = 1 << 30; pmax_ref = 0; pmin_dut = 1 << 30; pmax_dut = 0;
         stb_mis = 0; dat_mis = 0; meas_ref = 0; meas_dut = 0;
         pwr_ref = 0.0; pwr_dut = 0.0;
         // the chain is some 40 clocks deep whatever the rate: let that pass too
         settle = N_SETTLE + 96 / cfg_total;
         limit = (settle + N_MEAS + 96) * cfg_total + 400;

         run = 1'b1; checking = 1'b1;
         while (n < limit && (meas_ref < N_MEAS || meas_dut < N_MEAS)) begin
            ph = TWO_PI * f_in * n;
            noise_i = ($random(seed) % 9);
            noise_q = ($random(seed) % 9);
            adc_i = $rtoi(AMP * $cos(ph)) + noise_i;
            adc_q = $rtoi(AMP * $sin(ph)) + noise_q;
            fe_i = {adc_i, 8'd0};                // as radio_legacy.v presents the ADC word
            fe_q = {adc_q, 8'd0};
            @(negedge clk);
            n = n + 1;
         end
         run = 1'b0;
         repeat (64) begin @(negedge clk); n = n + 1; end     // let the pipelines drain, still compared
         checking = 1'b0;

         g_ref = (meas_ref > 0) ? 10.0 * $log10(pwr_ref / meas_ref / (AMP * AMP)) : -999.0;
         g_dut = (meas_dut > 0) ? 10.0 * $log10(pwr_dut / meas_dut / (AMP * AMP)) : -999.0;

         cfg_fail = 0;
         if (stb_mis != 0 || dat_mis != 0) cfg_fail = 1;
         if (meas_ref < N_MEAS || meas_dut < N_MEAS) cfg_fail = 1;
         if (pmin_dut != cfg_total || pmax_dut != cfg_total) cfg_fail = 1;
         if (pmin_ref != cfg_total || pmax_ref != cfg_total) cfg_fail = 1;
         if (g_dut - g_ref > 0.1 || g_ref - g_dut > 0.1) cfg_fail = 1;
         if (g_dut > 0.2 || g_dut < -1.2) cfg_fail = 1;
         fails = fails + cfg_fail;

         $display("decim %3d  reg 0x%03x scale %5d mux %b nco %s | period ref %0d..%0d dut %0d..%0d clk | samples ref %0d dut %0d | strobe mismatches %0d, sample mismatches %0d | level ref %7.3f dB dut %7.3f dB, delta %6.3f dB | %s",
                  cfg_total, rate_word, scale, cfg_mux,
                  cfg_tune ? "-0.2" : " 0.0",
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
