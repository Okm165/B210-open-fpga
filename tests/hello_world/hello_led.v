`timescale 1ns/1ps

// hello_led.v — the smallest meaningful FPGA design: a heartbeat LED.
//
// Two modules on purpose:
//   hello_led_core  pure logic, no vendor primitives -> simulated on the host
//   hello_led_top   IBUFDS + BUFG + core            -> synthesized for the part
//
// This exists to prove the *flow*, not to run on hardware: same compiler
// settings, same part, same bitstream pipeline as the real design.

module hello_led_core #(
   parameter WIDTH = 24
) (
   input  clk,
   input  rst,
   output led,
   output tick
);
   reg [WIDTH-1:0] count = {WIDTH{1'b0}};

   always @(posedge clk)
     if (rst) count <= {WIDTH{1'b0}};
     else     count <= count + 1'b1;

   assign led  = count[WIDTH-1];
   assign tick = &count;
endmodule


// Synthesis top: 40 MHz differential board clock in, one LED out.
module hello_led_top (
   input  codec_main_clk_p,
   input  codec_main_clk_n,
   output led
);
   wire clk_in;
   wire clk;

   IBUFDS u_ibufds (
      .O  (clk_in),
      .I  (codec_main_clk_p),
      .IB (codec_main_clk_n)
   );

   BUFG u_bufg (
      .I (clk_in),
      .O (clk)
   );

   hello_led_core #(.WIDTH(24)) u_core (
      .clk  (clk),
      .rst  (1'b0),
      .led  (led),
      .tick ()
   );
endmodule
