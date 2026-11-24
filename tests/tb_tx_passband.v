// tb_tx_passband.v - TX passband measured with a coherent single-bin detector.
//
// For each frequency, a steady tone is driven at the host rate and the output
// is correlated with cos/sin at that same frequency (in output-sample units)
// over an integer number of cycles.  A single-bin correlation rejects DC,
// images and every other component by construction, so the result is the
// chain's gain at that frequency - no window, no leakage, no interpretation.
// At bypass the answer is known a priori (a delay line: 0.00 dB) and the bench
// checks it, which validates the estimator before it is trusted at other rates.
//
// The chain is the stock Ettus one (CORDIC, hb47_int halfbands, 4-stage CIC)
// with the scale word UHD's tx_dsp_core_3000 writes for each CIC rate, so
// 0 dB here is 0.99925 at the pins (the CORDIC's 1.64676 against UHD's 1.648).
//
// Sweep: configs 0, 1, 2 and 4 run to 0.4375 fs_in; the two configs with a
// CIC behind them stop at 0.219.
//
// Measured (host band edge = 0.5 fs_in):
//   bypass, total 1:        -0.01 dB at every bin up to 0.4375
//   one halfband, total 2:  -0.01 dB to 0.375, -0.23 dB at 0.4375; image
//                           -76 dBc or better to 0.312, -69.5 at 0.375,
//                           -31.8 at 0.4375.  (cfg 1 is the halfband next to
//                           the CIC, the one UHD enables for an interpolation
//                           of 2; cfg 4 is the other one alone, which UHD
//                           never selects.  Both measure the same.)  The
//                           tone's image lands at 1-f, so beyond ~0.4 fs_in
//                           both droop and image are set by the 47-tap
//                           halfband's transition band.
//   two halfbands, total 4: -0.01 dB to 0.375, -0.23 dB at 0.4375, image
//                           <= -75 dBc to 0.312
//   two halfbands, CIC 4:   -0.02 .. -0.17 dB to 0.219, image <= -80 dBc
//   CIC only, total 3:      what UHD programs for an odd interpolation, and
//                           what it warns about ("the user should expect CIC
//                           rolloff").  The 4-stage CIC's own response:
//                           -0.06 dB at 0.031 fs_in growing to -2.49 dB at
//                           0.219, image -92 down to -40.5 dBc.  Stock
//                           behaviour, pinned here so it cannot change
//                           unnoticed.
`timescale 1ns/1ps

// Coherent single-bin detector: measures the TX chain's gain at one frequency
// per run, rejecting images, DC and everything else by construction.
module tb_tx_passband;
  reg clk=0; always #5 clk=~clk;
  reg rst=1, set_stb=0, run=0;
  reg [7:0] set_addr=0; reg [31:0] set_data=0, sample=0;
  wire [23:0] ti,tq; wire stb; wire [31:0] dbg;
  duc_chain #(.BASE(0),.DSPNO(0),.WIDTH(24),.DEVICE("7SERIES")) dut
    (.clk(clk),.rst(rst),.clr(1'b0),.set_stb(set_stb),.set_addr(set_addr),.set_data(set_data),
     .tx_fe_i(ti),.tx_fe_q(tq),.sample(sample),.run(run),.strobe(stb),.debug(dbg));
  task wr(input [7:0] a, input [31:0] d); begin @(negedge clk); set_stb=1; set_addr=a; set_data=d; @(negedge clk); set_stb=0; end endtask
  integer cfg,k,rate,total,nb,nbmax,n,errors;
  real fedge, rate_pow;
  reg [7:0] hb;
  real frac, w, w2, ph, a16, ci, cq, ci2, cq2, amp, amp2, gain, img_db;
  initial begin
    errors = 0;
    repeat(8) @(posedge clk); @(negedge clk); rst=0;
    wr(8'd0,32'd0);                         // LO parked
    for (cfg=0; cfg<6; cfg=cfg+1) begin
      // nbmax: the halfband-only configs are swept to the band edge (0.4375
      // fs_in); cfg 3 (two halfbands + CIC) and cfg 5 (CIC only) have a CIC
      // image that collapses near Nyquist, so they keep the 0.219 ceiling.
      nbmax = 10;
      case (cfg) 0: begin hb=2'b00; rate=1; end
                 1: begin hb=2'b01; rate=1; end
                 2: begin hb=2'b11; rate=1; end
                 3: begin hb=2'b11; rate=4; nbmax=7; end
                 4: begin hb=2'b10; rate=1; end
                 5: begin hb=2'b00; rate=3; nbmax=7; end endcase
      total = rate*(hb[0]+1)*(hb[1]+1);
      // the scale tx_dsp_core_3000 writes for this CIC rate
      rate_pow = $pow(1.0*rate, 3);
      wr(8'd1, $rtoi(65536.0*$pow(2.0, $ceil($ln(rate_pow)/$ln(2.0)))/(1.648*rate_pow) + 0.5));
      wr(8'd2,{hb,8'd0}|rate); run=1;
      for (nb=0; nb<nbmax; nb=nb+1) begin
        case (nb) 0: frac=2.0/64; 1: frac=4.0/64; 2: frac=6.0/64; 3: frac=8.0/64;
                 4: frac=10.0/64; 5: frac=12.0/64; 6: frac=14.0/64;
                 7: frac=20.0/64; 8: frac=24.0/64; 9: frac=28.0/64; endcase
        w  = 2.0*3.14159265358979*frac/total;        // signal, per output sample
        w2 = 2.0*3.14159265358979*(1.0-frac)/total;  // nearest interpolation image
        // settle with the tone running, integer number of 64-sample windows
        k = 0;
        repeat (4096*total) begin
          @(negedge clk);
          if (stb) begin
            ph = 2.0*3.14159265358979*frac*k;
            // complex excitation: a single positive frequency.  With a real
            // cosine the image sits on the negative-frequency component of
            // the stimulus; with e^{jwt} the image is a separate line and is
            // measured without any sign ambiguity.
            sample[31:16] = $rtoi(1000.0*$cos(ph));
            sample[15:0]  = $rtoi(1000.0*$sin(ph));
            k = k + 1;
          end
        end
        // coherent detection over 64 input samples = 64*total output samples
        ci = 0.0; cq = 0.0; ci2 = 0.0; cq2 = 0.0; n = 0;
        while (n < 64*total) begin
          @(negedge clk);
          if (stb) begin
            ph = 2.0*3.14159265358979*frac*k;
            // complex excitation: a single positive frequency.  With a real
            // cosine the image sits on the negative-frequency component of
            // the stimulus; with e^{jwt} the image is a separate line and is
            // measured without any sign ambiguity.
            sample[31:16] = $rtoi(1000.0*$cos(ph));
            sample[15:0]  = $rtoi(1000.0*$sin(ph));
            k = k + 1;
          end
          @(posedge clk); #1;
          ci  = ci  + $signed(ti)*$cos(w*n);
          cq  = cq  + $signed(ti)*$sin(w*n);
          ci2 = ci2 + $signed(ti)*$cos(w2*n);
          cq2 = cq2 + $signed(ti)*$sin(w2*n);
          n = n + 1;
        end
        amp = 2.0*$sqrt(ci*ci+cq*cq)/(64.0*total);
        amp2 = 2.0*$sqrt(ci2*ci2+cq2*cq2)/(64.0*total);
        gain = amp/(256000.0);
        img_db = 20.0*$log10(amp2/(amp+1e-9) + 1e-12);
        if (cfg == 0) img_db = -999.0;   // no interpolation: nothing to reject
        $display("PASSBAND cfg %0d total %2d f=%.3f fs_in  gain %+0.2f dB  image %6.1f dBc",
                 cfg, total, frac, 20.0*$log10(gain), img_db);
        // The interpolation image must be suppressed by the halfbands; a
        // polyphase phase misalignment would show up here first, near the
        // band edge.  Loose bound: the design target is -65 dBc, the guard
        // only has to catch a structural break.
        // Image guard, frequency dependent because the halfband's transition
        // band is what limits the clean operating band.  Measured on the
        // single-halfband paths (cfg 1/4):
        //   f <= 0.312 fs_in  <= -76 dBc
        //   0.375             -69.5 dBc  <- clean-band edge
        //   0.438             -31.8 dBc  <- transition shoulder: the image of
        //                                  a tone at f lands at 1-f, which for
        //                                  f > ~0.4 is inside the transition
        //                                  band, so no practical 47-tap
        //                                  halfband rejects it.
        // The guard therefore requires -65 dBc to 0.375 and only catches a
        // structural break (-25 dBc) at the shoulder.
        // cfg 5 is the CIC-only path (no halfband, hence no image
        // cancellation): -40.5 dBc and -2.49 dB at 0.219 fs_in is the 4-stage
        // CIC itself.
        if (cfg == 5 && img_db > -39.5) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - CIC image %.1f dBc at %.4f fs_in", img_db, frac);
        end
        if (cfg == 5 && nb == 6 && (20.0*$log10(gain) < -2.6 || 20.0*$log10(gain) > -2.4)) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - CIC droop %.2f dB at %.4f fs_in, expected -2.49",
                    20.0*$log10(gain), frac);
        end
        if (cfg > 0 && cfg != 5 && frac <= 24.0/64 && img_db > -65.0) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - image %.1f dBc at %.4f fs_in (total %0d)",
                    img_db, frac, total);
        end
        if (cfg > 0 && frac > 24.0/64 && img_db > -25.0) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - shoulder image %.1f dBc at %.4f fs_in (total %0d)",
                    img_db, frac, total);
        end
        // Bypass must be flat (it is a delay line and two fixed gains); a
        // shaped bypass was the defect this bench exists to catch.
        // Interpolated rates may roll off towards the host Nyquist but must
        // never boost.
        if (cfg == 0 && (gain > 0.99925 + 0.001 || gain < 0.99925 - 0.001)) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - bypass is not flat at %.3f fs_in (%+0.2f dB)",
                    frac, 20.0*$log10(gain));
        end
        if (gain > 1.002) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - gain above unity at %.3f fs_in (%+0.2f dB)",
                    frac, 20.0*$log10(gain));
        end
        // Band-edge droop of the single/two-halfband paths.  The 47-tap
        // halfband is flat to 0.375 fs_in and reaches -0.23 dB at 0.4375.
        // This is a spec guard, not a shape: it catches a structural break
        // such as the two output phases of a halfband coming from different
        // input samples, which droops by decibels.
        if ((cfg == 1 || cfg == 2 || cfg == 4) && nb >= 7) begin
           fedge = 20.0*$log10(gain);
           if (fedge < -0.35) begin
              errors = errors + 1;
              $display("PASSBAND: FAIL - halfband droop %.2f dB at %.4f fs_in",
                       fedge, frac);
           end
        end
      end
      run=0; repeat(64) @(posedge clk);
    end
    if (errors == 0)
       $display("PASSBAND: PASS - bypass flat, no boost at any rate");
    else
       $display("PASSBAND: FAIL - %0d checks failed", errors);
    $finish;
  end
endmodule
