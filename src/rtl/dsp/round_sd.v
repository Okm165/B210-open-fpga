//
// Copyright 2021 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module round_sd #(
  parameter WIDTH_IN   = 18,
  parameter WIDTH_OUT  = 16,
  parameter DISABLE_SD = 0
) (
  input                      clk,
  input                      reset,
  input      [ WIDTH_IN-1:0] in,
  input                      strobe_in,
  output reg [WIDTH_OUT-1:0] out         = 0,
  output reg                 strobe_out  = 0
);

  localparam ERR_WIDTH = WIDTH_IN - WIDTH_OUT + 1;

  wire [ERR_WIDTH-1:0] err;
  wire [WIDTH_IN-1:0]  err_ext, err_ext_01, sum;
  wire [WIDTH_OUT-1:0] out_pre;
  wire                 strobe_pre;

  sign_extend #(
    .bits_in  (ERR_WIDTH),
    .bits_out (WIDTH_IN)
  ) ext_err (
    .in  (err),
    .out (err_ext)
  );

  assign err_ext_01 =
    //synthesis translate_off
    // Disallow X from getting stuck on the err_ext feedback path in simulation
    (^err_ext === 1'bX) ? 0 :
    //synthesis translate_on
    err_ext;

  // Dither the quantiser decision with +-1/2 output LSB.  Without it the
  // error-feedback loop locks onto a deterministic limit cycle (measured:
  // the output toggles between exactly two values with a period-33 pattern),
  // which places discrete idle tones in the passband.  The dither breaks the
  // cycle; the loop still shapes the resulting noise, so the total noise
  // power is unchanged but it is spread instead of concentrated in tones.
  // Uses an LFSR, not the synthesiser's $random, so simulation and silicon
  // produce the same sequence.
  // Two independent LFSRs summed give a triangular-PDF dither of exactly
  // +-1 output LSB -- the textbook requirement for a quantiser whose error
  // must be decorrelated from the signal.  With a half-weight dither the
  // multi-tone measurement still showed third-order intermodulation products
  // (f1+f3-f2 and friends) from the quantiser nonlinearity.
  reg [ERR_WIDTH-2:0] dither_a = 17'h1ACE5;
  reg [ERR_WIDTH-2:0] dither_b = 17'h2F00D;
  wire [ERR_WIDTH:0]  dither_sum;
  wire [ERR_WIDTH-1:0] dither;
  always @(posedge clk)
    if (reset) begin
      dither_a <= 17'h1ACE5;
      dither_b <= 17'h2F00D;
    end else if (strobe_in) begin
      // maximal-length 17-bit LFSRs: x^17 + x^14 + 1 and x^17 + x^15 + 1
      dither_a <= {dither_a[15:0], dither_a[16] ^ dither_a[13]};
      dither_b <= {dither_b[15:0], dither_b[16] ^ dither_b[14]};
    end
  assign dither_sum = {1'b0, dither_a} + {1'b0, dither_b} - (1 << 16);
  // scale the +-1-output-LSB triangular dither to this instance's step size:
  // the full 17-bit span is +/-2^16, i.e. +-1 LSB for a 17-bit drop
  assign dither = dither_sum >>> (17 - (ERR_WIDTH - 1));

  wire [WIDTH_IN-1:0] dither_ext;
  sign_extend #(.bits_in(ERR_WIDTH), .bits_out(WIDTH_IN)) ext_dither
    (.in(dither), .out(dither_ext));

  add2_and_clip_reg #(
    .WIDTH (WIDTH_IN)
  ) add2_and_clip_reg (
    .clk        (clk),
    .rst        (reset),
    .in1        (in),
    .in2        ((DISABLE_SD == 0) ? (err_ext_01 + dither_ext)
                                        : {WIDTH_IN{1'b0}}),
    .strobe_in  (strobe_in),
    .sum        (sum),
    .strobe_out (strobe_pre)
  );

  round #(
    .bits_in  (WIDTH_IN),
    .bits_out (WIDTH_OUT)
  ) round_sum (
    .in  (sum),
    .out (out_pre),
    .err (err)
  );

  always @(posedge clk) begin
    if (reset) begin
      strobe_out <= 1'b0;
    end else begin
      strobe_out <= strobe_pre;
      if (strobe_pre) begin
        out <= out_pre;
      end
    end
  end

endmodule // round_sd
