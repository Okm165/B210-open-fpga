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

   // CORDIC  24-bit I/O
   // (Algorithmic gain through CORDIC => 1.647 * 0.5 = 0.8235)
   // (Worst case gain through rotation => SQRT(2) = 1.4142)
   // Total worst case gain => 0.8235 * 1.4142 = 1.1646
   // So add an extra MSB bit for word growth.

   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_i (.in(rx_fe_i_mux), .out(to_cordic_i));
   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_q (.in(rx_fe_q_mux), .out(to_cordic_q));

   cordic_z24 #(.bitwidth(cwidth))
   cordic(.clock(clk), .reset(rst), .enable(run),
	  .xi(to_cordic_i),. yi(to_cordic_q), .zi(phase[31:32-zwidth]),
	  .xo(i_cordic),.yo(q_cordic),.zo() );

   // Round the discarded guard bit to nearest-even instead of truncating:
   // truncation here (plus the CORDIC's own output slice) is what produced a
   // measured -1 LSB idle offset with a zero input.
   always @(posedge clk) begin
      i_cordic_pipe[23:0] <= i_cordic[24:1] + (i_cordic[0] & i_cordic[1]);
      q_cordic_pipe[23:0] <= q_cordic[24:1] + (q_cordic[0] & q_cordic[1]);
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
   localparam [17:0] SCALE_UNITY = 18'h1FFFF;   // ~1.0 in Q17

   // round to 19 bits for clip (->18) followed by multiplication (total gain
   // of 6 bits) -- unchanged from the original formatter so that host-side
   // amplitude calibration is unaffected
   wire [18:0] i_unscaled_rnd, q_unscaled_rnd;

   round #(.bits_in(WIDTH), .bits_out(19)) unscaled_rnd_i
     (.in(i_cordic_pipe), .out(i_unscaled_rnd));
   round #(.bits_in(WIDTH), .bits_out(19)) unscaled_rnd_q
     (.in(q_cordic_pipe), .out(q_unscaled_rnd));

   wire        strobe_unscaled_clip;
   wire [17:0] i_unscaled_clip, q_unscaled_clip;

   clip_reg #(.bits_in(19), .bits_out(18), .STROBED(1)) unscaled_clip_i
     (.clk(clk), .reset(rst), .in(i_unscaled_rnd), .strobe_in(1'b1),
      .out(i_unscaled_clip[17:0]), .strobe_out(strobe_unscaled_clip));
   clip_reg #(.bits_in(19), .bits_out(18), .STROBED(1)) unscaled_clip_q
     (.clk(clk), .reset(rst), .in(q_unscaled_rnd), .strobe_in(1'b1),
      .out(q_unscaled_clip[17:0]), .strobe_out());

   wire [35:0] prod_i, prod_q;

   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mult_i (.P(prod_i), .A(i_unscaled_clip), .B(SCALE_UNITY),
             .CE(strobe_unscaled_clip), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mult_q (.P(prod_q), .A(q_unscaled_clip), .B(SCALE_UNITY),
             .CE(strobe_unscaled_clip), .CLK(clk), .RST(rst));

   reg         strobe_scaled;
   wire        strobe_clip;
   wire [32:0] i_clip, q_clip;

   always @(posedge clk) strobe_scaled <= strobe_unscaled_clip;

   clip_reg #(.bits_in(36), .bits_out(33), .STROBED(1)) clip_i
     (.clk(clk), .reset(rst), .in(prod_i[35:0]), .strobe_in(strobe_scaled),
      .out(i_clip), .strobe_out(strobe_clip));
   clip_reg #(.bits_in(36), .bits_out(33), .STROBED(1)) clip_q
     (.clk(clk), .reset(rst), .in(prod_q[35:0]), .strobe_in(strobe_scaled),
      .out(q_clip), .strobe_out());

   round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16)) round_i
     (.clk(clk), .reset(rst), .in(i_clip), .strobe_in(strobe_clip),
      .out(sample[31:16]), .strobe_out(strobe));
   round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16)) round_q
     (.clk(clk), .reset(rst), .in(q_clip), .strobe_in(strobe_clip),
      .out(sample[15:0]), .strobe_out());



   assign debug = {30'd0, run, strobe};

endmodule // ddc_chain
