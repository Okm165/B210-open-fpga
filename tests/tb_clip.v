//
// Clipping and its registered wrapper.
//
// clip_reg is the module behind the defect that made every RX sample zero
// (F17): its `reset` port drives only `strobe_out`, and in ddc_chain that port
// was left open, so synthesis folded `strobe_out` to constant 0 and the sample
// strobe never fired.  The RTL was "correct"; the wiring was not.  This bench
// pins down the contract that wiring has to satisfy:
//
//   clip        saturates to the 12-bit rail on either side, in range passes
//   clip_reg    STROBED=1: `out` holds unless strobe_in, strobe_out follows
//               strobe_in and is cleared by reset (reset must reach the strobe)
//   clip_reg    STROBED=0: `out` tracks every clock regardless of strobe_in
//
`timescale 1ns/1ps

module tb_clip;
  localparam BIN  = 16;
  localparam BOUT = 12;

  reg  [BIN-1:0]  in = 0;
  wire [BOUT-1:0] clipped;

  reg             clk = 0;
  reg             reset = 0;
  reg             strobe_in = 0;
  wire [BOUT-1:0] out_strobed;
  wire            strobe_out;
  wire [BOUT-1:0] out_free;

  integer errors = 0;
  integer i;

  clip #(.bits_in(BIN), .bits_out(BOUT)) u_clip (
    .in(in), .out(clipped));

  clip_reg #(.bits_in(BIN), .bits_out(BOUT), .STROBED(1'b1)) u_strobed (
    .clk(clk), .reset(reset), .in(in), .out(out_strobed),
    .strobe_in(strobe_in), .strobe_out(strobe_out));

  clip_reg #(.bits_in(BIN), .bits_out(BOUT), .STROBED(1'b0)) u_free (
    .clk(clk), .reset(reset), .in(in), .out(out_free),
    .strobe_in(strobe_in), .strobe_out());

  always #5 clk = ~clk;

  // in, expected signed 12-bit result
  reg signed [BIN-1:0] vec_in  [0:7];
  reg signed [BOUT-1:0] vec_out [0:7];

  initial begin
    vec_in[0]  =  16'sd0;      vec_out[0] =  12'sd0;
    vec_in[1]  =  16'sd1;      vec_out[1] =  12'sd1;
    vec_in[2]  =  16'sd2047;   vec_out[2] =  12'sd2047;    // positive rail
    vec_in[3]  =  16'sd2048;   vec_out[3] =  12'sd2047;    // first overflow
    vec_in[4]  =  16'sd32767;  vec_out[4] =  12'sd2047;
    vec_in[5]  = -16'sd2048;   vec_out[5] = -12'sd2048;    // negative rail
    vec_in[6]  = -16'sd2049;   vec_out[6] = -12'sd2048;    // first underflow
    vec_in[7]  = -16'sd32768;  vec_out[7] = -12'sd2048;

    // ---- clip: saturation in both directions -------------------------------
    for (i = 0; i < 8; i = i + 1) begin
      in = vec_in[i];
      #1;
      if ($signed(clipped) !== vec_out[i]) begin
        errors = errors + 1;
        $display("FAIL: clip(%0d) = %0d, expected %0d",
                 $signed(vec_in[i]), $signed(clipped), vec_out[i]);
      end
    end

    // ---- clip_reg STROBED=1: hold until strobe, reset clears the strobe -----
    // `out` has no reset, so it may hold x until the first strobe; that is fine.
    in = 16'sd100;
    repeat (2) @(posedge clk); #1;

    @(negedge clk); strobe_in = 1'b1;
    @(posedge clk); #1;
    if ($signed(out_strobed) !== 12'sd100) begin
      errors = errors + 1;
      $display("FAIL: strobed out %0d after first strobe, expected 100", $signed(out_strobed));
    end
    if (strobe_out !== 1'b1) begin
      errors = errors + 1;
      $display("FAIL: strobe_out not asserted one cycle after strobe_in");
    end

    // Change the input without a strobe: out must hold.
    @(negedge clk); strobe_in = 1'b0; in = 16'sd4000;
    repeat (3) @(posedge clk); #1;
    if ($signed(out_strobed) !== 12'sd100) begin
      errors = errors + 1;
      $display("FAIL: strobed out changed to %0d without a strobe", $signed(out_strobed));
    end
    if (strobe_out !== 1'b0) begin
      errors = errors + 1;
      $display("FAIL: strobe_out asserted without strobe_in");
    end

    // A strobe takes the saturated value: 4000 clamps to 2047.
    @(negedge clk); strobe_in = 1'b1;
    @(posedge clk); #1;
    if ($signed(out_strobed) !== 12'sd2047) begin
      errors = errors + 1;
      $display("FAIL: strobed out %0d after clamp, expected 2047", $signed(out_strobed));
    end

    // Reset must kill the output strobe even while strobe_in stays high.
    @(negedge clk); reset = 1'b1; strobe_in = 1'b1;
    repeat (3) begin
      @(posedge clk); #1;
      if (strobe_out !== 1'b0) begin
        errors = errors + 1;
        $display("FAIL: strobe_out asserted while reset is high");
      end
    end
    @(negedge clk); reset = 1'b0; strobe_in = 1'b0;

    // ---- clip_reg STROBED=0: out tracks every clock -------------------------
    @(negedge clk); in = 16'sd777;
    @(posedge clk); #1;
    if ($signed(out_free) !== 12'sd777) begin
      errors = errors + 1;
      $display("FAIL: free-running out %0d, expected 777", $signed(out_free));
    end
    @(negedge clk); in = -16'sd5000;
    @(posedge clk); #1;
    if ($signed(out_free) !== -12'sd2048) begin
      errors = errors + 1;
      $display("FAIL: free-running out %0d on clamp, expected -2048", $signed(out_free));
    end

    if (errors == 0)
      $display("PASS: clip saturates both rails; clip_reg strobe hold, reset, free-run");
    else
      $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
