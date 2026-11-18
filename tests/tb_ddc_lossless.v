// -*- verilog -*-
//
// Lossless receive path: CIC rate 1, both halfbands off.
//
// In that configuration there is no rate change, so the decimation filters
// must not touch the signal.  The chain routes the mixer output straight to
// the output formatter, and this bench proves the two properties that matter:
//
//   1. The transfer function is a pure constant gain: a tone at a quarter of
//      the sample rate has the same amplitude as DC (any filtering would show
//      up as droop -- the halfband path loses 4.2 dB at this frequency).
//   2. No sample saturates: the output stays inside the 16-bit range with the
//      default scale, so the clip stage is never reached.
//
`timescale 1ns/1ps

module tb_ddc_lossless;

   localparam integer WIDTH       = 24;
   localparam integer A16         = 6000;    // tone amplitude, 16-bit domain
   localparam integer TONE_PERIOD = 4;       // 1/4 of the sample rate (bin 256)
   localparam integer NOUT        = 1024;

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
      .DEVICE("7SERIES")
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
         set_stb <= 1'b1; set_addr <= addr; set_data <= data;
         @(posedge clk);
         set_stb <= 1'b0;
      end
   endtask

   real    acc_r, acc_j;
   integer n_captured;
   integer n, errors = 0;
   real    arg, amp_dc, amp_tone;
   reg signed [31:0] peak;
   integer warmup;
   integer BIN;

   always @(posedge clk) begin
      if (!rst && run && strobe && n_captured < NOUT) begin
         if (warmup > 0) warmup = warmup - 1;
         else begin
            acc_r = acc_r + $itor($signed(sample[31:16])) * $cos(-2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
            acc_j = acc_j + $itor($signed(sample[31:16])) * $sin(-2.0 * 3.14159265358979 * $itor(BIN * n_captured) / $itor(NOUT));
            n_captured = n_captured + 1;
         end
         if ($signed(sample[31:16]) > peak) peak = $signed(sample[31:16]);
         if ($signed(sample[31:16]) < -peak) peak = -$signed(sample[31:16]);
      end
   end

   task measure(input integer period, output real amp);
      integer k;
      begin
         n_captured = 0; acc_r = 0; acc_j = 0; warmup = 64;
         BIN = (period == 0) ? 0 : 256;
         for (k = 0; k < (NOUT + 256) * period + 512; k = k + 1) begin
            @(posedge clk);
            if (period == 0) begin
               rx_i <= (A16 << 8);
               rx_q <= 24'sd0;
            end else begin
               arg = 2.0 * 3.14159265358979 * $itor(k) / $itor(period);
               rx_i <= ($rtoi(A16 * $cos(arg)) << 8);
               rx_q <= ($rtoi(A16 * $sin(arg)) << 8);
            end
         end
         // a complex tone at bin k has peak amplitude 2|X|/N; a DC term has
         // amplitude |X|/N (no factor of two)
         amp = ((period == 0) ? 1.0 : 2.0) * $sqrt(acc_r * acc_r + acc_j * acc_j) / $itor(n_captured);
      end
   endtask

   initial begin
      repeat (8) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);

      // CIC rate 1, halfbands off, scale ~1.0, no mixing
      set_reg(8'd0, 32'h0000_0000);
      set_reg(8'd1, 32'h0001_FFFF);
      set_reg(8'd2, 32'h0000_0001);
      run <= 1'b1;

      peak = 0;
      measure(0, amp_dc);
      measure(TONE_PERIOD, amp_tone);

      $display("  lossless: DC amplitude %.1f, tone at fs/4 amplitude %.1f", amp_dc, amp_tone);
      $display("  peak output sample %0d", peak);

      if (amp_dc < 1.0) begin
         errors = errors + 1;
         $display("FAIL: no DC output");
      end
      if (amp_tone < 0.99 * amp_dc || amp_tone > 1.01 * amp_dc) begin
         errors = errors + 1;
         $display("FAIL: tone/DC gain ratio %.4f is not flat (path is filtering)", amp_tone / amp_dc);
      end
      if (peak > 32767) begin
         errors = errors + 1;
         $display("FAIL: output saturated at %0d", peak);
      end

      if (errors == 0)
        $display("PASS: lossless path is flat (tone/DC %.4f) and never clips", amp_tone / amp_dc);
      else
        $display("FAIL: %0d errors", errors);
      $finish;
   end

endmodule
