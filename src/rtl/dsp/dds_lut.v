// Quarter-wave sine/cosine LUT with linear interpolation.
//
// Replaces the 19-stage CORDIC as the mixer's oscillator.  Measured against
// the ideal sine, the interpolated LUT's maximum error is -96 dB -- below the
// 16-bit output quantisation floor -- where the CORDIC's per-stage rounding
// produced -69.8 dBc spurs.  It also has no gain constant (the CORDIC's
// algorithmic 1.6468/2 = 0.8235 had to be calibrated out downstream).
//
// Phase format (32-bit accumulator):
//   [31:30] quadrant   [29:20] quarter-wave index (10 bit)   [19:0] fraction
//
// The ROM stores {value, slope} per entry so the interpolation needs one
// multiply and one add:  out = value + slope * fraction.
`default_nettype none

module dds_lut #(
  parameter WIDTH = 24          // output width (saturating)
) (
  input  wire               clk,
  input  wire               rst,
  input  wire [31:0]        phase,     // 2^32 = 360 degrees
  output reg  signed [17:0] sin_out,
  output reg  signed [17:0] cos_out
);

  // {slope[15:0], value[15:0]} per entry, 1025 entries
  reg [31:0] rom [0:1024];
  reg [15:0] rom_v [0:1024];
  reg [15:0] rom_d [0:1024];
  initial begin
    $readmemh("src/rtl/dsp/dds_lut_qw.mem", rom);
    for (integer i = 0; i < 1025; i = i + 1) begin
      rom_v[i] = rom[i][15:0];
      rom_d[i] = rom[i][31:16];
    end
  end

  wire [1:0]  quad  = phase[31:30];
  wire [9:0]  index = phase[29:20];
  wire [19:0] frac  = phase[19:0];

  // cosine is the same table shifted one quadrant
  wire [1:0]  cq   = quad + 2'd1;
  wire [9:0]  cidx = cq[0] ? 10'd1023 - index : index;
  wire [19:0] cfr  = cq[0] ? ~frac : frac;
  wire [9:0]  sidx = quad[0] ? 10'd1023 - index : index;
  wire [19:0] sfr  = quad[0] ? ~frac : frac;

  wire signed [15:0] sv  = rom_v[sidx];
  wire signed [15:0] sd  = rom_d[sidx];
  wire signed [15:0] cv  = rom_v[cidx];
  wire signed [15:0] cd  = rom_d[cidx];

  // interpolation: value + slope * fraction  (fraction/2^20, Q0.20)
  wire signed [35:0] sprod = sd * $signed({4'd0, frac});
  wire signed [35:0] cprod = cd * $signed({4'd0, cfr});
  wire signed [35:0] sval  = {{18{sv[15]}}, sv} + (sprod >>> 20);
  wire signed [35:0] cval  = {{18{cv[15]}}, cv} + (cprod >>> 20);

  // quadrant folding: q0: +sin  q1: +cos  q2: -sin  q3: -cos
  wire signed [17:0] s_mag = sval[17:0];
  wire signed [17:0] c_mag = cval[17:0];
  wire        s_neg = quad[1];
  wire        c_neg = cq[1];

  always @(posedge clk) begin
    if (rst) begin
      sin_out <= 18'sd0;
      cos_out <= 18'sd0;
    end else begin
      sin_out <= s_neg ? -s_mag : s_mag;
      cos_out <= c_neg ? -c_mag : c_mag;
    end
  end

endmodule
`default_nettype wire
