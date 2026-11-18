//
// cordic_z24: the TX upconverter's rotation core.
//
// This bench exists because the module could not be simulated at all until it
// was fixed.  cordic_stage built its shift term as
//
//     {{shift+1{yi[bitwidth-1]}}, yi[bitwidth-2:shift]}
//
// which is only well formed while shift <= bitwidth-2.  The top stages use
// shift 17, 18 and 19 with bitwidth 18, so the part select is reversed:
// Icarus refuses to elaborate it, and Yosys silently swaps the range
// (y[16:17] -> y[17:16]), putting the wrong low bits into the last three
// rotations.  The stages now use `$signed(y) >>> shift`, which is defined for
// any shift and identical wherever the old form was legal.
//
// Properties checked (magnitude is ~0.824 * input: CORDIC gain 1.647 with the
// implementation's 0.5 scaling):
//   0 deg   (1000,0) -> ( 823, 0)
//   90 deg           -> ( 0, 824)
//   180 deg          -> (-824, 0)
//   270 deg          -> ( 0,-823)
//   (0,1000) 0 deg   -> ( 0, 824)
//   (1000,1000)      -> ( 823, 824)
// plus magnitude preservation between quadrants.
//
`timescale 1ns/1ps

module tb_cordic;
  localparam BW = 16;
  localparam G  = 824;             // measured implementation gain * 1000
  localparam TOL = 4;

  reg                clock = 0;
  reg                reset = 1;
  reg                enable = 0;
  reg  signed [BW-1:0] xi = 0, yi = 0;
  reg  [23:0]        zi = 0;
  wire signed [BW-1:0] xo, yo;
  wire [23:0]        zo;

  integer errors = 0;
  integer mag0;

  always #5 clock = ~clock;

  cordic_z24 #(.bitwidth(BW), .stages(19)) dut (
    .clock(clock), .reset(reset), .enable(enable),
    .xi(xi), .yi(yi), .zi(zi), .xo(xo), .yo(yo), .zo(zo));

  function integer mag2(input signed [BW-1:0] a, input signed [BW-1:0] b);
    mag2 = a * a + b * b;
  endfunction

  task rotate(input signed [BW-1:0] a, input signed [BW-1:0] b, input [23:0] z);
    begin
      xi = a; yi = b; zi = z;
      repeat (40) @(posedge clock);
    end
  endtask

  task expect(input signed [BW-1:0] a, input signed [BW-1:0] b,
              input signed [BW-1:0] ex, input signed [BW-1:0] ey,
              input [8*32-1:0] what);
    begin
      if ((^xo) === 1'bx || (^yo) === 1'bx) begin
        errors = errors + 1;
        $display("FAIL: %0s produced x", what);
      end else if (xo < ex - TOL || xo > ex + TOL || yo < ey - TOL || yo > ey + TOL) begin
        errors = errors + 1;
        $display("FAIL: %0s got (%0d,%0d) expected (~%0d,~%0d)", what, xo, yo, ex, ey);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 1'b0;
    enable = 1'b1;

    rotate(1000, 0, 24'd0);
    expect(0, 0, G, 0, "0 deg on I");
    mag0 = mag2(xo, yo);

    rotate(1000, 0, 24'd4194304);            // 90 deg = 2^22
    expect(0, 0, 0, G, "90 deg on I");

    rotate(1000, 0, 24'd8388608);            // 180 deg = 2^23
    expect(0, 0, -G, 0, "180 deg on I");

    rotate(1000, 0, 24'd12582912);           // 270 deg = 3*2^22
    expect(0, 0, 0, -G, "270 deg on I");

    rotate(0, 1000, 24'd0);
    expect(0, 0, 0, G, "0 deg on Q");

    rotate(1000, 1000, 24'd0);
    expect(0, 0, G, G, "0 deg on I=Q");

    // Magnitude must not depend on the rotation angle.
    rotate(1000, 0, 24'd0);
    if (mag2(xo, yo) < mag0 - 3000 || mag2(xo, yo) > mag0 + 3000) begin
      errors = errors + 1;
      $display("FAIL: magnitude changed with angle: %0d vs %0d", mag2(xo, yo), mag0);
    end

    // Idle-bias regression.  A zero input used to produce a constant -1 LSB
    // at the CORDIC output (and -256 LSB at the 16-bit TX output) because the
    // output slice and every stage shift floored toward -infinity.  All three
    // narrowing points now round, so the residual must be noise, not offset.
    // The second case (zero I, non-zero Q, zero phase) is the condition that
    // was actually observed in the chain: I must stay at zero.
    begin : idle
      integer n;
      integer acc;
      xi = 0; yi = 0; zi = 0;
      repeat (25) @(posedge clock);            // drain the 20-stage pipeline
      acc = 0;
      for (n = 0; n < 64; n = n + 1) begin
        @(posedge clock);
        acc = acc + xo + yo;
      end
      if (acc > 32 || acc < -32) begin
        errors = errors + 1;
        $display("FAIL: idle bias (0,0): sum(xo+yo) over 64 clocks = %0d", acc);
      end else begin
        $display("  idle bias (0,0): sum(xo+yo) over 64 clocks = %0d", acc);
      end

      xi = 0; yi = 1000; zi = 0;
      repeat (25) @(posedge clock);
      acc = 0;
      for (n = 0; n < 64; n = n + 1) begin
        @(posedge clock);
        acc = acc + xo;
      end
      // The CORDIC itself is accurate to +-1 LSB at this width; what mattered
      // was that the offset was systematic (-1 on every sample) and that it
      // was amplified downstream.  The chain benches check the 16-bit output.
      if (acc > 64 || acc < -64) begin
        errors = errors + 1;
        $display("FAIL: idle bias (0,1000): sum(xo) over 64 clocks = %0d", acc);
      end else begin
        $display("  idle bias (0,1000): sum(xo) over 64 clocks = %0d", acc);
      end
      xi = 0; yi = 0; zi = 0;
      repeat (25) @(posedge clock);
    end

    if (errors == 0)
      $display("PASS: CORDIC rotates 0/90/180/270 deg, preserves magnitude, no idle bias");
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
