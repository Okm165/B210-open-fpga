// tb_tx_dc.v - TX DC gain from the host word to the 24-bit pin word, per rate.
//
// The RX side has an exhaustive static curve (tb_rx_codes); this is its TX
// mirror.  A constant host sample runs through a real duc_chain with the LO
// at DC and scale at unity, so every stage is a pure gain and the
// measurement needs no tone, no window and no spectral interpretation.
//
// It locks two facts:
//   * the halfband coefficient sum (65534 vs 65536) produces no measurable
//     DC error: at every power-of-two total rate the gain is 1.00000;
//   * the CIC normalisation contract is visible end to end: total rate 6 and
//     12 give 0.84375 (-1.4757 dB), total 20 gives 0.97650 (-0.2066 dB).
//
// Expected gain per configuration is listed in exp_gain[]; a deviation of
// more than 2e-5 fails the run.
`timescale 1ns/1ps

module tb_tx_dc;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;
   reg [31:0] sample = 32'h03E8_0000;       // I = 1000, Q = 0
   reg        run = 0;

   wire [23:0] tx_fe_i, tx_fe_q;
   wire        strobe;
   wire [31:0] debug;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_fe_i), .tx_fe_q(tx_fe_q),
      .sample(sample), .run(run), .strobe(strobe), .debug(debug));

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clk); set_stb = 0;
      end
   endtask

   integer cfg, k, rate, settle, sum, total, errors;
   reg [7:0] hb;
   real gain, exp_gain;

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      wr(8'd0, 32'd0);                      // LO at DC
      wr(8'd1, 32'h0000_8000);              // scale = unity

      for (cfg = 0; cfg < 9; cfg = cfg + 1) begin
         case (cfg)
           0: begin hb = 2'b00; rate = 1; exp_gain = 1.0;     end
           1: begin hb = 2'b01; rate = 1; exp_gain = 1.0;     end
           2: begin hb = 2'b01; rate = 3; exp_gain = 0.84375; end
           3: begin hb = 2'b11; rate = 1; exp_gain = 1.0;     end
           4: begin hb = 2'b11; rate = 2; exp_gain = 1.0;     end
           5: begin hb = 2'b11; rate = 3; exp_gain = 0.84375; end
           6: begin hb = 2'b11; rate = 4; exp_gain = 1.0;     end
           7: begin hb = 2'b11; rate = 5; exp_gain = 0.97650; end
           8: begin hb = 2'b11; rate = 8; exp_gain = 1.0;     end
         endcase
         total = rate * (hb[0] + 1) * (hb[1] + 1);
         wr(8'd2, {hb, 8'd0} | rate);
         run = 1'b1;
         settle = 512 * rate + 512;
         repeat (settle) @(posedge clk);
         sum = 0;
         for (k = 0; k < 256; k = k + 1) begin
            @(posedge clk); #1;
            sum = sum + $signed(tx_fe_i);
         end
         gain = (sum / 256.0) / 256000.0;   // 1000 * 256 = full-scale unity
         $display("TX-DC: halfbands %0d%0d CIC %0d total %2d gain %.5f (%.4f dB)",
                  hb[1], hb[0], rate, total, gain, 20.0*$log10(gain));
         if (gain > exp_gain + 2e-5 || gain < exp_gain - 2e-5) begin
            errors = errors + 1;
            $display("TX-DC: FAIL at total %0d: %.5f, expected %.5f",
                     total, gain, exp_gain);
         end
         run = 1'b0;
         repeat (64) @(posedge clk);
      end

      if (errors == 0)
         $display("TX-DC: PASS - unity DC gain at every power-of-two rate, CIC contract elsewhere");
      else
         $display("TX-DC: FAIL - %0d configurations wrong", errors);
      $finish;
   end

endmodule
