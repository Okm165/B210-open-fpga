//
// Behavioral 49-tap halfband decimator equivalent to the legacy CoreGen
// hbdec1/hbdec2 FIR Compiler cores used by the B200/B210 DDC.
//
// hb47.coe is symmetric and every odd tap is zero, so only the 25 even
// samples and 13 coefficients are needed.  The output is full precision
// (47 bits), matching the CoreGen full-precision output.  The host never
// reloads coefficients; the reload port is retained for compatibility.
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

  // Even-sample history: x[0] newest, x[24] oldest.
  reg signed [23:0] x [0:24];
  reg               phase;
  reg [4:0]         fill_count;

  // Pipeline: capture -> pair sums -> products -> sum -> output.
  reg signed [24:0] s [0:11];
  reg signed [23:0] centre;
  reg               valid1, valid2, valid3, valid4;
  reg               ready1, ready2, ready3, ready4;
  reg signed [42:0] p [0:12];
  reg signed [47:0] acc;
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
      ready1     <= 1'b0;
      ready2     <= 1'b0;
      ready3     <= 1'b0;
      ready4     <= 1'b0;
      acc        <= 48'sd0;
      dout1_r    <= 48'sd0;
      dout2_r    <= 48'sd0;
      centre     <= 24'sd0;
      for (i = 0; i < 25; i = i + 1) x[i] <= 24'sd0;
      for (i = 0; i < 12; i = i + 1) s[i] <= 25'sd0;
      for (i = 0; i < 13; i = i + 1) p[i] <= 43'sd0;
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
        for (i = 24; i > 0; i = i - 1) x[i] <= x[i-1];
        x[0] <= $signed(din_1);
        valid1 <= 1'b1;
        ready1 <= (fill_count >= 5'd24);
        if (fill_count < 5'd25) fill_count <= fill_count + 5'd1;
      end else begin
        valid1 <= 1'b0;
        ready1 <= 1'b0;
      end
      phase <= nd ? ~phase : phase;

      // Stage 1: multiply.
      for (i = 0; i < 12; i = i + 1) p[i] <= s[i] * c[i];
      p[12] <= centre * c[12];
      valid2 <= valid1;
      ready2 <= ready1;

      // Stage 2: sum.
      acc <= p[0] + p[1] + p[2] + p[3] + p[4] + p[5] + p[6]
           + p[7] + p[8] + p[9] + p[10] + p[11] + p[12];
      valid3 <= valid2;
      ready3 <= ready2;

      // Stage 3: output.
      dout1_r <= acc;
      dout2_r <= acc;
      valid4  <= valid3;
      ready4  <= ready3;

    end
  end

  assign rfd        = 1'b1;
  assign rdy        = valid4 & ready4;
  assign data_valid = valid4 & ready4;
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
