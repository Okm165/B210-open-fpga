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

  // Triangular-PDF dither of exactly +-1 output LSB (2 LSB peak-to-peak), the
  // amplitude for which the quantiser error is decorrelated from the signal
  // (Schuchman condition).  Without it the error-feedback loop locks onto a
  // deterministic limit cycle (measured: the idle output toggled between two
  // values with a period-33 pattern).
  //
  // The span must scale with this instance's quantiser step: the step in the
  // accumulator domain is 2**DROP with DROP = WIDTH_IN - WIDTH_OUT, so the
  // dither is (sum - 2^17) >> (17 - DROP), spanning exactly +-2**DROP.
  // (A previous revision used a fixed shift and an LFSR truncated to the
  // error width; at WIDTH_IN=23 that collapsed the dither to {0,-1}
  // accumulator units, i.e. no dither at all.)
  localparam DROP = WIDTH_IN - WIDTH_OUT;

  reg  [16:0] dither_a = 17'h1ACE5;
  reg  [16:0] dither_b = 17'h2F00D;
  wire [17:0] dither_sum = {1'b0, dither_a} + {1'b0, dither_b};
  // The two 17-bit LFSRs sum to a value centred on 2**17, not 2**16: centring
  // on 2**16 leaves the dither carrying a +0.5 output-LSB DC offset (found by
  // the exact-integer audit, which measured a +0.74 LSB mean error).
  wire signed [19:0] dither_raw = $signed({2'b00, dither_sum}) - 20'sd131072;
  wire signed [19:0] dither_s = (DROP == 0)     ? 20'sd0     :
                                (DROP >= 17)    ? dither_raw :
                                                  (dither_raw >>> (17 - DROP));
  wire [ERR_WIDTH-1:0] dither = dither_s[ERR_WIDTH-1:0];

  always @(posedge clk)
    if (reset) begin
      dither_a <= 17'h1ACE5;
      dither_b <= 17'h2F00D;
    end else if (strobe_in) begin
      // maximal-length 17-bit LFSRs: x^17 + x^14 + 1 and x^17 + x^15 + 1
      dither_a <= {dither_a[15:0], dither_a[16] ^ dither_a[13]};
      dither_b <= {dither_b[15:0], dither_b[16] ^ dither_b[14]};
    end

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
