// tb_duc_stages.v - per-stage contamination capture for the TX DUC.
//
// Mirror of tb_ddc_stages: a mocked complex baseband tone (12-bit-quantised
// + dither) is fed at the input strobe (x8 interpolation: HB1 -> HB2 -> CIC),
// the CORDIC up-mixes at +NCO_INC (default fs/16), and every stage is dumped
// at its native rate for external spectral analysis:
//
//   <dir>/in.txt   sample {I,Q}    at input strobe (~2^18 slow samples)
//   <dir>/hb1.txt  hb1_i/q         every 4 clks
//   <dir>/hb2.txt  hb2_i/q         every 2 clks
//   <dir>/cic.txt  i_interp/q      every clk
//   <dir>/out.txt  tx_fe_i/q[17:2] every clk
//
// Note the pipeline runs at 18-bit internally here (18->36->33->16); the
// dumps take the natural 18-bit slices.  Analysis tooling stays outside the
// repo (same contract as the RX harness).
`timescale 1ns/1ps

module tb_duc_stages;

   localparam integer WIDTH = 24;
   localparam integer NIN   = 18;          // 2^NIN input strobes (262k)

   reg                clk = 0;
   reg                rst = 1;
   reg                clr = 0;
   reg                run = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [31:0]        sample = 0;

   wire [WIDTH-1:0]   tx_i, tx_q;
   wire               strobe;
   wire [31:0]        debug;

   always #5 clk = ~clk;

   duc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
      .DEVICE("7SERIES")
   ) dut (
      .clk(clk), .rst(rst), .clr(clr),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_i), .tx_fe_q(tx_q),
      .sample(sample), .run(run), .strobe(strobe),
      .debug(debug)
   );

   task set_reg(input [7:0] addr, input [31:0] data);
      begin
         @(posedge clk);
         set_stb  <= 1'b1;
         set_addr <= addr;
         set_data <= data;
         @(posedge clk);
         set_stb  <= 1'b0;
      end
   endtask

   integer n, n_in, q12_i, q12_q;
   real    arg, a16, dith;
   integer seed = 32'hD0C1;
   integer f_in, f_hb1, f_hb2, f_cic, f_out;
   reg [8*128-1:0] dir;
   integer dir_len;

   initial begin
      if (!$value$plusargs("DIR=%s", dir)) begin
         dir = "/tmp/opencode/duc_stages";
         dir_len = 22;
      end else begin
         dir_len = 0;
         while (dir[dir_len*8 +: 8] != 0 && dir_len < 113) dir_len = dir_len + 1;
         dir[dir_len*8 +: 8*113] = 0;
      end
      a16 = 6000.0;
      f_in  = $fopen({dir, "/in.txt"},  "w");
      f_hb1 = $fopen({dir, "/hb1.txt"}, "w");
      f_hb2 = $fopen({dir, "/hb2.txt"}, "w");
      f_cic = $fopen({dir, "/cic.txt"}, "w");
      f_out = $fopen({dir, "/out.txt"}, "w");

      repeat (8) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);

      // prime + reset: hb47_int emits x for its first outputs and the CIC
      // integrators latch x permanently (bench-only; silicon powers up 0)
      set_reg(8'd0, 32'h0000_0000);
      set_reg(8'd1, 32'h0001_FFFF);
      set_reg(8'd2, (2'b11 << 8) | 8'd2);
      run <= 1'b1;
      repeat (300) @(posedge clk);
      rst <= 1'b1;
      repeat (4) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);
      run <= 1'b0;

      // NCO at fs/16 unless overridden, scale ~1.0, HBs on, CIC rate 2
      if ($test$plusargs("NCO_INC")) begin : ncoarg
         integer inc;
         if (!$value$plusargs("NCO_INC=%d", inc)) inc = 0;
         set_reg(8'd0, inc);
      end else begin
         set_reg(8'd0, 32'h1000_0000);   // +fs/16
      end
      set_reg(8'd1, 32'h0001_FFFF);
      set_reg(8'd2, (2'b11 << 8) | 8'd2);
      run <= 1'b1;
      n = 0;
      n_in = 0;

      // one clk per iteration; act on each DUT strobe exactly once.
      // (A previous version consumed 9 clks per iteration and skipped every
      // other strobe - the baseband aliased to DC and the output was a bare
      // clipped carrier.  The loop below is the proven tb_duc_sine pattern.)
      for (n = 0; n < (1 << NIN) * 8 + 4096; n = n + 1) begin
         @(posedge clk);
         if (dut.strobe) begin
            // n_in counts INPUT STROBES (not clk cycles - the loop counter n
            // runs at the clk rate and would place the tone at Nyquist)
            arg   = 2.0 * 3.14159265358979 * $itor(n_in) / 16.0;
            n_in  = n_in + 1;
            dith  = $itor(($random(seed) % 3));
            q12_i = $rtoi(($itor(a16) * $cos(arg) + dith) / 8.0) * 8;
            q12_q = $rtoi(($itor(a16) * $sin(arg) + dith) / 8.0) * 8;
            sample <= {q12_i[15:0], q12_q[15:0]};
            $fwrite(f_in, "%0d %0d\n", q12_i, q12_q);
         end
         if (dut.strobe_hb1)
            $fwrite(f_hb1, "%0d %0d\n",
                    $signed(dut.hb1_i[17:3]), $signed(dut.hb1_q[17:3]));
         // hb2's OUTPUT rate is strobe_cic (clk/2); strobe_hb2 is clk/4 and
         // undersamples the stage, aliasing its interpolation images into any
         // spectral analysis of this dump.  Measured: the same capture read
         // with the wrong tap showed a -17.6 dB image that does not exist.
         if (dut.strobe_cic)
            $fwrite(f_hb2, "%0d %0d\n",
                    $signed(dut.hb2_i[17:3]), $signed(dut.hb2_q[17:3]));
         $fwrite(f_cic, "%0d %0d\n",
                 $signed(dut.i_interp[17:3]), $signed(dut.q_interp[17:3]));
         $fwrite(f_out, "%0d %0d\n",
                 $signed(tx_i[WIDTH-1:WIDTH-16]), $signed(tx_q[WIDTH-1:WIDTH-16]));
      end

      $fclose(f_in); $fclose(f_hb1); $fclose(f_hb2); $fclose(f_cic); $fclose(f_out);
      $display("PASS: DUC stage capture complete (%0d input samples)", 1 << NIN);
      $finish;
   end

   initial begin
      #800000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
