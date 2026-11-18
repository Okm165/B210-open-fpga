// tb_cordic_overflow.v - the TX rotator at and beyond full scale.
//
// cordic_z24 carries bitwidth+2 bits through 19 stages and narrows back to
// bitwidth at the end.  A bare slice drops the guard bit, so a rotated vector
// larger than full scale used to WRAP - a sign inversion, the worst possible
// failure mode, and exactly what the DUC header warns about at 1.22x amplitude.
// The output now saturates at the rail instead.
//
// Two properties are checked:
//   A. corner input at full scale (|v| = sqrt(2) x full scale), rotating once:
//      no wrap.  A wrap appears as a step of order full scale between adjacent
//      samples of a slowly rotating vector; a saturated but continuous signal
//      never steps further than one sample of the ideal rotation.
//   B. small input, rotating: the output still matches the ideal rotation, so
//      the saturation cannot have changed normal operation.  The pipeline
//      latency is MEASURED here (best match over a range of candidate delays)
//      rather than assumed, and reported.
`timescale 1ns/1ps

module tb_cordic_overflow;

   localparam integer W      = 24;
   localparam integer FULL   = (1 << (W-1));
   localparam integer N      = 4096;
   localparam integer MAXL   = 64;          // latency search range

   reg clk = 0; always #8.138 clk = ~clk;
   reg rst = 1, en = 1;
   reg signed [W-1:0] xi = 0, yi = 0;
   reg [23:0] zi = 0;
   wire signed [W-1:0] xo, yo;
   wire [23:0] zo;

   cordic_z24 #(.bitwidth(W)) dut
     (.clock(clk), .reset(rst), .enable(en),
      .xi(xi), .yi(yi), .zi(zi), .xo(xo), .yo(yo), .zo(zo));

   integer m, lat, best_lat, err, best_err, worst, jumps, sat, di, dq, px, py;
   real th, g;
   reg signed [W-1:0] capx [0:N+MAXL];
   reg signed [W-1:0] capy [0:N+MAXL];

   // Drive one sample.  The output register value present when the sample is
   // launched is captured under the same index, so a fixed pipeline delay is
   // absorbed by the latency search in phase B.
   task step(input signed [W-1:0] x, input signed [W-1:0] y, input integer ph);
      begin
         @(posedge clk);
         capx[m] = xo;
         capy[m] = yo;
         xi <= x;
         yi <= y;
         zi <= ph * (1 <<< 12);            // one revolution over N samples
         m = m + 1;
      end
   endtask

   initial begin
      repeat (5) @(posedge clk); rst <= 0; repeat (40) @(posedge clk);

      // ---- A: corner at full scale, one revolution -------------------------
      m = 0; jumps = 0; worst = 0; sat = 0; px = 0; py = 0;
      while (m < N) begin
         step(FULL-1, FULL-1, m);
         if (m > MAXL + 2) begin
            di = xo - px; if (di < 0) di = -di;
            dq = yo - py; if (dq < 0) dq = -dq;
            if (di > worst) worst = di;
            if (dq > worst) worst = dq;
            if (di > FULL/8 || dq > FULL/8) jumps = jumps + 1;
            if (xo >= FULL-1 || yo >= FULL-1 ||
                xo <= -FULL  || yo <= -FULL ) sat = sat + 1;
         end
         px = xo; py = yo;
      end
      // One sample of the ideal rotation moves a component by at most
      // 1.6468 * (FULL-1) * 2*pi/N = 21 218 counts when both inputs are at the
      // rail; a wrap is 8 388 608 counts.  Allow 2x for the corner geometry.
      $display("CORDIC: corner: %0d jumps (wrap), worst step %0d of %0d, %0d saturated samples",
               jumps, worst, FULL, sat);
      if (jumps != 0)
         $display("CORDIC: FAIL - the rotator wrapped");
      else if (worst > 45000)
         $display("CORDIC: FAIL - output steps by %0d counts between samples", worst);
      else if (sat < 100)
         $display("CORDIC: FAIL - the corner case never exercised the rail");

      // ---- B: small input, rotating, latency measured then error checked --
      g = 0.8233899;                        // prod sqrt(1+2^-2i) / 2
      m = 0;
      while (m < N + MAXL)
         step(100000, 0, m);
      best_lat = 0; best_err = 1 << 30;
      for (lat = 1; lat <= MAXL; lat = lat + 1) begin
         err = 0;
         for (m = MAXL; m < N; m = m + 1) begin
            th = 2.0*3.14159265358979*(m-lat)/N;
            di = capx[m] - $rtoi(g*100000.0*$cos(th)); if (di < 0) di = -di;
            dq = capy[m] - $rtoi(g*100000.0*$sin(th)); if (dq < 0) dq = -dq;
            if (di > err) err = di;
            if (dq > err) err = dq;
         end
         if (err < best_err) begin best_err = err; best_lat = lat;
            $display("CORDIC: latency %0d: worst error %0d LSB", lat, err);
         end
      end
      $display("CORDIC: small signal: latency %0d, worst error %0d LSB of %0d full scale",
               best_lat, best_err, FULL);
      if (best_err > 400)
         $display("CORDIC: FAIL - normal rotation changed (error %0d)", best_err);
      else if (jumps == 0 && worst <= 45000 && sat >= 100)
         $display("CORDIC: PASS - saturates at the rail, never wraps, normal rotation intact");
      $finish;
   end

endmodule
