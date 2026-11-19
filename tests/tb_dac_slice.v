// tb_dac_slice.v - exhaustive proof of the transmit pin quantiser.
//
// dac_slice is the last number operation before the DAC: 24-bit DSP word ->
// 12-bit two's complement code, round half to even and saturate.  It is
// combinational, so every one of the 2^24 input codes can be checked against
// an independent integer model:
//
//   * the code must equal round_half_even(in / 4096) with saturation at 2047,
//   * the mapping must be monotonic non-decreasing (no sign flips, no wrap),
//   * the two rails must be reachable and nothing may exceed them.
//
// The failure this bench exists for: rounding without the clip maps the top
// 2047 of 8388608 codes to 2048, which 12-bit two's complement reads as
// -2048 - a full-scale positive sample coming out as a full-scale negative
// spike.  A full-scale host sample (in16 = 32767 -> 8388352) is checked
// explicitly.
//
// Optional plusarg STEP=<n> subsamples the sweep for a quick run; the default
// is exhaustive.
`timescale 1ns/1ps

module tb_dac_slice;

   reg  signed [23:0] din = 0;
   wire        [11:0] dout;

   dac_slice dut (.in(din), .out(dout));

   integer step, x, ref, code, sgn, prev, errors, checks;
   integer neg_rail, pos_rail;

   initial begin
      if (!$value$plusargs("STEP=%d", step)) step = 1;
      errors = 0; checks = 0; prev = -3000;
      neg_rail = 2047; pos_rail = -2048;   // signed code range

      for (x = -8388608; x <= 8388607; x = x + step) begin
         din = x;
         #1;
         code = dout;

         // independent integer model of round-half-even + saturation
         ref = x + 2047 + ((x >>> 12) & 1);
         if (ref > 8388607) ref = 8388607;
         ref = (ref >>> 12) & 4095;

         checks = checks + 1;
         if (code !== ref) begin
            errors = errors + 1;
            if (errors < 6)
               $display("FAIL: in %0d -> 0x%03X, model 0x%03X", x, code, ref);
         end
         sgn = (code >= 2048) ? code - 4096 : code;   // signed 12-bit
         if (sgn < prev) begin
            errors = errors + 1;
            if (errors < 6)
               $display("FAIL: not monotonic at %0d: 0x%03X after 0x%03X",
                        x, code, prev);
         end
         prev = sgn;
         if (sgn > pos_rail) pos_rail = sgn;
         if (sgn < neg_rail) neg_rail = sgn;
      end

      // the cases that motivated the module
      din = 8388352; #1;  // in16 = +32767 at scale unity: full-scale host sample
      $display("FULL-SCALE POSITIVE: in %0d -> 0x%03X (must be 0x7FF)", din, dout);
      if (dout !== 12'h7FF) errors = errors + 1;
      din = 8388607; #1;
      if (dout !== 12'h7FF) errors = errors + 1;
      din = -8388608; #1;
      $display("FULL-SCALE NEGATIVE: in %0d -> 0x%03X (must be 0x800)", din, dout);
      if (dout !== 12'h800) errors = errors + 1;
      din = 2048; #1;
      if (dout !== 12'h000) errors = errors + 1;   // 0.5 LSB ties to even
      din = 6144; #1;
      if (dout !== 12'h002) errors = errors + 1;   // 1.5 LSB ties to even
      din = -2048; #1;
      if (dout !== 12'h000) errors = errors + 1;

      if (errors == 0) begin
         $display("DAC-SLICE: PASS - %0d input codes (step %0d), rails %0d..%0d",
                  checks, step,
                  neg_rail,
                  pos_rail);
      end else
         $display("DAC-SLICE: FAIL - %0d of %0d codes wrong", errors, checks);
      $finish;
   end

endmodule
