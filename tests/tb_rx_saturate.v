// tb_rx_saturate.v - the RX chain's overload corner.
//
// The exhaustive transfer curve (tb_rx_codes) drives I only, so the complex
// envelope never exceeds full scale.  But a strong blocker plus a signal can
// exceed it: with the LO at 45 degrees and I = Q = full scale, the rotated
// component is sqrt(2) x full scale and must SATURATE.  The Ettus chain is
// built for it - the CORDIC carries a guard bit, and the two clip stages
// behind the CIC take the excess - and this bench pins that it holds with the
// registers UHD writes (scale 39767, decimation 1).
//
// Cases (input I = Q = 2047, i.e. full-scale 12-bit):
//   LO at DC   -> I = Q = 32727  (no saturation: 32752 x 0.99925, the CORDIC
//                 gain 1.64676 against the 1.648 in UHD's scale)
//   LO turning -> the rotated I must sit ON the positive rail 32767 for the
//                 part of the turn where the ideal exceeds it
// A wrap shows up immediately as a negative rail value.
`timescale 1ns/1ps

module tb_rx_saturate;

   reg clk = 0; always #5 clk = ~clk;
   reg rst = 1;

   reg        set_stb = 0;
   reg  [7:0] set_addr = 0;
   reg [31:0] set_data = 0;
   reg  [23:0] rx_i = 24'sd2047 << 12, rx_q = 24'sd2047 << 12;
   wire [31:0] sample;
   wire        strobe;
   reg         run = 0;      // streaming starts after the rate is written, as in the radio

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

   integer k, errors = 0, si, sq, peak, trough, rail;

   task meas(output integer oi, output integer oq);
      integer n;
      begin
         repeat (40) @(posedge clk);
         oi = 0; oq = 0;
         for (n = 0; n < 64; n = n + 1) begin
            @(posedge clk); #1;
            oi = oi + $signed(sample[31:16]);
            oq = oq + $signed(sample[15:0]);
         end
         oi = oi / 64; oq = oq / 64;
      end
   endtask

   initial begin
      repeat (8) @(posedge clk);
      @(negedge clk); rst = 0;
      wr(8'd1, 32'd39767);       // UHD scale for CIC rate 1
      wr(8'd2, 32'h001);         // decimation 1, no halfband
      wr(8'd3, 32'h0);

      // LO at DC: no rotation, no saturation
      wr(8'd0, 32'd0);
      run = 1;
      meas(si, sq);
      $display("RX-SAT: LO 0 deg    I %0d Q %0d (expect 32727, 32727)", si, sq);
      if (si < 32725 || si > 32729 || sq < 32725 || sq > 32729) errors = errors + 1;

      // Slow rotation (fs/64): the rotated I component reaches
      // 2047*(cos+sin)*16 = 46 320 at its peak (46 285 after the chain's
      // 0.99925), well past the 16-bit rail, so
      // it must sit ON the rail for the samples where the ideal exceeds it.
      // A wrap would show up as nothing on the positive rail at all.
      wr(8'd0, 32'h0400_0000);
      repeat (40) @(posedge clk);
      peak = 0; trough = 0; rail = 0;
      for (k = 0; k < 128; k = k + 1) begin
         @(posedge clk); #1;
         si = $signed(sample[31:16]);
         if (si > peak) peak = si;
         if (si < trough) trough = si;
         if (si > 32760) rail = rail + 1;
      end
      $display("RX-SAT: LO fs/64   peak %0d trough %0d, %0d samples on the rail",
               peak, trough, rail);
      // the ideal is 2047*16*(cos+sin), which exceeds 32767 for a known
      // fraction of the cycle: the clipped waveform must show a plateau
      if (peak < 32766 || rail < 8 || rail > 40) begin
         errors = errors + 1;
         $display("RX-SAT: FAIL - expected a plateau of 8..40 rail samples, got %0d (peak %0d)",
                  rail, peak);
      end
      if (trough < -32768 || trough > -32760) begin
         errors = errors + 1;
         $display("RX-SAT: FAIL - negative rail wrong (%0d)", trough);
      end

      if (errors == 0)
         $display("RX-SAT: PASS - overload saturates at the rail, never wraps");
      else
         $display("RX-SAT: FAIL - %0d cases wrong", errors);
      $finish;
   end

endmodule
