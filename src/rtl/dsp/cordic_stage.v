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
   // Round the shifted operand to nearest (add half an LSB before the
   // arithmetic shift) instead of flooring it.  Each floor() rounds toward
   // -infinity; nineteen stages in series add up to a systematic negative
   // offset, measured as a DC component at the CORDIC output.
   wire signed [bitwidth:0] yi_rnd = $signed(yi) + ((shift == 0) ? 0 : (65'sd1 <<< (shift-1)));
   wire signed [bitwidth:0] xi_rnd = $signed(xi) + ((shift == 0) ? 0 : (65'sd1 <<< (shift-1)));
   wire [bitwidth-1:0] yi_shr = yi_rnd >>> shift;
   wire [bitwidth-1:0] xi_shr = xi_rnd >>> shift;

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
