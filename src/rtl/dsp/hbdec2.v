//
// hbdec2 - second receive halfband decimator of the stock B200 DDC.
//
// Port-compatible replacement for the Xilinx FIR Compiler core of the same
// name (fpga/usrp3/top/b200/coregen_dsp/hbdec2.xco in the UHD tree: as
// hbdec1, but generated for a sample on every other clock).  See hbdec47.v
// for what is and is not reproduced; the coefficient reload ports are
// accepted and ignored.
//
`default_nettype none

module hbdec2 (
  input  wire        clk,
  input  wire        sclr,
  input  wire        ce,
  input  wire        coef_ld,
  input  wire        coef_we,
  input  wire [17:0] coef_din,
  output wire        rfd,
  input  wire        nd,
  input  wire [23:0] din_1,
  input  wire [23:0] din_2,
  output wire        rdy,
  output wire        data_valid,
  output wire [46:0] dout_1,
  output wire [46:0] dout_2
);

  hbdec47 #(.LATENCY(21), .PRODS(4)) fir
    (.clk(clk), .sclr(sclr), .ce(ce), .nd(nd), .din_1(din_1), .din_2(din_2),
     .rfd(rfd), .rdy(rdy), .data_valid(data_valid), .dout_1(dout_1), .dout_2(dout_2));

endmodule

`default_nettype wire
