//
// Self-checking impulse-response test for the halfband filter.
// The expected sequence is the hb47.coe symmetric halfband response:
// c0..c12 then c11..c0.
//
// The filter is a *two-channel* FIR: din_1/dout_1 and din_2/dout_2 are
// independent.  Testing only channel 1 hides a real defect, because a core
// that ties dout_2 to dout_1 passes an impulse test on channel 1 while
// silently turning the complex DDC/DUC into a real (mono) datapath.
//
// Three phases:
//   A  impulse on din_1 only      -> dout_1 = C, dout_2 = 0
//   B  impulse on din_2 only      -> dout_1 = 0, dout_2 = C
//   C  din_1 = 1 and din_2 = 3    -> dout_1 = C, dout_2 = 3C
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
  integer phase;
  integer errors = 0;
  reg signed [47:0] e1, e2;
  reg signed [23:0] amp1, amp2;

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

  // Drive one impulse pair through the filter and check every output tap.
  task run_phase(input signed [23:0] a, input signed [23:0] b);
    begin
      idx = 0;
      @(negedge clk);
      sclr <= 1'b1;
      nd   <= 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      sclr <= 1'b0;

      for (n = 0; n < 140; n = n + 1) begin
        @(negedge clk);
        nd    <= 1'b1;
        din_1 <= (n == 50) ? a : 24'sd0;
        din_2 <= (n == 50) ? b : 24'sd0;
        @(posedge clk);

        if (data_valid && n >= 54) begin
          e1 = a * expected[idx];
          e2 = b * expected[idx];

          if ($signed(dout_1) !== e1) begin
            errors = errors + 1;
            $display("FAIL: phase %0d tap %0d: dout_1 expected %0d got %0d",
                     phase, idx, e1, $signed(dout_1));
          end
          if ($signed(dout_2) !== e2) begin
            errors = errors + 1;
            $display("FAIL: phase %0d tap %0d: dout_2 expected %0d got %0d",
                     phase, idx, e2, $signed(dout_2));
          end

          idx = idx + 1;
          if (idx == 25) n = 140;     // done with this phase
        end
      end

      if (idx != 25) begin
        errors = errors + 1;
        $display("FAIL: phase %0d produced %0d/25 taps", phase, idx);
      end
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);

    phase = 1;  run_phase(24'sd1, 24'sd0);      // I only
    phase = 2;  run_phase(24'sd0, 24'sd1);      // Q only
    phase = 3;  run_phase(24'sd1, 24'sd3);      // both, 3x on Q

    if (errors == 0)
      $display("PASS: 25 halfband taps on both channels (3 phases)");
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
