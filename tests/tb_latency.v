// tb_latency.v - measured latency of both datapaths, in clocks and in samples.
//
// RX: a step from 0 to 2000 ADC codes into ddc_chain (LO at DC, decimation 1,
// the scale UHD writes); measure the clock at which the 16-bit output first
// exceeds half of its final value.  That is what the host sees: sample in ->
// sample out.
//
// TX: the same step into duc_chain (LO at DC, the scale UHD writes) for each
// interpolation configuration, measured at tx_fe_i.  The delay is pipeline
// registers plus the halfband and CIC group delay, so it is reported in clock
// cycles (the converter's time base) and in input sample periods (the host's
// time base).
//
// Why this exists: the digital part of "group delay / MIMO alignment" is
// exactly measurable here; only cable and converter delays remain for
// hardware.  Both radios run identical RTL on identical clocks, so channel A
// and channel B have the same digital delay by construction.
//
// The delays are those of the stock Ettus chain (tb_ddc_golden and
// tb_duc_golden hold this design to that chain clock for clock), so the
// bounds here only say what the numbers are; they are deliberately loose.
// Measured: RX 39 clocks at decimation 1 (the CORDIC alone is 21 stages); TX
// half-value delay 34.0, 33.5, 31.5, 26.0, 22.8, 21.4 input samples at total
// rates 1, 2, 4, 8, 16, 32.
`timescale 1ns/1ps

module tb_latency;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   // ---------------- RX ----------------
   reg        r_stb = 0;
   reg  [7:0] r_addr = 0;
   reg [31:0] r_data = 0;
   reg  [23:0] rx_i = 0, rx_q = 0;
   wire [31:0] rx_sample;
   wire        rx_strobe;
   reg         rx_run = 0;     // streaming starts after the rate is written, as in the radio

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r_stb), .set_addr(r_addr), .set_data(r_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
      .sample(rx_sample), .run(rx_run), .strobe(rx_strobe), .debug());

   // ---------------- TX ----------------
   reg        t_stb = 0;
   reg  [7:0] t_addr = 0;
   reg [31:0] t_data = 0;
   reg [31:0] tx_sample = 0;
   reg        tx_run = 0;
   wire [23:0] tx_i, tx_q;
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

   integer k, onset, rate, total, cfg, errors;
   integer t_onset, t_half;
   real tx_delay_samples;
   reg [7:0] hb;

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;

      // ---- RX: LO at DC, step input ----
      rwr(8'd0, 32'd0);
      rwr(8'd1, 32'd39767);      // UHD scale for CIC rate 1
      rwr(8'd2, 32'h001);        // decimation 1
      rwr(8'd3, 32'h0);
      rx_run = 1'b1;
      repeat (64) @(posedge clk);
      @(negedge clk); rx_i = 24'd2000 << 12;
      onset = -1;
      for (k = 0; k < 80; k = k + 1) begin
         @(posedge clk); #1;
         if (onset < 0 && $signed(rx_sample[31:16]) > 1000) onset = k;
      end
      $display("LATENCY: RX %0d clocks, sample in -> sample out (half of final value)", onset + 1);
      if (onset + 1 < 35 || onset + 1 > 43) begin
         errors = errors + 1;
         $display("LATENCY: FAIL - RX delay %0d clocks outside 35..43", onset + 1);
      end

      // ---- TX ----
      twr(8'd0, 32'd0);
      twr(8'd1, 32'd39767);      // UHD scale at these (power-of-two) CIC rates
      for (cfg = 0; cfg < 6; cfg = cfg + 1) begin
         case (cfg)
           0: begin hb = 2'b00; rate = 1; end
           1: begin hb = 2'b01; rate = 1; end
           2: begin hb = 2'b11; rate = 1; end
           3: begin hb = 2'b11; rate = 2; end
           4: begin hb = 2'b11; rate = 4; end
           5: begin hb = 2'b11; rate = 8; end
         endcase
         total = rate * (hb[0] + 1) * (hb[1] + 1);
         twr(8'd2, {hb, 8'd0} | rate);
         tx_run = 1'b1;
         tx_sample = 0;
         repeat (512 * rate + 512) @(posedge clk);
         @(negedge clk); tx_sample = 32'd1000 << 16;
         t_onset = -1; t_half = -1;
         for (k = 0; k < 2048 * rate + 256; k = k + 1) begin
            @(posedge clk); #1;
            if (t_onset < 0 && $signed(tx_i) > 1000) t_onset = k;
            if (t_half  < 0 && $signed(tx_i) > 128000) t_half = k;
         end
         tx_delay_samples = (t_half + 1.0) / total;
         $display("LATENCY: TX halfbands %0d%0d CIC %0d total %2d: half %0d clk = %0.2f input samples",
                  hb[1], hb[0], rate, total, t_half + 1, tx_delay_samples);
         if (tx_delay_samples < 18.0 || tx_delay_samples > 38.0) begin
            errors = errors + 1;
            $display("LATENCY: FAIL - TX delay %0.2f samples outside 18..38", tx_delay_samples);
         end
         tx_run = 1'b0;
         repeat (64) @(posedge clk);
      end

      if (errors == 0)
         $display("LATENCY: PASS - digital delay measured and within bounds at every rate");
      else
         $display("LATENCY: FAIL - %0d checks failed", errors);
      $finish;
   end

endmodule
