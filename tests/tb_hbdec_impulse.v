//
// Self-checking impulse-response test for the halfband filter.
// The expected sequence is the hb47.coe symmetric halfband response:
// c0..c12 then c11..c0.
//
`timescale 1ns/1ps

module tb_hbdec_impulse;
  reg clk = 0;
  reg sclr = 1;
  reg ce = 1;
  reg coef_we = 0;
  reg nd = 0;
  reg coef_ld = 0;
  reg [23:0] din_1 = 0;
  reg [23:0] din_2 = 0;
  reg [17:0] coef_din = 0;
  wire rfd, rdy, data_valid;
  wire [46:0] dout_1, dout_2;

  integer n;
  integer idx;
  reg started;

  // hb47.coe unique half, then the mirrored half.
  reg signed [47:0] expected [0:24];
  initial begin
    expected[0]  = -62;
    expected[1]  = 194;
    expected[2]  = -440;
    expected[3]  = 855;
    expected[4]  = -1505;
    expected[5]  = 2478;
    expected[6]  = -3900;
    expected[7]  = 5990;
    expected[8]  = -9187;
    expected[9]  = 14632;
    expected[10] = -26536;
    expected[11] = 83009;
    expected[12] = 131071;
    expected[13] = 83009;
    expected[14] = -26536;
    expected[15] = 14632;
    expected[16] = -9187;
    expected[17] = 5990;
    expected[18] = -3900;
    expected[19] = 2478;
    expected[20] = -1505;
    expected[21] = 855;
    expected[22] = -440;
    expected[23] = 194;
    expected[24] = -62;
  end

  hbdec1 dut (
    .sclr(sclr), .ce(ce), .rfd(rfd), .rdy(rdy), .data_valid(data_valid),
    .coef_we(coef_we), .nd(nd), .clk(clk), .coef_ld(coef_ld),
    .dout_1(dout_1), .dout_2(dout_2), .din_1(din_1), .din_2(din_2),
    .coef_din(coef_din)
  );

  always #5 clk = ~clk;

  initial begin
    idx = 0;
    started = 0;
    repeat (5) @(posedge clk);
    sclr <= 0;
    repeat (5) @(posedge clk);
    for (n = 0; n < 120; n = n + 1) begin
      @(negedge clk);
      nd <= 1'b1;
      din_1 <= (n == 50) ? 24'sd1 : 24'sd0;
      din_2 <= 24'sd0;
      @(posedge clk);
      if (data_valid && n >= 54) begin
        started <= 1;
        if ($signed(dout_1) !== expected[idx] || $signed(dout_2) !== expected[idx]) begin
          $display("FAIL: tap %0d expected %0d got %0d/%0d at n=%0d",
                   idx, expected[idx], $signed(dout_1), $signed(dout_2), n);
          $finish;
        end
        idx = idx + 1;
        if (idx == 25) begin
          $display("PASS: 25 halfband taps");
          $finish;
        end
      end
    end
    $display("FAIL: only %0d/25 taps observed", idx);
    $finish;
  end
endmodule
