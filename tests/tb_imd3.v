// tb_imd3.v - two-tone intermodulation through the complete TX->RX datapath.
//
// A single-tone test cannot see a nonlinearity: a memoryless odd nonlinearity
// leaves the fundamental alone and creates 2f1-f2 and 2f2-f1.  Two tones are
// the standard SDR distortion measurement, and the receive chain's design
// choice (one dithered quantiser with first-order error feedback instead of a
// cascade of deterministic roundings) was made specifically to avoid the
// third-order products the old cascade produced at -67 dBc.
//
// This bench drives a complex two-tone into the TX chain (bypass, LO 0), wires
// the 24-bit pin word into the RX chain (LO 0), and measures the bins
//   f1, f2, 2f1-f2, 2f2-f1
// with one coherent DFT over 1024 clocks.  It measures the INPUT two-tone with
// the same DFT, so the stimulus generator's own truncation spurs can be told
// apart from the datapath's contribution.
//
// Sweeping the level is the physics: a linear system's IMD3 in dBc does not
// change with level; a nonlinear one degrades as the signal grows.
`timescale 1ns/1ps

module tb_imd3;

   localparam integer L  = 1024;
   localparam integer K1 = 64;     // f1 = 64/1024 fs
   localparam integer K2 = 72;     // f2 = 72/1024 fs
   localparam integer KI1 = 2*64 - 72;   // 56  = 2f1-f2
   localparam integer KI2 = 2*72 - 64;   // 80  = 2f2-f1

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        t_stb = 0; reg [7:0] t_addr = 0; reg [31:0] t_data = 0;
   reg        r_stb = 0; reg [7:0] r_addr = 0; reg [31:0] r_data = 0;
   reg  [31:0] tx_sample = 0;
   wire [23:0] tx_i, tx_q;
   wire        tx_strobe;
   wire [31:0] tx_debug;
   wire [31:0] rx_sample;
   wire        rx_strobe;

   duc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) tx (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(t_stb), .set_addr(t_addr), .set_data(t_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
      .sample(tx_sample), .run(1'b1), .strobe(tx_strobe), .debug(tx_debug));

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) rx (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(r_stb), .set_addr(r_addr), .set_data(r_data),
      .rx_fe_i(tx_i), .rx_fe_q(tx_q),
      .sample(rx_sample), .run(1'b1), .strobe(rx_strobe), .debug());

   task twr(input [7:0] a, input [31:0] d);
      begin @(negedge clk); t_stb=1; t_addr=a; t_data=d;
            @(negedge clk); t_stb=0; end
   endtask
   task rwr(input [7:0] a, input [31:0] d);
      begin @(negedge clk); r_stb=1; r_addr=a; r_data=d;
            @(negedge clk); r_stb=0; end
   endtask

   // two-tone generator, one new host sample per clock (bypass)
   integer amp = 3000;
   integer pn = 0;
   real    th1, th2, si, sq;
   always @(negedge clk) begin
      th1 = 2.0*3.14159265358979323846*K1*pn/L;
      th2 = 2.0*3.14159265358979323846*K2*pn/L;
      si = amp*($cos(th1) + $cos(th2));
      sq = amp*($sin(th1) + $sin(th2));
      tx_sample[31:16] <= $floor(si + 0.5);
      tx_sample[15:0]  <= $floor(sq + 0.5);
      pn <= (pn == L-1) ? 0 : pn + 1;
   end

   // complex amplitude at an arbitrary bin, for the input or the output word
   task bin(input integer which, input integer k, output real mag);
      integer n; real ar, ai, vi, vq, th;
      begin
         ar = 0.0; ai = 0.0;
         for (n = 0; n < L; n = n + 1) begin
            @(posedge clk); #1;
            if (which == 0) begin
               vi = $itor($signed(tx_sample[31:16]));
               vq = $itor($signed(tx_sample[15:0]));
            end else begin
               vi = $itor($signed(rx_sample[31:16]));
               vq = $itor($signed(rx_sample[15:0]));
            end
            th = 2.0*3.14159265358979323846*k*n/L;
            ar = ar + vi*$cos(th) + vq*$sin(th);
            ai = ai + vq*$cos(th) - vi*$sin(th);
         end
         mag = $sqrt(ar*ar + ai*ai) / L;
      end
   endtask

   // one pass measuring all four bins for a selected source
   task spectrum(input integer which,
                 output real m1, output real m2,
                 output real mi1, output real mi2);
      integer n; real ar, ai, br, bi, cr, ci, dr, di;
      real vi, vq, a, b;
      begin
         ar=0.0; ai=0.0; br=0.0; bi=0.0; cr=0.0; ci=0.0; dr=0.0; di=0.0;
         for (n = 0; n < L; n = n + 1) begin
            @(posedge clk); #1;
            if (which == 0) begin
               vi = $itor($signed(tx_sample[31:16]));
               vq = $itor($signed(tx_sample[15:0]));
            end else begin
               vi = $itor($signed(rx_sample[31:16]));
               vq = $itor($signed(rx_sample[15:0]));
            end
            a = 2.0*3.14159265358979323846*K1*n/L;
            b = 2.0*3.14159265358979323846*K2*n/L;
            ar = ar + vi*$cos(a) + vq*$sin(a);
            ai = ai + vq*$cos(a) - vi*$sin(a);
            br = br + vi*$cos(b) + vq*$sin(b);
            bi = bi + vq*$cos(b) - vi*$sin(b);
            // 2f1-f2
            a = 2.0*3.14159265358979323846*(2*K1-K2)*n/L;
            cr = cr + vi*$cos(a) + vq*$sin(a);
            ci = ci + vq*$cos(a) - vi*$sin(a);
            // 2f2-f1
            b = 2.0*3.14159265358979323846*(2*K2-K1)*n/L;
            dr = dr + vi*$cos(b) + vq*$sin(b);
            di = di + vq*$cos(b) - vi*$sin(b);
         end
         m1  = $sqrt(ar*ar + ai*ai) / L;
         m2  = $sqrt(br*br + bi*bi) / L;
         mi1 = $sqrt(cr*cr + ci*ci) / L;
         mi2 = $sqrt(dr*dr + di*di) / L;
      end
   endtask

   integer a_idx, errors;
   real i1, i2, ii1, ii2, o1, o2, oi1, oi2;
   real imd_in, imd_out, gain_db, worst;

   initial begin
      errors = 0;
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      twr(8'd0, 32'd0); twr(8'd1, 32'h0000_8000); twr(8'd2, 32'd1);
      rwr(8'd0, 32'd0); rwr(8'd3, 32'd0);

      for (a_idx = 0; a_idx < 6; a_idx = a_idx + 1) begin
         case (a_idx)
           0: amp = 300;     // ~ -40 dBFS per tone
           1: amp = 1000;    // ~ -30 dBFS
           2: amp = 3000;    // ~ -21 dBFS
           3: amp = 8000;    // ~ -12 dBFS (peak envelope 16000)
           4: amp = 12000;   // peak envelope 24000
           5: amp = 15500;   // peak envelope 31000, just below the 32768 rail
         endcase
         repeat (600) @(posedge clk);

         spectrum(0, i1, i2, ii1, ii2);           // input two-tone
         imd_in  = 20.0*$log10(((ii1 > ii2 ? ii1 : ii2) + 1.0e-9) /
                               (((i1+i2)/2.0) + 1.0e-9));
         spectrum(1, o1, o2, oi1, oi2);           // through the datapath
         imd_out = 20.0*$log10(((oi1 > oi2 ? oi1 : oi2) + 1.0e-9) /
                               (((o1+o2)/2.0) + 1.0e-9));
         gain_db = 20.0*$log10(((o1+o2)/2.0) / (((i1+i2)/2.0) + 1.0e-9));

         $display("IMD3: amp %5d gain %+.5f dB  stim %6.1f dBc  out %6.1f dBc  vs stim %+.1f dB",
                  amp, gain_db, imd_in, imd_out, imd_out - imd_in);

         // Absolute floor: the digital products must sit well below the
         // converters' own IMD (a 12-bit converter is typically -70..-80 dBc).
         if (imd_out > -80.0) begin
            errors = errors + 1;
            $display("  FAIL: output IMD3 above -80 dBc");
         end
         // Linearity: a nonlinear chain gets *worse* as the level rises.  This
         // one must not grow by more than 3 dB from the lowest level.
         if (a_idx == 0) worst = imd_out;
         if (imd_out > worst + 3.0) begin
            errors = errors + 1;
            $display("  FAIL: IMD3 grows with level (nonlinear)");
         end
      end

      if (errors == 0)
         $display("IMD3: PASS - two-tone products stay at the stimulus/dither floor and do not grow with level");
      else
         $display("IMD3: FAIL - %0d checks wrong", errors);
      $finish;
   end

endmodule
