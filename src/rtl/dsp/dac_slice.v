//
// Copyright 2026 Open Source SDR Lab
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

//! The last number operation on the transmit path: 24-bit DSP word -> 12-bit
//! DAC word.
//
// Round half to even, then SATURATE.  Both halves matter:
//
//   * Truncation (the original code, `in[23:12]`) biases every code by
//     -0.5 LSB and doubles the error power relative to rounding.
//   * Rounding without saturation is worse than truncation: input values in
//     the top 1/4096 of the range round to 2048, which 12-bit two's
//     complement reads as -2048, i.e. a full-scale positive sample becomes a
//     full-scale negative spike.  Measured: a full-scale host sample
//     (in16 = 32767 -> 8388352) produced code 0x800 instead of 0x7FF before
//     this module existed.
//
// The 25-bit intermediate is required: 24-bit max + 2048 overflows 24 bits.
module dac_slice (
  input  wire signed [23:0] in,
  output wire        [11:0] out
);

   wire signed [24:0] rnd = {in[23], in} + 25'sd2047 + {24'd0, in[12]};

   // 8388607 is the largest positive 24-bit value; anything above it can only
   // come from the rounding add, so it clips to the largest DAC code.
   assign out = (rnd > 25'sd8388607) ? 12'h7FF : rnd[23:12];

endmodule
