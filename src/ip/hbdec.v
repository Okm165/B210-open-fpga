//
// Behavioral 49-tap halfband decimator equivalent to the legacy CoreGen
// hbdec1/hbdec2 FIR Compiler cores used by the B200/B210 DDC.
//
// hb47.coe is symmetric and every odd tap is zero, so only the 25 even
// samples and 13 coefficients are needed.  The output is full precision
// (47 bits), matching the CoreGen full-precision output.  The host never
// reloads coefficients; the reload port is retained for compatibility.
//
// The core is dual channel: din_1/dout_1 and din_2/dout_2 are independent
// filters sharing one coefficient set.  The DDC drives I into channel 1 and
// Q into channel 2, so a shared datapath would destroy the imaginary part
// of every sample.  Channel 1 keeps the original latency and values.
//
`default_nettype none

module hbdec_core (
  input  wire        sclr,
  input  wire        ce,
  input  wire        coef_we,
  input  wire        nd,
  input  wire        clk,
  input  wire        coef_ld,
  output wire        rfd,
  output wire        rdy,
  output wire        data_valid,
  output wire [46:0] dout_1,
  output wire [46:0] dout_2,
  input  wire [23:0] din_1,
  input  wire [23:0] din_2,
  input  wire [17:0] coef_din
);

  // hb47.coe unique half: taps 0,2,...,22 and the centre tap 24.
  reg signed [17:0] c [0:12];
  reg signed [17:0] c_shadow [0:12];
  integer ci;
  initial begin
    c[0]  = -18'sd62;      c_shadow[0]  = -18'sd62;
    c[1]  =  18'sd194;     c_shadow[1]  =  18'sd194;
    c[2]  = -18'sd440;     c_shadow[2]  = -18'sd440;
    c[3]  =  18'sd855;     c_shadow[3]  =  18'sd855;
    c[4]  = -18'sd1505;    c_shadow[4]  = -18'sd1505;
    c[5]  =  18'sd2478;    c_shadow[5]  =  18'sd2478;
    c[6]  = -18'sd3900;    c_shadow[6]  = -18'sd3900;
    c[7]  =  18'sd5990;    c_shadow[7]  =  18'sd5990;
    c[8]  = -18'sd9187;    c_shadow[8]  = -18'sd9187;
    c[9]  =  18'sd14632;   c_shadow[9]  =  18'sd14632;
    c[10] = -18'sd26536;   c_shadow[10] = -18'sd26536;
    c[11] =  18'sd83009;   c_shadow[11] =  18'sd83009;
    c[12] =  18'sd131071;  c_shadow[12] =  18'sd131071;
  end

  reg [4:0] wr_ptr;
  always @(posedge clk) begin
    if (sclr) begin
      wr_ptr <= 5'd0;
    end else if (ce) begin
      if (coef_ld) begin
        for (ci = 0; ci < 13; ci = ci + 1) c[ci] <= c_shadow[ci];
        wr_ptr <= 5'd0;
      end else if (coef_we) begin
        if (wr_ptr < 5'd13) c_shadow[wr_ptr] <= coef_din;
        wr_ptr <= wr_ptr + 5'd1;
      end
    end
  end

  // Even-sample history: x[0] newest, x[24] oldest.  Channel 1 and channel 2
  // have independent histories, pair sums and accumulators: this core is the
  // dual-channel FIR the original CoreGen hbdec1/hbdec2 provided, and the
  // DDC feeds I into din_1 and Q into din_2.  A single shared datapath would
  // make dout_2 a copy of dout_1 and turn the complex DDC into a real path.
  reg signed [23:0] x  [0:24];
  reg signed [23:0] xq [0:24];
  reg               phase;
  reg [4:0]         fill_count;

  // Pipeline: capture -> pair sums -> products -> sum -> output.
  reg signed [24:0] s  [0:11];
  reg signed [24:0] sq [0:11];
  reg signed [23:0] centre, centre_q;
  reg               valid1, valid2, valid3, valid4, valid5;
  reg               ready1, ready2, ready3, ready4, ready5;
  reg signed [42:0] p  [0:12];
  reg signed [42:0] pq [0:12];
  // The 13 products are summed in four groups, not in one chain.  Yosys maps
  // a mul+add chain onto a DSP48E1 post-adder cascade, and Nextpnr packs such
  // a cascade with a fixed 5-tile pitch.  A Kintex-7 DSP column holds only 5
  // tiles (9 slices) per clock row before the pitch changes to 6, so a chain
  // longer than 9 is impossible to place.  Groups of at most four keep every
  // chain inside one clock row.
  reg signed [44:0] g  [0:3];
  reg signed [44:0] gq [0:3];
  reg signed [47:0] acc, acc_q;
  reg signed [47:0] dout1_r, dout2_r;

  integer i;
  always @(posedge clk) begin
    if (sclr) begin
      phase      <= 1'b0;
      fill_count <= 5'd0;
      valid1     <= 1'b0;
      valid2     <= 1'b0;
      valid3     <= 1'b0;
      valid4     <= 1'b0;
      valid5     <= 1'b0;
      ready1     <= 1'b0;
      ready2     <= 1'b0;
      ready3     <= 1'b0;
      ready4     <= 1'b0;
      ready5     <= 1'b0;
      acc        <= 48'sd0;
      acc_q      <= 48'sd0;
      dout1_r    <= 48'sd0;
      dout2_r    <= 48'sd0;
      centre     <= 24'sd0;
      centre_q   <= 24'sd0;
      for (i = 0; i < 25; i = i + 1) x[i]  <= 24'sd0;
      for (i = 0; i < 25; i = i + 1) xq[i] <= 24'sd0;
      for (i = 0; i < 12; i = i + 1) s[i]  <= 25'sd0;
      for (i = 0; i < 12; i = i + 1) sq[i] <= 25'sd0;
      for (i = 0; i < 13; i = i + 1) p[i]  <= 43'sd0;
      for (i = 0; i < 13; i = i + 1) pq[i] <= 43'sd0;
      for (i = 0; i < 4; i = i + 1) g[i]  <= 45'sd0;
      for (i = 0; i < 4; i = i + 1) gq[i] <= 45'sd0;
    end else if (ce) begin
      // Stage 0: accept only the even input samples.  The pair sums use
      // the window that includes the new sample (din) and the old history.
      if (nd && !phase) begin
        s[0]  <= $signed(din_1) + x[23];
        s[1]  <= x[0]  + x[22];
        s[2]  <= x[1]  + x[21];
        s[3]  <= x[2]  + x[20];
        s[4]  <= x[3]  + x[19];
        s[5]  <= x[4]  + x[18];
        s[6]  <= x[5]  + x[17];
        s[7]  <= x[6]  + x[16];
        s[8]  <= x[7]  + x[15];
        s[9]  <= x[8]  + x[14];
        s[10] <= x[9]  + x[13];
        s[11] <= x[10] + x[12];
        centre <= x[11];

        sq[0]  <= $signed(din_2) + xq[23];
        sq[1]  <= xq[0]  + xq[22];
        sq[2]  <= xq[1]  + xq[21];
        sq[3]  <= xq[2]  + xq[20];
        sq[4]  <= xq[3]  + xq[19];
        sq[5]  <= xq[4]  + xq[18];
        sq[6]  <= xq[5]  + xq[17];
        sq[7]  <= xq[6]  + xq[16];
        sq[8]  <= xq[7]  + xq[15];
        sq[9]  <= xq[8]  + xq[14];
        sq[10] <= xq[9]  + xq[13];
        sq[11] <= xq[10] + xq[12];
        centre_q <= xq[11];

        for (i = 24; i > 0; i = i - 1) x[i]  <= x[i-1];
        for (i = 24; i > 0; i = i - 1) xq[i] <= xq[i-1];
        x[0]  <= $signed(din_1);
        xq[0] <= $signed(din_2);
        valid1 <= 1'b1;
        ready1 <= (fill_count >= 5'd24);
        if (fill_count < 5'd25) fill_count <= fill_count + 5'd1;
      end else begin
        valid1 <= 1'b0;
        ready1 <= 1'b0;
      end
      phase <= nd ? ~phase : phase;

      // Stage 1: multiply.
      for (i = 0; i < 12; i = i + 1) p[i]  <= s[i]  * c[i];
      p[12] <= centre * c[12];
      for (i = 0; i < 12; i = i + 1) pq[i] <= sq[i] * c[i];
      pq[12] <= centre_q * c[12];
      valid2 <= valid1;
      ready2 <= ready1;

      // Stage 2: group sums.  Four addends per group, so a DSP post-adder
      // cascade stays within one clock row of the DSP column.
      g[0] <= p[0] + p[1] + p[2] + p[3];
      g[1] <= p[4] + p[5] + p[6];
      g[2] <= p[7] + p[8] + p[9];
      g[3] <= p[10] + p[11] + p[12];
      gq[0] <= pq[0] + pq[1] + pq[2] + pq[3];
      gq[1] <= pq[4] + pq[5] + pq[6];
      gq[2] <= pq[7] + pq[8] + pq[9];
      gq[3] <= pq[10] + pq[11] + pq[12];
      valid3 <= valid2;
      ready3 <= ready2;

      // Stage 3: total.
      acc   <= g[0]  + g[1]  + g[2]  + g[3];
      acc_q <= gq[0] + gq[1] + gq[2] + gq[3];
      valid4 <= valid3;
      ready4 <= ready3;

      // Stage 4: output.
      dout1_r <= acc;
      dout2_r <= acc_q;
      valid5  <= valid4;
      ready5  <= ready4;

    end
  end

  assign rfd        = 1'b1;
  assign rdy        = valid5 & ready5;
  assign data_valid = valid5 & ready5;
  assign dout_1     = dout1_r[46:0];
  assign dout_2     = dout2_r[46:0];

endmodule

module hbdec1 (
  input  wire        sclr,
  input  wire        ce,
  input  wire        coef_we,
  input  wire        nd,
  input  wire        clk,
  input  wire        coef_ld,
  output wire        rfd,
  output wire        rdy,
  output wire        data_valid,
  output wire [46:0] dout_1,
  output wire [46:0] dout_2,
  input  wire [23:0] din_1,
  input  wire [23:0] din_2,
  input  wire [17:0] coef_din
);
  hbdec_core u (
    .sclr(sclr), .ce(ce), .coef_we(coef_we), .nd(nd), .clk(clk),
    .coef_ld(coef_ld), .rfd(rfd), .rdy(rdy), .data_valid(data_valid),
    .dout_1(dout_1), .dout_2(dout_2), .din_1(din_1), .din_2(din_2),
    .coef_din(coef_din));
endmodule

module hbdec2 (
  input  wire        sclr,
  input  wire        ce,
  input  wire        coef_we,
  input  wire        nd,
  input  wire        clk,
  input  wire        coef_ld,
  output wire        rfd,
  output wire        rdy,
  output wire        data_valid,
  output wire [46:0] dout_1,
  output wire [46:0] dout_2,
  input  wire [23:0] din_1,
  input  wire [23:0] din_2,
  input  wire [17:0] coef_din
);
  hbdec_core u (
    .sclr(sclr), .ce(ce), .coef_we(coef_we), .nd(nd), .clk(clk),
    .coef_ld(coef_ld), .rfd(rfd), .rdy(rdy), .data_valid(data_valid),
    .dout_1(dout_1), .dout_2(dout_2), .din_1(din_1), .din_2(din_2),
    .coef_din(coef_din));
endmodule
