// tb_rx_codes.v - the RX datapath's static transfer curve, exhaustively.
//
// Every one of the 4096 possible ADC words is driven through a real
// ddc_chain with the LO parked at DC (phase_inc = 0, so cos = 1, sin = 0)
// and left-justified exactly as radio_legacy feeds it: the 12-bit word sits
// in the top 12 bits of the 24-bit port, which is what makes sign handling
// implicit and needs no sign-extension code at the pin boundary.
//
// With the LO at DC the chain is a pure static gain, so this measures the
// whole receive datapath's number handling end to end:
//
//   * unity transfer, gain 16 LSB16 per ADC LSB (the 4-bit left justify),
//   * no code-dependent bias: the error is the quantiser's own +-1 LSB16
//     triangular dither plus first-order shaping, nothing else,
//   * no saturation at either rail,
//   * Q carries dither only, because sin(0) is exactly 0.
//
// It also pins the four measured I/Q control bits (BASE+3): 1 = swap,
// 2 = realmode (Q zeroed), 4 = invert_q, 8 = invert_i, and that the
// one's-complement inversion is accurate to the dither floor.
`timescale 1ns/1ps

module tb_rx_codes;

   localparam integer NAVE   = 256;
   localparam integer TOL    = 2;         // LSB16: dither is +-1, shaping adds a little
   localparam real    QTOL   = 0.50;      // LSB16: dither walk on the undriven channel

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;

   reg  [23:0] rx_i = 0, rx_q = 0;
   wire [31:0] sample;
   wire        strobe;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
      .sample(sample), .run(1'b1), .strobe(strobe), .debug());

   task wr(input [7:0] a, input [31:0] d);
      begin
         @(negedge clk); set_stb = 1; set_addr = a; set_data = d;
         @(negedge clk); set_stb = 0;
      end
   endtask

   task meas(output integer oi, output integer oq);
      integer k;
      begin
         repeat (40) @(posedge clk);
         oi = 0; oq = 0;
         for (k = 0; k < NAVE; k = k + 1) begin
            @(posedge clk); #1;
            oi = oi + $signed(sample[31:16]);
            oq = oq + $signed(sample[15:0]);
         end
      end
   endtask

   integer code, k, si, sq, adc, err;
   integer worst_err, worst_code, errors, qmax;
   integer lo_mean, hi_mean, gain_x4095;
   integer mi, mq;

   initial begin
      errors = 0; worst_err = 0; worst_code = 0; qmax = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      wr(8'd0, 32'd0);                       // LO at DC
      wr(8'd3, 32'h0);                       // no swap, complex, no invert
      repeat (16) @(posedge clk);

      for (code = 0; code < 4096; code = code + 1) begin
         adc  = (code < 2048) ? code : (code - 4096);
         rx_i = (code < 2048) ? (code << 12) : ((code - 4096) << 12);
         rx_q = 24'sd0;
         meas(si, sq);

         err = si - NAVE * 16 * adc;         // exact integer residual
         if (err < 0) err = -err;
         if (err > worst_err) begin worst_err = err; worst_code = code; end
         if (err > TOL * NAVE) begin
            errors = errors + 1;
            if (errors < 4)
               $display("FAIL: code %0d (adc %0d) mean %0.3f LSB16, expected %0d",
                        code, adc, si/(NAVE*1.0), 16*adc);
         end
         if (sq < 0) k = -sq; else k = sq;
         if (k > qmax) qmax = k;

         if (code == 2047) hi_mean = si;
         if (code == 2048) lo_mean = si;
      end

      gain_x4095 = (hi_mean - lo_mean) / NAVE;  // 16 LSB16/LSB x 4095 codes
      if (gain_x4095 < 65479 || gain_x4095 > 65520) begin   // 15.99 .. 16.00
         errors = errors + 1;
         $display("FAIL: gain %0d/4095 LSB16 per ADC LSB (expected 65520 = 16.0)",
                  gain_x4095);
      end
      if (qmax > QTOL * NAVE) begin
         errors = errors + 1;
         $display("FAIL: quiet channel is not quiet: worst mean %0.4f LSB16",
                  qmax/(NAVE*1.0));
      end

      // The four I/Q control bits, measured (BASE+3 = {invert_i,invert_q,
      // realmode,swap_iq} on a 4-bit setting_reg, so LSB first).
      rx_i = 24'sd1000 << 12;                 // exact output 16000
      rx_q = 24'sd500  << 12;                 // exact output  8000

      wr(8'd3, 32'h1); meas(mi, mq);
      $display("MUX bit0=swap     I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 7999*NAVE || mi > 8001*NAVE || mq < 15999*NAVE || mq > 16001*NAVE) errors = errors + 1;

      wr(8'd3, 32'h2); meas(mi, mq);
      $display("MUX bit1=realmode I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 15999*NAVE || mi > 16001*NAVE || mq < -1*NAVE || mq > 1*NAVE) errors = errors + 1;

      wr(8'd3, 32'h4); meas(mi, mq);
      $display("MUX bit2=invert_q I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 15999*NAVE || mi > 16001*NAVE || mq < -8001*NAVE || mq > -7999*NAVE) errors = errors + 1;

      wr(8'd3, 32'h8); meas(mi, mq);
      $display("MUX bit3=invert_i I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < -16001*NAVE || mi > -15999*NAVE || mq < 7999*NAVE || mq > 8001*NAVE) errors = errors + 1;

      if (errors == 0) begin
         $display("RX-CODES: PASS - 4096 codes, worst |error| %0.3f LSB16 at code %0d,",
                  worst_err/(NAVE*1.0), worst_code);
         $display("RX-CODES: PASS - gain %0.5f LSB16/ADC-LSB, quiet channel <= %0.4f LSB16 rms",
                  gain_x4095/4095.0, qmax/(NAVE*1.0));
      end else
         $display("RX-CODES: FAIL - %0d checks failed", errors);
      $finish;
   end

endmodule
