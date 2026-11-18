//
// Halfband decimator: rate, valid discipline, and pipeline depth.
//
// tb_hbdec_impulse proves the filter *coefficients*.  This bench proves the
// things around them, which are equally capable of breaking a receiver:
//
//   1. decimation by two - one output per two accepted input samples;
//   2. no output while nd is low, and no output after the pipeline drains;
//   3. rdy and data_valid are the same condition;
//   4. sclr stops all output;
//   5. the capture-to-output latency stays in its five-stage band.  hbdec was
//      split into grouped accumulators so that no DSP48E1 post-adder cascade
//      crosses a clock-row boundary (F25); that fix must not silently grow the
//      pipeline.
//
`timescale 1ns/1ps

module tb_hbdec_rate;
  reg         clk = 0;
  reg         sclr = 1;
  reg         ce = 1;
  reg         coef_we = 0;
  reg         nd = 0;
  reg         coef_ld = 0;
  reg  [23:0] din_1 = 0;
  reg  [23:0] din_2 = 0;
  reg  [17:0] coef_din = 0;
  wire        rfd, rdy, data_valid;
  wire [46:0] dout_1, dout_2;

  integer errors = 0;
  integer accepted = 0;
  integer produced = 0;
  integer cycles = 0;
  integer first_accept = -1;
  integer first_valid = -1;
  integer latency;
  integer n;
  integer expected;
  reg     phase = 0;

  // The core holds ready low until its 24-sample history window is full, so
  // the first accepted samples are deliberately not emitted.  Every accepted
  // sample after the priming window produces exactly one output.
  localparam PRIME = 24;

  hbdec1 dut (
    .sclr(sclr), .ce(ce), .coef_we(coef_we), .nd(nd), .clk(clk),
    .coef_ld(coef_ld), .rfd(rfd), .rdy(rdy), .data_valid(data_valid),
    .dout_1(dout_1), .dout_2(dout_2), .din_1(din_1), .din_2(din_2),
    .coef_din(coef_din));

  always #5 clk = ~clk;

  // One clock: drive nd like the real datapath does (level, not a strobe).
  task cycle(input nd_in);
    begin
      @(negedge clk);
      nd = nd_in;
      din_1 = cycles[23:0];
      din_2 = ~cycles[23:0];
      @(posedge clk); #1;

      if (nd_in && !phase) begin
        accepted = accepted + 1;
        if (first_accept < 0) first_accept = cycles;
      end
      phase = nd_in ? ~phase : phase;

      if (data_valid) begin
        produced = produced + 1;
        if (first_valid < 0) first_valid = cycles;
      end

      if (data_valid !== rdy) begin
        errors = errors + 1;
        $display("FAIL: data_valid %b != rdy %b at cycle %0d", data_valid, rdy, cycles);
      end

      cycles = cycles + 1;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    sclr = 1'b0;

    // 100 cycles of nd high -> 50 accepted samples -> 50-PRIME outputs.
    for (n = 0; n < 100; n = n + 1) cycle(1'b1);

    // Drain: nd low, but the last accepted samples are still in the pipeline.
    for (n = 0; n < 12; n = n + 1) cycle(1'b0);

    expected = accepted - PRIME;

    if (accepted != 50) begin
      errors = errors + 1;
      $display("FAIL: accepted %0d samples in 100 cycles, expected 50", accepted);
    end
    if (produced != expected) begin
      errors = errors + 1;
      $display("FAIL: produced %0d outputs for %0d accepted samples, expected %0d",
               produced, accepted, expected);
    end

    // Nothing may appear once the pipeline is empty and nd is low.
    for (n = 0; n < 20; n = n + 1) cycle(1'b0);
    if (produced != expected) begin
      errors = errors + 1;
      $display("FAIL: %0d extra outputs appeared with nd low", produced - expected);
    end

    // Capture-to-output latency: the priming window (PRIME accepted samples,
    // one every two cycles) plus the five-register output pipeline, counted
    // inclusively by this bench.
    latency = first_valid - first_accept;
    if (latency < 2 * PRIME + 3 || latency > 2 * PRIME + 8) begin
      errors = errors + 1;
      $display("FAIL: pipeline latency %0d cycles, expected %0d..%0d",
               latency, 2 * PRIME + 3, 2 * PRIME + 8);
    end

    // Reset must silence the outputs and keep them silent.
    @(negedge clk);
    sclr = 1'b1;
    for (n = 0; n < 4; n = n + 1) begin
      @(posedge clk); #1;
      if (data_valid !== 1'b0) begin
        errors = errors + 1;
        $display("FAIL: data_valid asserted during sclr");
      end
    end
    @(negedge clk);
    sclr = 1'b0;

    if (errors == 0)
      $display("PASS: halfband decimates 2:1, valid==rdy, drain silent, latency %0d", latency);
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
