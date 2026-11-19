// hb47_poly - 2x interpolating halfband, polyphase, strobe-free, pipelined.
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
//   centre phase   = x[n-11]
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
// Pipelining: the multiply result and two 6-term partial sums are registered,
// so the per-clock path is multiply, add, add - each comfortably inside the
// 100 MHz bus clock.  The filtered path is then 2 clocks behind the sample
// history.  That DOES move the pairing unless the centre tap carries the
// matching delay: the centre is therefore registered once (centre_q), the
// value that keeps both phases on the same input sample at every strobe
// period, down to the 2-clock period of total 2.  Removing that register
// leaves the total-2 interpolation image uncancelled (-7.7 dBc at 0.125
// fs_in) and droops total 4 by -0.53 dB; the guard is tb_tx_passband cfg 1.
//
// Two outputs are produced per input sample.  `phase` is derived from stb_in,
// not stb_out, so no external phase can break it; stb_out only enables the
// output register at the 2x rate.  The DUC strobes stb_out coincidently with
// stb_in (verified: 999 of 999 hb2 strobes coincide with a CIC strobe).
`default_nettype none

module hb47_poly #(
  parameter WIDTH  = 18
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
  wire signed [WIDTH:0]         sum   [0:11];
  // stage 1: multiply result registered (yosys packs this into the DSP48E1)
  reg  signed [17+WIDTH:0]      prod_q [0:11];
  // stage 2: two 6-term partial sums registered
  reg  signed [17+WIDTH+2:0]    ps_a, ps_b;

  generate
    for (g = 0; g < 12; g = g + 1) begin: macs
      assign sum[g] = $signed(xa[g]) + $signed(xb[g]);
      // No reset: a register with a reset blocks the DSP48E1 PREG mapping and
      // leaves the multiply combinational (measured: bus_clk then failed at
      // 66 MHz).  The value is defined anyway - xd is reset and the product
      // updates every clock.
      always @(posedge clk)
        prod_q[g] <= $signed(sum[g]) * $signed(c(g));
    end
  endgenerate

  always @(posedge clk) begin
    ps_a <= prod_q[0] + prod_q[1] + prod_q[2] + prod_q[3] + prod_q[4] + prod_q[5];
    ps_b <= prod_q[6] + prod_q[7] + prod_q[8] + prod_q[9] + prod_q[10] + prod_q[11];
  end

  wire signed [17+WIDTH+2:0] acc = ps_a + ps_b;

  // Round half even from Q17, then saturate to WIDTH.
  //
  // Shift FIRST, add the rounding bit AFTER.  Adding the sticky term before
  // the shift adds one Q17 LSB, i.e. 1/131072 of an output LSB - a no-op that
  // leaves truncation-toward-minus-infinity.  Measured consequence: a
  // -0.5 LSB DC bias, -82 dBc relative to the tone, which the TX NCO turned
  // into a -82 dBc feedthrough at the DAC (the RX path uses round_sd and
  // measured -88.7 dBc, so this was also the main RX/TX quality asymmetry).
  wire signed [17+WIDTH+2:0] acc_s = acc >>> 17;
  wire signed [17+WIDTH+2:0] acc_r = acc_s + (acc[16] & (acc[17] | |acc[15:0]));
  wire signed [WIDTH-1:0]    filtered =
      (acc_r >  (1 <<< (WIDTH-1)) - 1) ?  (1 <<< (WIDTH-1)) - 1 :
      (acc_r < -(1 <<< (WIDTH-1)))     ? -(1 <<< (WIDTH-1))     : acc_r[WIDTH-1:0];

  // The filtered path is two registers deep (prod_q, ps_a/ps_b).  The centre
  // tap is registered once, which is the delay that aligns the two polyphase
  // phases at every input-strobe period - including the 2-clock period of the
  // total-2 configuration (a single halfband, the MIMO 2 x 30.72 transmit
  // path).  Before this register the centre and the filtered half came from
  // different input samples at total 2: the interpolation image was NOT
  // cancelled (-1.7 dBc at 0.219 fs_in, and the passband drooped -2.24 dB),
  // while total 4 drooped -0.53 dB.  With it, total 2 and 4 are flat to
  // 0.01 dB and images are <= -80 dBc (tests/tb_tx_passband.v, cfgs 1-3).
  reg signed [WIDTH-1:0] centre_q;
  always @(posedge clk) centre_q <= xd[12];

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
      data_out <= phase ? centre_q : filtered;
endmodule

`default_nettype wire
