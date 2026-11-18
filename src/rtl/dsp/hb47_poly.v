// hb47_poly - 2x interpolating halfband, polyphase, strobe-free.
//
// Replaces hb47_int in the transmit chain.  hb47_int derived its polyphase
// selection from one-clock pipeline stages of stb_in, so an input strobe
// slower than its clock made the phase bits stale: it computed one polyphase
// half only and its interpolation image was never cancelled (measured -13.9
// dBc at the stage, -22.9 dBc at the DAC pins; see
// .context/evidence-dsp-steps.md).
//
// This module computes both phases explicitly, so it works at any input
// strobe period:
//
//   centre phase  = x[n-11]
//   filtered phase = sum_g c_g * (x[n-g] + x[n-23+g])
//
// with c_g = 2 * q[2g], q being the Q17 halfband of
// .context/hb47_replacement_taps.npy (sum q = 1, centre q[23] = 0.5).  The
// factor two makes both phases unity DC gain, matching the level convention
// of hb47_int (its folded coefficients are the same numbers).
//
// The coefficients run from the OUTERMOST pair inwards: c(0) is the -23 tap,
// c(11) is the +-1 tap.  Getting this order backwards (as the first draft did)
// leaves the right numbers in the wrong places: the impulse response still
// looks plausible in isolation, but its passband collapses and the image is
// reinforced instead of cancelled.
//
// Two outputs are produced per input sample.  `phase` is derived from stb_in,
// not stb_out, so no external phase can break it; stb_out only enables the
// output register at the 2x rate.  The DUC strobes stb_out coincidently with
// stb_in (verified: 999 of 999 hb2 strobes coincide with a CIC strobe); at
// that edge the filter output for the previous input sample is presented,
// and the centre sample for the same input sample follows at the next
// stb_out.
`default_nettype none

module hb47_poly #(
  parameter WIDTH  = 18,
  parameter DEVICE = "7SERIES"
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               bypass,
  input  wire               stb_in,       // input sample strobe (any period)
  input  wire [WIDTH-1:0]   data_in,
  input  wire               stb_out,      // output enable at 2x stb_in
  output reg  [WIDTH-1:0]   data_out
);

  // 24 delayed input samples: xd[0] = x[n], xd[23] = x[n-23]
  reg signed [WIDTH-1:0] xd [0:23];
  integer i;
  always @(posedge clk)
    if (rst)
      for (i = 0; i < 24; i = i + 1) xd[i] <= {WIDTH{1'b0}};
    else if (stb_in)
      begin
         xd[0] <= data_in;
         for (i = 1; i < 24; i = i + 1) xd[i] <= xd[i-1];
      end

  // Folded halfband coefficients, Q17, edge pair first (see header).
  function signed [17:0] c;
    input integer k;
    case (k)
      0:  c = -18'sd54;      1:  c =  18'sd186;
      2:  c = -18'sd436;     3:  c =  18'sd856;
      4:  c = -18'sd1510;    5:  c =  18'sd2486;
      6:  c = -18'sd3912;    7:  c =  18'sd6004;
      8:  c = -18'sd9200;    9:  c =  18'sd14644;
      10: c = -18'sd26546;   11: c =  18'sd83016;
      default: c = 18'sd0;
    endcase
  endfunction

  wire signed [WIDTH-1:0] xa [0:11];
  wire signed [WIDTH-1:0] xb [0:11];
  genvar g;
  generate
    for (g = 0; g < 12; g = g + 1) begin: pairs
      assign xa[g] = xd[g];
      assign xb[g] = xd[23-g];
    end
  endgenerate

  // Taps are folded into pairs, so twelve pre-adders and twelve multiplies
  // compute the whole 47-tap filter.  Both operands are explicitly signed:
  // an unsigned coefficient would make the product unsigned and turn every
  // negative tap into a large positive one (the signedness trap already
  // measured on the TX narrow stage).
  wire signed [WIDTH:0]    sum  [0:11];
  wire signed [17+WIDTH:0] prod [0:11];
  generate
    for (g = 0; g < 12; g = g + 1) begin: macs
      assign sum[g]  = $signed(xa[g]) + $signed(xb[g]);
      assign prod[g] = $signed(sum[g]) * $signed(c(g));
    end
  endgenerate

  wire signed [17+WIDTH+3:0] acc;
  assign acc = prod[0] + prod[1] + prod[2]  + prod[3]
             + prod[4] + prod[5] + prod[6]  + prod[7]
             + prod[8] + prod[9] + prod[10] + prod[11];

  // round half even from Q17, then saturate to WIDTH
  wire signed [17+WIDTH+3:0] acc_r = acc + (acc[16] & (acc[17] | |acc[15:0]));
  wire signed [17+WIDTH+3:0] acc_s = acc_r >>> 17;
  wire signed [WIDTH-1:0]    filtered =
      (acc_s >  (1 <<< (WIDTH-1)) - 1) ?  (1 <<< (WIDTH-1)) - 1 :
      (acc_s < -(1 <<< (WIDTH-1)))     ? -(1 <<< (WIDTH-1))     : acc_s[WIDTH-1:0];

  // phase 0 at the coincident stb_in/stb_out edge (filter output), phase 1 at
  // the following stb_out (centre sample).
  reg phase;
  always @(posedge clk)
    if (rst)             phase <= 1'b0;
    else if (stb_in)     phase <= 1'b1;
    else if (stb_out)    phase <= 1'b0;

  always @(posedge clk)
    if (bypass)
      data_out <= data_in;
    else if (stb_out)
      data_out <= phase ? xd[12] : filtered;
endmodule

`default_nettype wire
