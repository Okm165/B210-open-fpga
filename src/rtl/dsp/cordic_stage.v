// -*- verilog -*-
//
//  USRP - Universal Software Radio Peripheral
//
//  Copyright (C) 2003 Matt Ettus
// 
//  SPDX-License-Identifier: LGPL-3.0-or-later
//

//

module cordic_stage( clock, reset, enable, xi,yi,zi,constant,xo,yo,zo);
   parameter bitwidth = 16;
   parameter zwidth = 16;
   parameter shift = 1;
   
   input     clock;
   input     reset;
   input     enable;
   input [bitwidth-1:0] xi,yi;
   input [zwidth-1:0] zi;
   input [zwidth-1:0] constant;
   output [bitwidth-1:0] xo,yo;
   output [zwidth-1:0] zo;
   
   wire z_is_pos = ~zi[zwidth-1];

   // Arithmetic right shifts by `shift`.  The historical expression
   //   {{shift+1{yi[bitwidth-1]}}, yi[bitwidth-2:shift]}
   // is only well formed while shift <= bitwidth-2.  The top stages
   // use shift 17..19 with bitwidth 18, so their part select is
   // reversed: Yosys silently swaps it (y[16:17] becomes y[17:16])
   // while Icarus refuses to elaborate.  The two tools therefore saw
   // different low bits in the last three rotations.  >>> is defined
   // for any shift: past the width it yields the sign bit alone.
   // Round-to-nearest-even before the arithmetic shift.  Flooring biases every
   // stage toward -infinity (19 stages in series produced a measurable DC
   // offset); round-half-up fixes the average but biases exact ties upward,
   // which is exactly what a zero/near-zero input produces.  Half-even is
   // unbiased in both cases, as in dblclockfft's convround.
   //   addend = 2^(shift-1) - 1 + kept_lsb      (0 when shift == 0)
   wire [63:0] rnd_mask  = (65'sd1 <<< shift) - 65'sd1;
   wire [63:0] rnd_half1 = rnd_mask >> 1;
   wire        rnd_en    = (shift != 0);
   wire [bitwidth-1:0] yi_add = rnd_en ? (rnd_half1[bitwidth-1:0] + {{(bitwidth-1){1'b0}}, ((yi >>> shift) & 1'b1)}) : {bitwidth{1'b0}};
   wire [bitwidth-1:0] xi_add = rnd_en ? (rnd_half1[bitwidth-1:0] + {{(bitwidth-1){1'b0}}, ((xi >>> shift) & 1'b1)}) : {bitwidth{1'b0}};
   wire [bitwidth-1:0] yi_shr = ($signed(yi) + $signed(yi_add)) >>> shift;
   wire [bitwidth-1:0] xi_shr = ($signed(xi) + $signed(xi_add)) >>> shift;

   reg [bitwidth-1:0] 	 xo,yo;
   reg [zwidth-1:0] zo;
   
   always @(posedge clock)
     if(reset)
       begin
	  xo <= 0;
	  yo <= 0;
	  zo <= 0;
       end
     else //if(enable)
       begin
	  xo <= z_is_pos ? xi - yi_shr : xi + yi_shr;
	  yo <= z_is_pos ? yi + xi_shr : yi - xi_shr;
	  zo <= z_is_pos ?   
		zi - constant :
		zi + constant;
       end
endmodule
