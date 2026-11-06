//
// Portable replacement for the Xilinx MULT_MACRO behavioral macro.
// Yosys synth_xilinx infers DSP48E1 (or logic) from the signed multiply.
//
`default_nettype none

module MULT_MACRO #(
  parameter DEVICE  = "7SERIES",
  parameter LATENCY = 1,
  parameter WIDTH_A = 18,
  parameter WIDTH_B = 18,
  parameter WIDTH_P = WIDTH_A + WIDTH_B
) (
  output wire [WIDTH_P-1:0] P,
  input  wire [WIDTH_A-1:0] A,
  input  wire [WIDTH_B-1:0] B,
  input  wire               CE,
  input  wire               CLK,
  input  wire               RST
);
  wire signed [WIDTH_A-1:0] a_s = A;
  wire signed [WIDTH_B-1:0] b_s = B;
  wire signed [WIDTH_P-1:0] product = a_s * b_s;

  generate
    if (LATENCY == 0) begin : g_comb
      assign P = product;
    end else begin : g_pipe
      reg signed [WIDTH_P-1:0] p [0:LATENCY-1];
      integer i;
      always @(posedge CLK) begin
        if (RST) begin
          for (i = 0; i < LATENCY; i = i + 1) p[i] <= {WIDTH_P{1'b0}};
        end else if (CE) begin
          p[0] <= product;
          for (i = 1; i < LATENCY; i = i + 1) p[i] <= p[i-1];
        end
      end
      assign P = p[LATENCY-1];
    end
  endgenerate
endmodule
