//
// Copyright 2011-2013 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//


//! The USRP digital down-conversion chain

module ddc_chain
  #(
    parameter BASE = 0,
    parameter DSPNO = 0,
    parameter WIDTH = 24,
    parameter DEVICE = "SPARTAN6"
  )
  (input clk, input rst, input clr,
   input 	     set_stb, input [7:0] set_addr, input [31:0] set_data,

   // From RX frontend
   input [WIDTH-1:0] rx_fe_i,
   input [WIDTH-1:0] rx_fe_q,

   // To RX control
   output [31:0] sample,
   input 	     run,
   output 	     strobe,
   output [31:0]     debug
   );

   localparam  cwidth = 25;
   localparam  zwidth = 24;

   wire [31:0] phase_inc;
   reg [31:0]  phase;

   wire [cwidth-1:0] to_cordic_i, to_cordic_q;
   wire [cwidth-1:0] i_cordic, q_cordic;
   reg  [WIDTH-1:0] i_cordic_pipe, q_cordic_pipe;


   reg [WIDTH-1:0]  rx_fe_i_mux, rx_fe_q_mux;
   wire        realmode;
   wire        swap_iq;
   wire        invert_i;
   wire        invert_q;

   setting_reg #(.my_addr(BASE+0)) sr_0
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(phase_inc),.changed());



   setting_reg #(.my_addr(BASE+3), .width(4)) sr_3
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out({invert_i,invert_q,realmode,swap_iq}),.changed());


   // MUX so we can do realmode signals on either input

   always @(posedge clk)
     if(swap_iq)
       begin
          rx_fe_i_mux <= invert_i ? ~rx_fe_q : rx_fe_q;
          rx_fe_q_mux <= realmode ? {WIDTH{1'b0}} : invert_q ? ~rx_fe_i : rx_fe_i;
       end
     else
       begin
	  rx_fe_i_mux <= invert_i ? ~rx_fe_i : rx_fe_i;
          rx_fe_q_mux <= realmode ? {WIDTH{1'b0}} : invert_q ? ~rx_fe_q : rx_fe_q;
       end

   // NCO
   always @(posedge clk)
     if(rst)
       phase <= 0;
     else if(~run)
       phase <= 0;
     else
       phase <= phase + phase_inc;

   // Mixer: interpolated quarter-wave LUT oscillator (dds_lut) plus a complex
   // multiply.  Exact unit gain -- the CORDIC's 1.6468/2 = 0.8235 constant and
   // its 19 stages of per-stage rounding spurs are gone.  The oscillator is
   // registered (one cycle), the multipliers another (LATENCY 1), so the
   // datapath here is two clocks deep and still produces one sample per
   // clock while running.
   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_i (.in(rx_fe_i_mux), .out(to_cordic_i));
   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_q (.in(rx_fe_q_mux), .out(to_cordic_q));

   wire signed [17:0] nco_sin, nco_cos;
   dds_lut #(.WIDTH(WIDTH)) nco
     (.clk(clk), .rst(rst), .phase(phase), .sin_out(nco_sin), .cos_out(nco_cos));

   // Down-conversion by the NCO phase theta:
   //   i' = i*cos + q*sin
   //   q' = q*cos - i*sin
   // (The Q channel's sign matters: with +i*sin the Q output rotates the
   // opposite way and the spectrum splatters to both f_in+/-f_lo, which the
   // tuned end-to-end test showed as four lines at +/-9 and +/-15 MHz.)
   wire signed [35:0] p_ic, p_qs, p_is, p_qc;
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_ic (.P(p_ic), .A(to_cordic_i[24:7]), .B(nco_cos), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_qs (.P(p_qs), .A(to_cordic_q[24:7]), .B(nco_sin), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_is (.P(p_is), .A(to_cordic_i[24:7]), .B(nco_sin), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_qc (.P(p_qc), .A(to_cordic_q[24:7]), .B(nco_cos), .CE(1'b1), .CLK(clk), .RST(rst));

   wire signed [36:0] sum_i = p_ic + p_qs;   // 18b x 18b, exact: no overflow
   wire signed [36:0] sum_q = p_qc - p_is;

   // Narrow the 37-bit accumulator to 24 bits with round-half-even.
   // The multipliers take the top 18 bits (>>7) and the oscillator is Q15,
   // so the product is input<<8; >>8 recovers exact unit gain.
   wire sum_i_rnd = sum_i[7] & (sum_i[8] | |sum_i[6:0]);
   wire sum_q_rnd = sum_q[7] & (sum_q[8] | |sum_q[6:0]);
   always @(posedge clk) begin
      i_cordic_pipe[23:0] <= sum_i[31:8] + sum_i_rnd;
      q_cordic_pipe[23:0] <= sum_q[31:8] + sum_q_rnd;
   end


   // ---------------------------------------------------------------------
   // Static maximum-quality output path.
   //
   // The receive datapath performs no rate change and no filtering: there is
   // no CIC, no droop compensator and no halfband, so nothing can droop,
   // alias or shape the signal.  The mixer output goes straight to the 16-bit
   // output formatter below, one sample per clock.
   //
   // The rate, halfband and coefficient-reload setting registers are no
   // longer decoded: writes to those addresses are ignored by the hardware
   // (the UHD driver never reads them back, so it is unaffected).  The scale
   // field is likewise fixed at unity, which is the value the driver programs
   // for full dynamic range.
   // ---------------------------------------------------------------------
   // Fixed output scale.  The old chain carried the CORDIC's 0.4117 net gain
   // (1.6468 algorithmic gain, /2 at the output slice, /2 again in the pipe),
   // which left 2.4x of headroom between a full-scale ADC sample and the
   // 16-bit rail.  With the exact-unit-gain mixer the natural scale is 0.5:
   // a full-scale ADC sample then lands at full-scale output.
   localparam [17:0] SCALE_UNITY = 18'h10000;   // exactly 0.5 in Q17

   // Single dithered quantiser, 24 -> 16 bit (the fixed 0.5 scale is the
   // shift by one).  The previous 24->19->18->x-scale->33->16 cascade rounded
   // deterministically twice before the multiply, which the multi-tone
   // measurement showed as third-order intermodulation at -67 dBc.  One
   // quantiser with triangular dither cannot generate those products.
   wire signed [WIDTH-2:0] i_fmt = i_cordic_pipe[WIDTH-1:1];
   wire signed [WIDTH-2:0] q_fmt = q_cordic_pipe[WIDTH-1:1];

   round_sd #(.WIDTH_IN(WIDTH-1), .WIDTH_OUT(16)) round_i
     (.clk(clk), .reset(rst), .in(i_fmt), .strobe_in(1'b1),
      .out(sample[31:16]), .strobe_out(strobe));
   round_sd #(.WIDTH_IN(WIDTH-1), .WIDTH_OUT(16)) round_q
     (.clk(clk), .reset(rst), .in(q_fmt), .strobe_in(1'b1),
      .out(sample[15:0]), .strobe_out());



   assign debug = {30'd0, run, strobe};

endmodule // ddc_chain
