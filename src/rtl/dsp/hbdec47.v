//
// hbdec47 - two-path 47-tap halfband decimator, plain Verilog.
//
// The stock B200 receive chain (ddc_chain with NEW_HB_DECIM = 1) decimates
// with two Xilinx FIR Compiler v5.0 cores, hbdec1 and hbdec2
// (fpga/usrp3/top/b200/coregen_dsp/ in the UHD tree).  They ship as netlists
// and cannot be built by an open flow, so this module replaces both.  It is
// not a redesign: it reproduces what the two netlists do, to the clock.
//
//   y[m] = sum(k = 0..46) h[k] * x[2m + 1 - k]
//
// h is hb47.coe, the coefficient file both cores were generated from: 18-bit
// integers, twelve distinct outer pairs and a centre tap of 131071.  The
// output is the exact 47-bit sum (the cores are "Full_Precision"), on both
// paths, and nothing is rounded or saturated here: ddc_chain takes bits
// [41:18] exactly as it does from the vendor cores.
//
// What was measured on the Xilinx netlists and is reproduced here
// (tests/tb_hbdec.v checks this contract against an independent model):
//
//   * an output is produced for every second accepted input sample, counting
//     from reset; that second sample is the newest one in the sum above
//   * the outputs change LATENCY clocks after the edge that takes that second
//     sample - 22 for hbdec1, 21 for hbdec2 - whatever the input spacing
//   * data_valid stays low for the first 23 outputs after reset (or after
//     configuration), until the filter holds only samples newer than the
//     reset; rdy pulses for those too
//   * sclr has priority over ce, restarts the pairing and drops results that
//     are still in the pipeline; ce = 0 freezes everything else
//   * hbdec1 takes a sample on every clock; hbdec2 needs two clocks per
//     sample and drops rfd for one clock after each sample it takes
//
// Not reproduced: coefficient reload (the coef_ld / coef_we / coef_din ports
// of the cores, driven from setting register SR_RX_DSP+4).  UHD never writes
// that register, so the coefficients are constants here.
//
// Structure.  Each output needs twelve products per path: the coefficient of
// each outer pair times the sum of its two samples.  The products are shared
// in time: PRODS per multiplier per output, so 12 / PRODS multipliers per
// path.  hbdec1 can be given a sample every clock, which leaves two clocks
// per output and needs six multipliers; hbdec2 has four clocks and uses
// three.  (25 x 18 bit, one DSP48E1 each.)
//
// T is the edge that takes the second sample of a pair, c = 0 .. PRODS-1:
//
//   T + 1 + c       sum of the two samples of pair-of-taps i*PRODS + c, and
//                   its coefficient, into the multiplier input registers
//   T + 2 + c       product
//   T + 3 + c       two partial sums of the products (each exactly as wide
//                   as its sum: see the note at their declaration)
//   T + 4 + c       their sum
//   T + 5 + c       accumulated over c
//   T + 5 + PRODS   plus the centre tap
//   T + LATENCY     output register (a plain delay in between)
//
// The line of second samples only moves when a pair completes, which is at
// most every PRODS clocks, so every read above sees it at rest.
//
`default_nettype none

module hbdec47 #(
  parameter integer LATENCY = 22,
  parameter integer PRODS   = 2      // 2: sample every clock.  4: every other clock.
) (
  input  wire        clk,
  input  wire        sclr,
  input  wire        ce,
  input  wire        nd,
  input  wire [23:0] din_1,
  input  wire [23:0] din_2,
  output wire        rfd,
  output wire        rdy,
  output wire        data_valid,
  output wire [46:0] dout_1,
  output wire [46:0] dout_2
);

  localparam integer MULTS = 12 / PRODS;
  localparam integer DLY   = LATENCY - 5 - PRODS;   // output delay, >= 1

  // -------------------------------------------------------------------------
  // Control: pairing, the post-reset flush, and the strobe pipeline.
  // -------------------------------------------------------------------------
  reg                second = 1'b0;      // the next sample completes a pair
  reg                hold   = 1'b0;      // PRODS = 4: one clock of recovery
  reg  [4:0]         flush  = 5'd0;      // outputs suppressed so far, 0..23
  reg  [LATENCY:0]   p      = {(LATENCY+1){1'b0}};   // p[k]: pair taken k+1 edges ago
  reg  [LATENCY:0]   v      = {(LATENCY+1){1'b0}};   // the same, for visible outputs

  assign rfd = (PRODS == 4) ? ~hold : 1'b1;

  wire take = nd & rfd;
  wire pair = take & second;

  always @(posedge clk)
    if (sclr) begin
      second <= 1'b0;
      hold   <= 1'b0;
      flush  <= 5'd0;
      p      <= {(LATENCY+1){1'b0}};
      v      <= {(LATENCY+1){1'b0}};
    end else if (ce) begin
      hold <= take;
      if (take) second <= ~second;
      if (pair && flush != 5'd23) flush <= flush + 5'd1;
      p <= {p[LATENCY-1:0], pair};
      v <= {v[LATENCY-1:0], pair & (flush == 5'd23)};
    end

  assign rdy        = p[LATENCY];
  assign data_valid = v[LATENCY];

  // Which of the PRODS products is being set up in this clock.
  reg [1:0] c;
  always @* begin
    c = 2'd0;
    if (p[1]) c = 2'd1;
    if (PRODS == 4 && p[2]) c = 2'd2;
    if (PRODS == 4 && p[3]) c = 2'd3;
  end

  // Coefficient of the tap pair (2j, 46 - 2j), from hb47.coe.
  function signed [17:0] coef;
    input integer j;
    case (j)
      0:  coef = -18'sd62;      1:  coef =  18'sd194;
      2:  coef = -18'sd440;     3:  coef =  18'sd855;
      4:  coef = -18'sd1505;    5:  coef =  18'sd2478;
      6:  coef = -18'sd3900;    7:  coef =  18'sd5990;
      8:  coef = -18'sd9187;    9:  coef =  18'sd14632;
      10: coef = -18'sd26536;   11: coef =  18'sd83009;
      default: coef = 18'sd0;
    endcase
  endfunction

  wire first_sample  = ce & take & ~second;
  wire second_sample = ce & pair;

  wire [2*47-1:0] dout;

  genvar g, i;
  generate
    for (g = 0; g < 2; g = g + 1) begin : path
      wire [23:0] din = (g == 0) ? din_1 : din_2;

      // s2[j]: second sample of the pair j pairs back (taps 0, 2, .. 46).
      // s1[j]: first sample likewise; s1[11] is the centre tap.
      reg signed [23:0] s2 [0:23];
      reg signed [23:0] s1 [0:11];
      integer n2, n1;
      always @(posedge clk)
        if (second_sample) begin
          s2[0] <= din;
          for (n2 = 1; n2 < 24; n2 = n2 + 1) s2[n2] <= s2[n2-1];
        end
      always @(posedge clk)
        if (first_sample) begin
          s1[0] <= din;
          for (n1 = 1; n1 < 12; n1 = n1 + 1) s1[n1] <= s1[n1-1];
        end

      // Multipliers.
      wire [43*MULTS-1:0] m;
      for (i = 0; i < MULTS; i = i + 1) begin : mult
        reg signed [24:0] ad;
        reg signed [17:0] cf;
        reg signed [42:0] mr;
        always @(posedge clk)
          if (ce) begin
            ad <= s2[i*PRODS + c] + s2[23 - i*PRODS - c];
            cf <= coef(i*PRODS + c);
            mr <= ad * cf;
          end
        assign m[43*i +: 43] = mr;
      end

      // Sum of the products of one clock, in two steps: NA of them, then the
      // other NB, then both.
      //
      // The two partial sums are registered at exactly the width a sum of NA
      // (NB) 43-bit products has when added one after the other - one more
      // bit per addition - and not at the 47 bits of everything behind them.
      // That is deliberate.  Yosys maps these additions and their register
      // into the DSP48E1s; when it packs a register that has a clock enable
      // or a reset and is wider than the sum it holds, yosys 0.69 leaves the
      // extra, sign-extending bits of the register reading a net that no
      // longer has a driver, and they end up as constant 0 in the netlist: a
      // negative sum turns into a large positive one.  (The same fault put
      // the old receive mixer on the positive rail.  RTL simulation cannot
      // show it; tb_hbdec on the synthesized netlist does.)  A register no
      // wider than its sum has no such bits.  The sign extension to 47 bits
      // happens in the addition of the two partial sums, which is plain
      // logic.
      localparam integer NA = (MULTS + 1) / 2;
      localparam integer NB = MULTS - NA;
      localparam integer WA = 43 + NA - 1;
      localparam integer WB = 43 + NB - 1;

      reg signed [WA-1:0] ps_a, ta;
      reg signed [WB-1:0] ps_b, tb;
      reg signed [46:0]   ps;
      integer k;
      always @* begin
        ta = {WA{1'b0}};
        tb = {WB{1'b0}};
        for (k = 0; k < MULTS; k = k + 1)
          if (k < NA) ta = ta + $signed(m[43*k +: 43]);
          else        tb = tb + $signed(m[43*k +: 43]);
      end
      always @(posedge clk)
        if (ce) begin
          ps_a <= ta;
          ps_b <= tb;
          ps   <= ps_a + ps_b;
        end

      // Accumulate the PRODS sums of one output; p[4] marks the first.
      reg signed [46:0] acc;
      always @(posedge clk)
        if (ce) acc <= p[4] ? ps : acc + ps;

      // Centre tap: the first sample eleven pairs back, as it stands in the
      // clock after a pair completes, carried to where the sum is ready.
      reg signed [23:0] ctr [0:3+PRODS];
      integer nc;
      always @(posedge clk)
        if (ce) begin
          ctr[0] <= s1[11];
          for (nc = 1; nc <= 3 + PRODS; nc = nc + 1) ctr[nc] <= ctr[nc-1];
        end
      wire signed [46:0] ctr_x  = ctr[3+PRODS];
      wire signed [46:0] centre = (ctr_x <<< 17) - ctr_x;    // * 131071

      reg signed [46:0] y;
      always @(posedge clk)
        if (ce && p[4+PRODS]) y <= acc + centre;

      // Make up the latency of the vendor core.
      reg [46:0] dl [1:DLY];
      integer nd_i;
      always @(posedge clk)
        if (ce) begin
          dl[1] <= y;
          for (nd_i = 2; nd_i <= DLY; nd_i = nd_i + 1) dl[nd_i] <= dl[nd_i-1];
        end

      assign dout[47*g +: 47] = dl[DLY];
    end
  endgenerate

  assign dout_1 = dout[46:0];
  assign dout_2 = dout[93:47];

endmodule

`default_nettype wire
