//
// Copyright 2011-2013 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//


//! The USRP digital up-conversion chain

module duc_chain
  #(
    parameter BASE = 0,
    parameter DSPNO = 0,
    parameter WIDTH = 24,
    parameter DEVICE = "7SERIES"
  )
  (input clk, input rst, input clr,
   input set_stb, input [7:0] set_addr, input [31:0] set_data,

   // To TX frontend
   output [WIDTH-1:0] tx_fe_i,
   output [WIDTH-1:0] tx_fe_q,

   // From TX control
   input [31:0] sample,
   input run,
   output strobe,
   output [31:0] debug
   );

   genvar 	 i;


   wire [17:0] scale_factor;
   wire [31:0] phase_inc;
   reg [31:0]  phase;
   wire [7:0]  interp_rate;
   wire [3:0]  tx_femux_a, tx_femux_b;
   wire        enable_hb1, enable_hb2;
   wire        rate_change;

   setting_reg #(.my_addr(BASE+0)) sr_0
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(phase_inc),.changed());

   setting_reg #(.my_addr(BASE+1), .width(18)) sr_1
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(scale_factor),.changed());

   setting_reg #(.my_addr(BASE+2), .width(10)) sr_2
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out({enable_hb1, enable_hb2, interp_rate}),.changed(rate_change));

   // Strobes are all now delayed by 1 cycle for timing reasons
   wire        strobe_cic_pre, strobe_hb1_pre, strobe_hb2_pre;
   reg 	       strobe_cic = 1;
   reg 	       strobe_hb1 = 1;
   reg 	       strobe_hb2 = 1;

  assign strobe = strobe_hb1;

   cic_strober #(.WIDTH(8))
     cic_strober(.clock(clk),.reset(rst),.enable(run & ~rate_change),.rate(interp_rate),
		 .strobe_fast(1'b1),.strobe_slow(strobe_cic_pre) );
   cic_strober #(.WIDTH(2))
     hb2_strober(.clock(clk),.reset(rst),.enable(run & ~rate_change),.rate(enable_hb2 ? 2'd2 : 2'd1),
		 .strobe_fast(strobe_cic_pre),.strobe_slow(strobe_hb2_pre) );
   cic_strober #(.WIDTH(2))
     hb1_strober(.clock(clk),.reset(rst),.enable(run & ~rate_change),.rate(enable_hb1 ? 2'd2 : 2'd1),
		 .strobe_fast(strobe_hb2_pre),.strobe_slow(strobe_hb1_pre) );

   always @(posedge clk) strobe_hb1 <= strobe_hb1_pre;
   always @(posedge clk) strobe_hb2 <= strobe_hb2_pre;
   always @(posedge clk) strobe_cic <= strobe_cic_pre;

   // NCO
   always @(posedge clk)
     if(rst)
       phase <= 0;
     else if(~run)
       phase <= 0;
     else
       phase <= phase + phase_inc;

   wire        signed [17:0] da, db;
   wire        signed [35:0] prod_i, prod_q;

   wire [17:0] i_interp, q_interp;

   wire [17:0] hb1_i, hb1_q, hb2_i, hb2_q;

   // Halfband interpolation, 47-tap stages (hb47_poly).  The previous 6-tap
   // `hb_interp`/`small_hb_int` path is gone: it could not even be simulated
   // (it instantiates MULT18X18S, which has no model here), so keeping it was
   // untested legacy.
	 // First stage of halfband interpolation filters. These run at a max CPO of 2 when CIC is bypassed and HB2 enabled.
	 hb47_poly
	   #(.WIDTH(18))
	     hb1_i0
	       (
		.clk(clk),
		.rst(rst),
		.bypass(~enable_hb1),
		.stb_in(strobe_hb1),
		.data_in({sample[31:16],2'b00}),
		.stb_out(strobe_hb2),
		.data_out(hb1_i)
		);

	 hb47_poly
	   #(.WIDTH(18))
	     hb1_q0
	       (
		.clk(clk),
		.rst(rst),
		.bypass(~enable_hb1),
		.stb_in(strobe_hb1),
		.data_in({sample[15:0],2'b00}),
		.stb_out(strobe_hb2),
		.data_out(hb1_q)
		);

	 // Second stage of halfband interpolation filters. These run at a max CPO of 1 when CIC is bypassed.
	 hb47_poly
	   #(.WIDTH(18))
	     hb2_i0
	       (
		.clk(clk),
		.rst(rst),
		.bypass(~enable_hb2),
		.stb_in(strobe_hb2),
		.data_in(hb1_i),
		.stb_out(strobe_cic),
		.data_out(hb2_i)
		);

	 hb47_poly
	   #(.WIDTH(18))
	     hb2_q0
	       (
		.clk(clk),
		.rst(rst),
		.bypass(~enable_hb2),
		.stb_in(strobe_hb2),
		.data_in(hb1_q),
		.stb_out(strobe_cic),
		.data_out(hb2_q)
		);


   wire [17:0] i_cic_out, q_cic_out;

   cic_interp  #(.bw(18),.N(4),.log2_of_max_rate(7))
     cic_interp_i(.clock(clk),.reset(rst),.enable(run & ~rate_change),.rate(interp_rate),
		  .strobe_in(strobe_cic),.strobe_out(1'd1),
		  .signal_in(hb2_i),.signal_out(i_cic_out));

   cic_interp  #(.bw(18),.N(4),.log2_of_max_rate(7))
     cic_interp_q(.clock(clk),.reset(rst),.enable(run & ~rate_change),.rate(interp_rate),
		  .strobe_in(strobe_cic),.strobe_out(1'd1),
		  .signal_in(hb2_q),.signal_out(q_cic_out));

   // Inverse-sinc CIC droop compensation (fixed, rate-independent: see
   // cic_comp.v).  Applied at the CIC output (full clk rate), exactly as in
   // the RX chain.  strobe_out is open: the CIC emits one sample per clk.
   // The compensator is only meaningful when the CIC actually interpolates:
   // at rate 1 it is the identity, and the inverse-sinc filter would impose
   // its own shape on the maximum-rate (bypass) mode.
   cic_comp #(.WIDTH(18)) cic_comp_i
     (.clk(clk), .rst(rst), .bypass(interp_rate == 8'd1), .stb_in(1'b1),
      .data_in(i_cic_out), .stb_out(), .data_out(i_interp));
   cic_comp #(.WIDTH(18)) cic_comp_q
     (.clk(clk), .rst(rst), .bypass(interp_rate == 8'd1), .stb_in(1'b1),
      .data_in(q_cic_out), .stb_out(), .data_out(q_interp));

   // ---------------------------------------------------------------------
   // Up-conversion mixer.
   //
   // Same oscillator and same arithmetic as the receive path (dds_lut plus
   // four exact 18x18 multiplies), so both directions share one verified
   // NCO and one verified gain convention.  It replaces the 24-bit CORDIC,
   // whose algorithmic gain of 1.6468 was neither unity nor amplitude
   // independent: the upstream note in this file recorded that it overflows
   // for a constant envelope above 1.22, and the guard-bit slice used to wrap
   // there (a sign inversion, measured at 8 wraps and a 16 769 546-count step
   // per corner revolution; see tests/tb_cordic_overflow.v).
   //
   // Rotation direction matches the CORDIC exactly: out = in * exp(+j*theta),
   // i.e. i' = i*cos - q*sin and q' = i*sin + q*cos.
   //
   // Gain is exactly 1.0: in Q15 both 18-bit operands give a 36-bit product,
   // so >>15 returns the input scaling.  Saturation replaces wrap, so a
   // complex envelope larger than full scale clips honestly instead of
   // folding.  NOTE for the driver: the old path multiplied by 1.6468, so the
   // TX scale register (BASE+1) now needs 0.6073x its previous value to keep
   // the same output level; a full-scale 16-bit input reaches full-scale DAC
   // output at scale 0x8000.
   // ---------------------------------------------------------------------
   wire signed [17:0] nco_sin, nco_cos;
   dds_lut #(.WIDTH(18)) nco
     (.clk(clk), .rst(rst), .phase(phase), .sin_out(nco_sin), .cos_out(nco_cos));

   wire signed [35:0] p_ic, p_qs, p_is, p_qc;
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_ic (.P(p_ic), .A(i_interp), .B(nco_cos), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_qs (.P(p_qs), .A(q_interp), .B(nco_sin), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_is (.P(p_is), .A(i_interp), .B(nco_sin), .CE(1'b1), .CLK(clk), .RST(rst));
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(18), .WIDTH_B(18))
     mix_qc (.P(p_qc), .A(q_interp), .B(nco_cos), .CE(1'b1), .CLK(clk), .RST(rst));

   wire signed [36:0] sum_i = p_ic - p_qs;
   wire signed [36:0] sum_q = p_is + p_qc;

   // Round half even, then saturate at 18 bits (the input's own range).
   //
   // The shift and the rounding add are written as separate signed
   // expressions on purpose.  Written as one expression
   // (sum_i >>> 15) + sum_i_rnd, the unsigned 1-bit rounding term makes the
   // whole addition unsigned, and this toolchain then evaluates >>> as a
   // LOGICAL shift: measured, a -6183 sample became +4189104 and saturated to
   // the positive rail, i.e. every negative TX sample came out at full scale.
   wire        sum_i_rnd = sum_i[14] & (sum_i[15] | |sum_i[13:0]);
   wire        sum_q_rnd = sum_q[14] & (sum_q[15] | |sum_q[13:0]);
   wire signed [36:0] mix_i = sum_i >>> 15;
   wire signed [36:0] mix_q = sum_q >>> 15;
   wire signed [36:0] mix_i_r = mix_i + sum_i_rnd;
   wire signed [36:0] mix_q_r = mix_q + sum_q_rnd;
   wire [17:0] da_r = (mix_i_r > 37'sd131071)  ? 18'sd131071 :
                      (mix_i_r < -37'sd131072) ? -18'sd131072 : mix_i_r[17:0];
   wire [17:0] db_r = (mix_q_r > 37'sd131071)  ? 18'sd131071 :
                      (mix_q_r < -37'sd131072) ? -18'sd131072 : mix_q_r[17:0];

   MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		.LATENCY(1),         // Desired clock cycle latency, 0-4
		.WIDTH_A(18),        // Multiplier A-input bus width, 1-25
		.WIDTH_B(18))        // Multiplier B-input bus width, 1-18
   mult_i (.P(prod_i),             // Multiplier output bus, width determined by WIDTH_P parameter
	   .A(da_r),               // Multiplier input A bus (rounded)
	   .B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
	   .CE(1'b1),              // 1-bit active high input clock enable
	   .CLK(clk),              // 1-bit positive edge clock input
	   .RST(rst));             // 1-bit input active high reset

   MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		.LATENCY(1),         // Desired clock cycle latency, 0-4
		.WIDTH_A(18),        // Multiplier A-input bus width, 1-25
		.WIDTH_B(18))        // Multiplier B-input bus width, 1-18
   mult_q (.P(prod_q),             // Multiplier output bus, width determined by WIDTH_P parameter
	   .A(db_r),               // Multiplier input A bus (rounded)
	   .B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
	   .CE(1'b1),              // 1-bit active high input clock enable
	   .CLK(clk),              // 1-bit positive edge clock input
	   .RST(rst));             // 1-bit input active high reset


   wire [32:0] 	     i_clip, q_clip;

   // Cordic rotation coupled with a saturated input signal can cause overflow
   // so we clip here rather than allow a wrap.
   clip_reg #(.bits_in(36), .bits_out(33), .STROBED(1)) clip_i
     (.clk(clk), .reset(rst), .in(prod_i[35:0]), .strobe_in(1'b1), .out(i_clip), .strobe_out());
   clip_reg #(.bits_in(36), .bits_out(33), .STROBED(1)) clip_q
     (.clk(clk), .reset(rst), .in(prod_q[35:0]), .strobe_in(1'b1), .out(q_clip), .strobe_out());

   assign tx_fe_i = i_clip[32:33-WIDTH];
   assign tx_fe_q = q_clip[32:33-WIDTH];


   //
   // Debug
   //
   assign 	     debug = {strobe_cic, strobe_hb1, strobe_hb2,run};

endmodule // duc_chain
