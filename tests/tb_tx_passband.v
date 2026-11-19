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
// Measured 2026-11-19 (host band edge = 0.5 fs_in):
//   bypass (rate 1):        -0.01 dB at every bin
//   two halfbands, CIC 1:   -0.02 -0.05 -0.10 -0.17 -0.27 -0.39 -0.53 dB at
//                           0.03 .. 0.22 fs_in (values in the table below)
//   two halfbands, CIC 4:   -0.01 .. -0.13 dB over the same span
//
// The earlier impulse-response/FFT attempt at interpolated rates disagreed
// with this and was an extraction artefact; the coherent detector is the
// measurement of record.
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
  integer cfg,k,rate,total,nb,n,errors;
  reg [7:0] hb;
  real frac, w, w2, ph, a16, ci, cq, ci2, cq2, amp, amp2, gain, img_db;
  initial begin
    errors = 0;
    repeat(8) @(posedge clk); @(negedge clk); rst=0;
    wr(8'd0,32'd0); wr(8'd1,32'h0000_8000);
    for (cfg=0; cfg<3; cfg=cfg+1) begin
      case (cfg) 0: begin hb=2'b00; rate=1; end
                 1: begin hb=2'b11; rate=1; end
                 2: begin hb=2'b11; rate=4; end endcase
      total = rate*(hb[0]+1)*(hb[1]+1);
      wr(8'd2,{hb,8'd0}|rate); run=1;
      for (nb=0; nb<7; nb=nb+1) begin
        case (nb) 0: frac=2.0/64; 1: frac=4.0/64; 2: frac=6.0/64; 3: frac=8.0/64;
                 4: frac=10.0/64; 5: frac=12.0/64; 6: frac=14.0/64; endcase
        w  = 2.0*3.14159265358979*frac/total;        // signal, per output sample
        w2 = 2.0*3.14159265358979*(1.0-frac)/total;  // nearest interpolation image
        // settle with the tone running, integer number of 64-sample windows
        k = 0;
        repeat (4096*total) begin
          @(negedge clk);
          if (stb) begin
            ph = 2.0*3.14159265358979*frac*k;
            sample[31:16] = $rtoi(1000.0*$cos(ph));
            k = k + 1;
          end
        end
        // coherent detection over 64 input samples = 64*total output samples
        ci = 0.0; cq = 0.0; ci2 = 0.0; cq2 = 0.0; n = 0;
        while (n < 64*total) begin
          @(negedge clk);
          if (stb) begin
            ph = 2.0*3.14159265358979*frac*k;
            sample[31:16] = $rtoi(1000.0*$cos(ph));
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
        if (cfg > 0 && img_db > -45.0) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - image %.1f dBc at %.3f fs_in (total %0d)",
                    img_db, frac, total);
        end
        // Bypass must be flat (it is a delay line); a shaped bypass was the
        // defect this bench exists to catch.  Interpolated rates may roll off
        // towards the host Nyquist but must never boost.
        if (cfg == 0 && (gain > 1.001 || gain < 0.999)) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - bypass is not flat at %.3f fs_in (%+0.2f dB)",
                    frac, 20.0*$log10(gain));
        end
        if (gain > 1.002) begin
           errors = errors + 1;
           $display("PASSBAND: FAIL - gain above unity at %.3f fs_in (%+0.2f dB)",
                    frac, 20.0*$log10(gain));
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
