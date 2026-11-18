//
// CIC interpolator: DC gain, rate, and enable behaviour.
//
// cic_interp is the TX mirror of cic_decim: N integrators at the output rate,
// N differentiators clocked by strobe_in, and cic_int_shifter removing
// (N-1)*log2(R) bits.  The design drives it exactly this way - strobe_out tied
// high, strobe_in pulsing once per interpolation period - so a constant input
// must come out bit-identical at unity DC gain.
//
// Settling is slow on purpose: the integrator chain ramps for roughly 64*R
// sample periods before the differentiator pulse train dies out.  Counting in
// samples, not cycles, is what makes an R=16 test as meaningful as R=2.
//
`timescale 1ns/1ps

module tb_cic_interp;
  localparam N = 4;

  reg  [17:0] signal_in = 18'd0;
  reg         clock = 0;
  reg         reset = 1;
  reg         enable = 0;
  reg  [7:0]  rate = 8'd4;
  reg         strobe_in = 0;
  wire [17:0] signal_out;

  integer errors = 0;
  integer i;
  integer k;
  integer settled_run;

  cic_interp #(.bw(18), .N(N), .log2_of_max_rate(7)) dut (
    .clock(clock), .reset(reset), .enable(enable), .rate(rate),
    .strobe_in(strobe_in), .strobe_out(1'b1),
    .signal_in(signal_in), .signal_out(signal_out));

  always #5 clock = ~clock;

  task run_dc(input [7:0] r_in, input signed [17:0] value);
    integer j;
    begin
      rate        = r_in;
      signal_in   = value;
      strobe_in   = 1'b0;
      k           = 0;
      settled_run = 0;

      // Changing `rate` rescales the shifter, so leftover integrator state
      // would show up as a wrong DC level.  The real design gates rate changes
      // with `enable`; do the same here between measurements.
      @(negedge clock);
      enable = 1'b0;
      repeat (4) @(posedge clock);
      @(negedge clock);
      enable = 1'b1;

      // 64 sample periods of settling, then eight sample periods of checks.
      for (j = 0; j < 64 * r_in; j = j + 1) begin
        @(negedge clock);
        strobe_in = ((k % r_in) == 0);
        k = k + 1;
        @(posedge clock); #1;
      end

      for (j = 0; j < 8 * r_in; j = j + 1) begin
        @(negedge clock);
        strobe_in = ((k % r_in) == 0);
        k = k + 1;
        @(posedge clock); #1;
        if ($signed(signal_out) !== value) begin
          if (settled_run < 4)
            $display("FAIL: rate %0d: expected %0d got %0d (sample cycle %0d)",
                     r_in, value, $signed(signal_out), j);
          settled_run = settled_run + 1;
        end
      end
      if (settled_run != 0)
        errors = errors + 1;
    end
  endtask

  initial begin
    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 1'b0;
    enable = 1'b1;

    run_dc(8'd2,   18'sd1000);
    run_dc(8'd4,   18'sd1000);
    run_dc(8'd8,   18'sd1000);
    run_dc(8'd16,  18'sd1000);
    run_dc(8'd4,  -18'sd1000);      // sign must survive the integrator chain
    run_dc(8'd8,  -18'sd250);

    // enable low must clear the integrators, so the output collapses to 0.
    @(negedge clock);
    enable = 0;
    repeat (4) @(posedge clock); #1;
    if (signal_out !== 18'd0) begin
      errors = errors + 1;
      $display("FAIL: output %0d after disable, expected 0", $signed(signal_out));
    end

    // reset must do the same as enable low.
    enable = 1;
    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 1'b1;
    repeat (4) @(posedge clock); #1;
    if (signal_out !== 18'd0) begin
      errors = errors + 1;
      $display("FAIL: output %0d during reset, expected 0", $signed(signal_out));
    end

    if (errors == 0)
      $display("PASS: CIC interpolator DC gain at rates 2/4/8/16, disable and reset clear");
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
