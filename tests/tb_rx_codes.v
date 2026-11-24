// tb_rx_codes.v - the RX datapath's static transfer curve, exhaustively.
//
// Every one of the 4096 possible ADC words is driven through a real
// ddc_chain with the LO parked at DC (phase_inc = 0, so cos = 1, sin = 0)
// and left-justified exactly as radio_legacy feeds it: the 12-bit word sits
// in the top 12 bits of the 24-bit port, which is what makes sign handling
// implicit and needs no sign-extension code at the pin boundary.
//
// With the LO at DC, decimation 1 and the scale word UHD writes (39767) the
// chain is a pure static gain, so this measures the whole receive datapath's
// number handling end to end:
//
//   * gain 16 x 0.99925 LSB16 per ADC LSB: 16 is the 4-bit left justify,
//     0.99925 the CORDIC's 1.64676 against the 1.648 in UHD's scale word,
//   * no code-dependent bias beyond the chain's one deterministic rounding
//     (to 19 bits ahead of the scale multiplier, +-0.15 LSB16); the output
//     rounder is a first-order sigma-delta, so the mean carries no more,
//   * no saturation at either rail,
//   * Q stays within a fraction of an LSB16 of zero (the CORDIC's residual
//     angle and truncation).
//
// It also pins the four measured I/Q control bits (BASE+3): 1 = swap,
// 2 = realmode (Q zeroed), 4 = invert_q, 8 = invert_i.
//
// Every measurement is checked for X first: a comparison against X is false,
// and a bench that only compares would pass on a chain that produced nothing.
`timescale 1ns/1ps

module tb_rx_codes;

   localparam integer NAVE   = 256;
   localparam real    TOL    = 0.5;       // LSB16 on the mean of NAVE samples
   localparam real    QTOL   = 0.50;      // LSB16 on the undriven channel
   localparam real    G      = 0.999248;  // 1.646760258 * 39767 / 65536

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;

   reg  [23:0] rx_i = 0, rx_q = 0;
   wire [31:0] sample;
   wire        strobe;
   reg         run = 0;      // streaming starts after the rate is written, as in the radio
   integer     nundef = 0;   // measured samples that were X or not strobed

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
      .sample(sample), .run(run), .strobe(strobe), .debug());

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
            if ((^sample) === 1'bx || strobe !== 1'b1) nundef = nundef + 1;
            oi = oi + $signed(sample[31:16]);
            oq = oq + $signed(sample[15:0]);
         end
      end
   endtask

   integer code, k, si, sq, adc;
   integer worst_code, errors, qmax;
   real    err, worst_err;
   integer lo_mean, hi_mean, gain_x4095;
   integer mi, mq;

   initial begin
      errors = 0; worst_err = 0.0; worst_code = 0; qmax = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      wr(8'd0, 32'd0);                       // LO at DC
      wr(8'd1, 32'd39767);                   // the scale UHD writes at CIC rate 1
      wr(8'd2, 32'h001);                     // decimation 1, no halfband
      wr(8'd3, 32'h0);                       // no swap, complex, no invert
      run = 1'b1;
      repeat (64) @(posedge clk);

      for (code = 0; code < 4096; code = code + 1) begin
         adc  = (code < 2048) ? code : (code - 4096);
         rx_i = (code < 2048) ? (code << 12) : ((code - 4096) << 12);
         rx_q = 24'sd0;
         meas(si, sq);

         err = si / (NAVE * 1.0) - 16.0 * G * adc;
         if (err < 0) err = -err;
         if (err > worst_err) begin worst_err = err; worst_code = code; end
         if (err > TOL) begin
            errors = errors + 1;
            if (errors < 4)
               $display("FAIL: code %0d (adc %0d) mean %0.3f LSB16, expected %0.3f",
                        code, adc, si/(NAVE*1.0), 16.0*G*adc);
         end
         if (sq < 0) k = -sq; else k = sq;
         if (k > qmax) qmax = k;

         if (code == 2047) hi_mean = si;
         if (code == 2048) lo_mean = si;
      end

      gain_x4095 = (hi_mean - lo_mean) / NAVE;  // 16 x 0.999248 LSB16/LSB x 4095 codes
      if (gain_x4095 < 65468 || gain_x4095 > 65474) begin   // 65470.7
         errors = errors + 1;
         $display("FAIL: gain %0d/4095 LSB16 per ADC LSB (expected 65471 = 15.988)",
                  gain_x4095);
      end
      if (qmax > QTOL * NAVE) begin
         errors = errors + 1;
         $display("FAIL: quiet channel is not quiet: worst mean %0.4f LSB16",
                  qmax/(NAVE*1.0));
      end

      // The four I/Q control bits, measured (BASE+3 = {invert_i,invert_q,
      // realmode,swap_iq} on a 4-bit setting_reg, so LSB first).
      rx_i = 24'sd1000 << 12;                 // output 16000 * G = 15988.0
      rx_q = 24'sd500  << 12;                 // output  8000 * G =  7994.0

      wr(8'd3, 32'h1); meas(mi, mq);
      $display("MUX bit0=swap     I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 7993*NAVE || mi > 7995*NAVE || mq < 15987*NAVE || mq > 15989*NAVE) errors = errors + 1;

      wr(8'd3, 32'h2); meas(mi, mq);
      $display("MUX bit1=realmode I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 15987*NAVE || mi > 15989*NAVE || mq < -1*NAVE || mq > 1*NAVE) errors = errors + 1;

      wr(8'd3, 32'h4); meas(mi, mq);
      $display("MUX bit2=invert_q I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < 15987*NAVE || mi > 15989*NAVE || mq < -7995*NAVE || mq > -7993*NAVE) errors = errors + 1;

      wr(8'd3, 32'h8); meas(mi, mq);
      $display("MUX bit3=invert_i I %8.3f Q %8.3f", mi/(NAVE*1.0), mq/(NAVE*1.0));
      if (mi < -15989*NAVE || mi > -15987*NAVE || mq < 7993*NAVE || mq > 7995*NAVE) errors = errors + 1;

      if (nundef != 0) begin
         errors = errors + 1;
         $display("FAIL: %0d samples were X or not strobed", nundef);
      end

      if (errors == 0) begin
         $display("RX-CODES: PASS - 4096 codes, worst |error| %0.3f LSB16 at code %0d,",
                  worst_err, worst_code);
         $display("RX-CODES: PASS - gain %0.5f LSB16/ADC-LSB, quiet channel <= %0.4f LSB16 rms",
                  gain_x4095/4095.0, qmax/(NAVE*1.0));
      end else
         $display("RX-CODES: FAIL - %0d checks failed", errors);
      $finish;
   end

endmodule
