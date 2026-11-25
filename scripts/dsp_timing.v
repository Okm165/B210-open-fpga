// dsp_timing.v - does the place-and-route engine time DSP48E1 paths?
//
// Three DSP48E1 register configurations between fabric flip-flops, on a 5 ns
// clock (scripts/dsp_timing.xdc):
//   u_comb : no register inside (A, B -> P combinational, 4.39 ns)
//   u_mreg : MREG only           (A, B setup 2.79 ns; clock to P 1.96 ns)
//   u_full : AREG, BREG, MREG, PREG (setup 0.31/0.39 ns; clock to P 0.39 ns)
// The engine without container/patches/nextpnr-dsp48e1-timing.patch ignores
// the three cells and reports over 1 GHz.  With it the path through u_comb
// (flip-flop, 4.39 ns, flip-flop) misses 5 ns, and scripts/toolchain.sh
// requires exactly that report before it installs an engine.  Synthesized
// with -nodsp, or yosys moves the flip-flops into the DSP48E1 registers.
module dsp_timing (input codec_main_clk_p, input codec_main_clk_n, input PPS_IN_EXT,
             output LED_RX1, output LED_TXRX1_RX, output LED_TXRX1_TX);
   wire clk_i, clk;
   IBUFDS ibuf (.I(codec_main_clk_p), .IB(codec_main_clk_n), .O(clk_i));
   BUFG   bufg (.I(clk_i), .O(clk));
   (* keep *) reg [29:0] a = 0; (* keep *) reg [17:0] b = 0;
   always @(posedge clk) begin a <= {a[28:0], PPS_IN_EXT}; b <= {b[16:0], a[29]}; end
   wire [47:0] p_comb, p_mreg, p_full;
   (* keep *) reg  [47:0] r_comb, r_mreg, r_full;
   always @(posedge clk) begin r_comb <= p_comb; r_mreg <= p_mreg; r_full <= p_full; end
   assign LED_RX1 = ^r_comb; assign LED_TXRX1_RX = ^r_mreg; assign LED_TXRX1_TX = ^r_full;
`define DSP(NAME, AR, BR, MR, PR, POUT) \
   DSP48E1 #(.AREG(AR), .BREG(BR), .CREG(0), .DREG(0), .ADREG(0), .MREG(MR), .PREG(PR), \
             .ACASCREG(AR), .BCASCREG(BR), .OPMODEREG(0), .ALUMODEREG(0), .INMODEREG(0), \
             .CARRYINREG(0), .CARRYINSELREG(0), .USE_MULT("MULTIPLY"), .USE_DPORT("FALSE")) NAME ( \
      .CLK(clk), .A(a), .B(b), .C(48'd0), .D(25'd0), .P(POUT), \
      .OPMODE(7'b0000101), .ALUMODE(4'b0000), .INMODE(5'b00000), .CARRYINSEL(3'b000), .CARRYIN(1'b0), \
      .CEA1(1'b1), .CEA2(1'b1), .CEB1(1'b1), .CEB2(1'b1), .CEC(1'b1), .CED(1'b1), .CEAD(1'b1), .CEM(1'b1), \
      .CEP(1'b1), .CECTRL(1'b1), .CECARRYIN(1'b1), .CEINMODE(1'b1), .CEALUMODE(1'b1), \
      .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0), .RSTM(1'b0), .RSTP(1'b0), .RSTCTRL(1'b0), \
      .RSTALLCARRYIN(1'b0), .RSTINMODE(1'b0), .RSTALUMODE(1'b0), \
      .ACIN(30'd0), .BCIN(18'd0), .PCIN(48'd0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0))
   `DSP(u_comb, 0, 0, 0, 0, p_comb);
   `DSP(u_mreg, 0, 0, 1, 0, p_mreg);
   `DSP(u_full, 1, 1, 1, 1, p_full);
endmodule
