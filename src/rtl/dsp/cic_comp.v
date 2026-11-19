//
// CIC inverse-sinc compensator (fixed, single-rate, linear-phase FIR).
//
// Corrects the passband droop of the CIC (N=4) stages in ddc_chain/duc_chain.
// The CIC droop at a fixed fraction of the input-side rate is INDEPENDENT of
// the rate R, so one fixed filter covers all decimation/interpolation
// settings (measured: -1.7 dB at R=2 ... -2.32 dB at R>=8 at the 0.2 edge).
//
// Design (least-squares fit to 1/|Hcic| over [0, 0.2*fs], high-frequency
// gain capped at +6% to protect downstream headroom, 18-bit q17 coefficients,
// DC gain 1.0000):
//   in-band residual:      -58.8 ... +0.5 dB   (vs -2.3 dB uncompensated)
//   gain above 0.24*fs:     <= -3.0 dB         (no headroom explosion)
//   sum|taps| = 2.476       -> guard bits + clip to WIDTH
//
// Symmetric 15-tap structure: 7 pre-added pairs + center tap = 8 DSP48s per
// channel. q17 taps (index 0..14, symmetric): 1262, -10783, 15333, 6275,
// -27192, -10388, 63968, 54124, 63968, -10388, -27192, 6275, 15333, -10783,
// 1262.
//
module cic_comp #(
    parameter WIDTH = 18
  ) (
    input                    clk,
    input                    rst,
    input                    bypass,
    input                    stb_in,
    input signed [WIDTH-1:0] data_in,
    output                    stb_out,
    output signed [WIDTH-1:0] data_out
  );

   localparam AW    = WIDTH + 1;      // symmetric pair pre-add
   localparam PW    = AW + 18;        // (WIDTH+1) x 18 product
   localparam ABITS = PW + 3;        // sum of 8 products
   localparam SBITS = ABITS - 17;    // post-q17-shift width into the clip

   // q17 coefficients
   localparam signed [17:0] C0 = 18'sd54124;   // center (tap 7)
   localparam signed [17:0] C1 = 18'sd63968;
   localparam signed [17:0] C2 = -18'sd10388;
   localparam signed [17:0] C3 = -18'sd27192;
   localparam signed [17:0] C4 = 18'sd6275;
   localparam signed [17:0] C5 = 18'sd15333;
   localparam signed [17:0] C6 = -18'sd10783;
   localparam signed [17:0] C7 = 18'sd1262;

   // delay line, shifted on input strobes; d[0] is the newest sample
   reg signed [WIDTH-1:0] d [0:14];
   integer k;
   always @(posedge clk)
     if (rst) begin
        for (k = 0; k < 15; k = k + 1) d[k] <= {WIDTH{1'b0}};
     end else if (stb_in) begin
        d[0] <= data_in;
        for (k = 1; k < 15; k = k + 1) d[k] <= d[k-1];
     end

   // symmetric pre-adds: tap pairs k and 14-k
   wire signed [AW-1:0] p1 = d[0]  + d[14];  // C7
   wire signed [AW-1:0] p2 = d[1]  + d[13];  // C6
   wire signed [AW-1:0] p3 = d[2]  + d[12];  // C5
   wire signed [AW-1:0] p4 = d[3]  + d[11];  // C4
   wire signed [AW-1:0] p5 = d[4]  + d[10];  // C3
   wire signed [AW-1:0] p6 = d[5]  + d[9];   // C2
   wire signed [AW-1:0] p7 = d[6]  + d[8];   // C1
   wire signed [WIDTH-1:0] pc = d[7];        // C0 center

   wire signed [PW-1:0] m1, m2, m3, m4, m5, m6, m7, m8;
   // wide sign-extended copies: a plain sum of 37-bit products would be
   // evaluated in 37-bit context and overflow, wrapping the upper bits
   wire signed [ABITS-1:0] e1 = m1, e2 = m2, e3 = m3, e4 = m4;
   wire signed [ABITS-1:0] e5 = m5, e6 = m6, e7 = m7, e8 = m8;

   reg stb_d1, stb_d2, stb_d3;

   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul1 (.P(m1), .A(p1), .B(C7), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul2 (.P(m2), .A(p2), .B(C6), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul3 (.P(m3), .A(p3), .B(C5), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul4 (.P(m4), .A(p4), .B(C4), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul5 (.P(m5), .A(p5), .B(C3), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul6 (.P(m6), .A(p6), .B(C2), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul7 (.P(m7), .A(p7), .B(C1), .CE(stb_d1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE("7SERIES"), .LATENCY(1), .WIDTH_A(AW), .WIDTH_B(18))
     mul8 (.P(m8), .A({pc[WIDTH-1], pc}), .B(C0), .CE(stb_d1), .CLK(clk), .RST(rst));

   // accumulator: worst case |acc| = sum|taps| * 2^17 * 2^(WIDTH-1)
   reg signed [ABITS-1:0] acc;

   always @(posedge clk)
     if (rst) begin
        stb_d1 <= 1'b0;
        stb_d2 <= 1'b0;
        stb_d3 <= 1'b0;
        acc    <= {ABITS{1'b0}};
     end else begin
        // d1: delay line has shifted and is stable -> products capture it
        // d2: products are registered -> accumulate
        // d3: accumulator is valid -> final clip/round
        stb_d1 <= stb_in;
        stb_d2 <= stb_d1;
        stb_d3 <= stb_d2;
        if (stb_d2)
          acc <= e1 + e2 + e3 + e4 + e5 + e6 + e7 + e8;
     end

   // q17 scaling with guard bits, clipped back to WIDTH
   wire signed [SBITS-1:0] scaled = acc[ABITS-1:17];
   wire signed [WIDTH-1:0] comp_out;
   clip_reg #(.bits_in(SBITS), .bits_out(WIDTH), .STROBED(1)) out_clip
     (.clk(clk), .reset(rst), .in(scaled), .strobe_in(stb_d3),
      .out(comp_out), .strobe_out(stb_out));

   // Bypass is not an edge case, it is the maximum-rate mode: at CIC rate 1
   // the CIC is the identity and has no droop, so this inverse-sinc filter
   // would ADD a shape instead of removing one (measured: +2.8 dB at 0.2 of
   // the output rate, -9.5 dB at 0.3).  Selecting the centre tap of the delay
   // line keeps exact unity gain and a pure delay.
   assign data_out = bypass ? d[7] : comp_out;

endmodule // cic_comp
