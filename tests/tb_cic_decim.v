//
// CIC decimator: DC gain, decimation, and enable/reset behaviour.
//
// cic_decim had no bench, and it is the module that carried the shared loop
// variable (two always blocks assigning the same integer, F20).  A CIC
// decimator with N integrators and decimation rate R has a DC gain of R^N;
// cic_dec_shifter removes exactly N*log2(R) bits for power-of-two rates, so a
// constant input must come out bit-identical.  That single property exercises
// all N integrators, all N differentiators, the rate input, the strobe
// discipline and the shifter in one go.
//
`timescale 1ns/1ps

module tb_cic_decim;
  localparam N = 4;

  reg         clock = 0;
  reg         reset = 1;
  reg         enable = 0;
  reg  [7:0]  rate = 8'd4;
  reg         strobe_in = 0;
  reg         strobe_out = 0;
  reg  [15:0] signal_in = 16'd0;
  wire [15:0] signal_out;

  integer errors = 0;
  integer i;
  integer k;
  integer settled_run;

  cic_decim #(.bw(16), .N(N), .log2_of_max_rate(7)) dut (
    .clock(clock), .reset(reset), .enable(enable), .rate(rate),
    .strobe_in(strobe_in), .strobe_out(strobe_out),
    .signal_in(signal_in), .signal_out(signal_out));

  always #5 clock = ~clock;

  // Hold a constant input long enough to reach steady state, then require the
  // output to be exactly that constant for a full stretch of sample periods.
  task run_dc(input [7:0] r_in, input signed [15:0] value);
    integer j;
    begin
      rate       = r_in;
      signal_in  = value;
      strobe_in  = 1'b1;
      k          = 0;
      settled_run = 0;

      // Settle for 40 sample periods (4 * rate input strobes each), then
      // require eight full sample periods of exact DC output.  Counting in
      // samples rather than cycles keeps R=16 as well settled as R=2.
      for (j = 0; j < 40 * r_in; j = j + 1) begin
        @(negedge clock);
        k = k + 1;
        strobe_out = ((k % r_in) == 0);
        @(posedge clock); #1;
      end

      // Steady state: every observation must be the DC input.
      for (j = 0; j < 8 * r_in; j = j + 1) begin
        @(negedge clock);
        k = k + 1;
        strobe_out = ((k % r_in) == 0);
        @(posedge clock); #1;
        if ($signed(signal_out) !== value) begin
          errors = errors + 1;
          if (settled_run < 4)
            $display("FAIL: rate %0d: expected %0d got %0d (settled cycle %0d)",
                     r_in, value, $signed(signal_out), j);
          settled_run = settled_run + 1;
        end
      end
    end
  endtask

  initial begin
    reset = 1;
    enable = 0;
    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 0;
    enable = 1;

    // Power-of-two rates: the shifter cancels the R^N gain exactly.
    run_dc(8'd2,  16'sd1000);
    run_dc(8'd4,  16'sd1000);
    run_dc(8'd8,  16'sd1000);
    run_dc(8'd16, -16'sd500);      // negative DC exercises sign extension

    // Disabling must clear the whole pipeline, so the output collapses to 0.
    @(negedge clock);
    enable = 0;
    repeat (4) @(posedge clock); #1;
    if (signal_out !== 16'd0) begin
      errors = errors + 1;
      $display("FAIL: output %0d after disable, expected 0", $signed(signal_out));
    end

    // Re-enable: the integrators start from zero again, so the DC value must
    // come back once the pipeline settles.
    @(negedge clock);
    enable = 1;
    run_dc(8'd4, 16'sd250);

    if (errors == 0)
      $display("PASS: CIC decimator DC gain at rates 2/4/8/16, disable clears, re-settle");
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
