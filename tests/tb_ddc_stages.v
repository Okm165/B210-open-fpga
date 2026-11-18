// tb_ddc_stages.v - per-stage contamination capture for the RX DDC.
//
// Feeds ADC-like data (a 12-bit-quantized complex tone plus LSB-level dither,
// exactly what the AD9361 delivers) through the whole chain and dumps every
// stage at its native rate to plain-text files for spectral analysis:
//
//   /tmp/opencode/ddc_stages/in.txt   rx_fe_i/q      every clk      (2^21)
//   /tmp/opencode/ddc_stages/cic.txt  i_cic/q_cic    every 2 clks   (CIC /2)
//   /tmp/opencode/ddc_stages/hb1.txt  i_hb1/q_hb1    every 4 clks   (HB1 /2)
//   /tmp/opencode/ddc_stages/hb2.txt  i_hb2/q_hb2    every 8 clks   (HB2 /2)
//   /tmp/opencode/ddc_stages/out.txt  sample I/Q     every 8 clks   (final)
//
// Analysis (numpy, outside this repo) locates *where* each spur is born by
// comparing the spectra stage by stage.
//
// NCO phase increment is a plusarg (+NCO_INC=<hex>) so the mixer can be
// analysed at zero and at a real offset.  Default 0.
`timescale 1ns/1ps

module tb_ddc_stages;

   localparam integer WIDTH = 24;
   localparam integer NCLK  = 21;          // 2^NCLK input clocks

   reg                clk = 0;
   reg                rst = 1;
   reg                clr = 0;
   reg                run = 0;
   reg                set_stb = 0;
   reg  [7:0]         set_addr = 0;
   reg  [31:0]        set_data = 0;
   reg  [WIDTH-1:0]   rx_i = 0;
   reg  [WIDTH-1:0]   rx_q = 0;

   wire [31:0]        sample;
   wire               strobe;
   wire [31:0]        debug;

   always #5 clk = ~clk;

   ddc_chain #(
      .BASE(0), .DSPNO(0), .WIDTH(WIDTH),
      .NEW_HB_DECIM(1), .DEVICE("7SERIES")
   ) dut (
      .clk(clk), .rst(rst), .clr(clr),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q),
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

   // stimulus: complex tone at 1/1024 of the input rate, 12-bit quantised,
   // with LSB dither - the ADC model
   integer n, q12_i, q12_q;
   real    arg, a16, dith;
   integer seed = 32'hD1CE;

   // capture files
   integer f_in, f_cic, f_hb1, f_hb2, f_out, f_cor;
   reg [8*128-1:0] dir;
   integer dir_len;

   initial begin
      // output directory: +DIR=<path>, default /tmp/opencode/ddc_stages
      if (!$value$plusargs("DIR=%s", dir)) begin
         dir = "/tmp/opencode/ddc_stages";
         dir_len = 24;
      end else begin
         dir_len = 0;
         while (dir[dir_len*8 +: 8] != 0 && dir_len < 127) dir_len = dir_len + 1;
      end
      a16 = 8192.0;                       // -12 dBFS of the 16-bit interface
      f_in  = $fopen({dir, "/in.txt"},  "w");
      f_cic = $fopen({dir, "/cic.txt"}, "w");
      f_hb1 = $fopen({dir, "/hb1.txt"}, "w");
      f_hb2 = $fopen({dir, "/hb2.txt"}, "w");
      f_out = $fopen({dir, "/out.txt"}, "w");
      f_cor = $fopen({dir, "/cordic.txt"}, "w");

      repeat (8) @(posedge clk);
      rst <= 1'b0;
      repeat (4) @(posedge clk);

      set_reg(8'd1, 32'h0001FFFF);                    // scale ~1.0 Q17
      set_reg(8'd2, 32'h0000_0000 | (2'b11 << 8) | 8'd2); // HB on, CIC rate 2
      set_reg(8'd3, 32'h0000_0000);                   // complex, no swap
      if ($test$plusargs("NCO_INC")) begin : ncoarg
         integer inc;
         if (!$value$plusargs("NCO_INC=%d", inc)) inc = 0;
         set_reg(8'd0, inc);
      end else begin
         set_reg(8'd0, 32'h0000_0000);
      end
      run <= 1'b1;

      for (n = 0; n < (1 << NCLK); n = n + 1) begin
         @(posedge clk);
         // 12-bit ADC quantisation of the ideal tone + 1-LSB dither
         arg    = 2.0 * 3.14159265358979 * $itor(n) / 1024.0;
         dith   = $itor(($random(seed) % 3));
         q12_i  = $rtoi(($itor(a16) * $cos(arg) + dith) / 8.0) * 8; // 13->12-bit grid
         q12_q  = $rtoi(($itor(a16) * $sin(arg) + dith) / 8.0) * 8;
         rx_i <= {q12_i[15:0], 8'd0};
         rx_q <= {q12_q[15:0], 8'd0};
         $fwrite(f_in, "%0d %0d\n", $signed(rx_i[23:8]), $signed(rx_q[23:8]));
         $fwrite(f_cor, "%0d %0d\n",
                 $signed(dut.i_cordic[24:9]), $signed(dut.q_cordic[24:9]));
         if (dut.strobe_cic)
            $fwrite(f_cic, "%0d %0d\n",
                    $signed(dut.i_cic[23:8]), $signed(dut.q_cic[23:8]));
         if (dut.new_hb.data_valid1)
            $fwrite(f_hb1, "%0d %0d\n",
                    $signed(dut.new_hb.i_hb1[41:18]), $signed(dut.new_hb.q_hb1[41:18]));
         if (dut.new_hb.data_valid2)
            $fwrite(f_hb2, "%0d %0d\n",
                    $signed(dut.new_hb.i_hb2[41:18]), $signed(dut.new_hb.q_hb2[41:18]));
         if (strobe)
            $fwrite(f_out, "%0d %0d\n",
                    $signed(sample[31:16]), $signed(sample[15:0]));
      end

      $fclose(f_in); $fclose(f_cic); $fclose(f_hb1); $fclose(f_hb2); $fclose(f_out);
      $fclose(f_cor);
      $display("PASS: stage capture complete (%0d input clocks, nco_inc=%0d)",
               1 << NCLK, dut.phase_inc);
      $finish;
   end

   initial begin
      #400000000;
      $display("FAIL: timeout");
      $finish;
   end

endmodule
