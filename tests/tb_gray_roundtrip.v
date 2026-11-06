// Self-checking unit test for the active Gray-code pointer helpers.
// This is a limited RTL test, not full-design verification.

`timescale 1ns/1ps

module tb_gray_roundtrip;

  localparam WIDTH = 8;

  reg  [WIDTH-1:0] bin_in;
  wire [WIDTH-1:0] gray;
  wire [WIDTH-1:0] bin_out;
  integer i;
  integer errors;

  bin2gray #(.WIDTH(WIDTH)) u_bin2gray (
    .bin(bin_in),
    .gray(gray)
  );

  gray2bin #(.WIDTH(WIDTH)) u_gray2bin (
    .gray(gray),
    .bin(bin_out)
  );

  initial begin
    errors = 0;
    bin_in = {WIDTH{1'b0}};

    for (i = 0; i < (1 << WIDTH); i = i + 1) begin
      bin_in = i;
      #1;
      if (bin_out !== bin_in) begin
        $display("FAIL: bin=%0d gray=%02h decoded=%02h", bin_in, gray, bin_out);
        errors = errors + 1;
      end
    end

    if (errors == 0) begin
      $display("PASS: %0d Gray-code round trips", (1 << WIDTH));
    end else begin
      $display("FAIL: %0d Gray-code round-trip errors", errors);
    end

    $finish;
  end

endmodule
