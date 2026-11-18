// tb_pair.v - the two-channel requirement, proven in simulation.
//
// The B210 runs two identical radio instances.  "Identical" is a property, not
// an intention: this bench instantiates the receive and transmit chains twice,
// drives them with the same samples and asserts
//
//   1. two receive chains programmed to the same LO produce byte-identical
//      output, dither included, while a third receive chain programmed to a
//      different LO is running alongside - so one channel cannot perturb
//      another,
//   2. neither receive channel hits the 16-bit rail on a full-scale quadrature
//      input,
//   3. the two transmit chains produce the same sample sequence from the same
//      input (compared per-channel, because the interpolator strobe phase
//      depends on when each channel's rate register was written).
//
// Both directions use the same oscillator (dds_lut) and the same exact-multiply
// mixer, so one bench guards the RX and TX implementations at once.
`timescale 1ns/1ps

module tb_pair;

   reg clk = 0;
   always #5 clk = ~clk;

   reg rst = 1;
   reg set_stb = 0;
   reg [7:0]  set_addr = 0;
   reg [31:0] set_data = 0;

   integer errors = 0;
   task check(input cond, input [255:0] what);
      begin
         if (!cond) begin
            $display("FAIL: %0s", what);
            errors = errors + 1;
         end
      end
   endtask

   task seta(input [7:0] a, input [31:0] d);
      begin
         @(posedge clk); set_stb <= 1; set_addr <= a; set_data <= d;
         @(posedge clk); set_stb <= 0;
      end
   endtask

   // ------------------------------------------------------------------ RX ---
   reg  [23:0] rx_i = 0, rx_q = 0;
   reg         run_rx = 0;
   wire [31:0] rx_a, rx_b, rx_r;
   wire        stb_a, stb_b, stb_r;
   wire [31:0] dbg_a, dbg_b, dbg_r;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) ddc_a
     (.clk(clk), .rst(rst), .clr(1'b0), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q), .sample(rx_a), .run(run_rx), .strobe(stb_a), .debug(dbg_a));

   ddc_chain #(.BASE(32), .DSPNO(1), .WIDTH(24), .DEVICE("7SERIES")) ddc_b
     (.clk(clk), .rst(rst), .clr(1'b0), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q), .sample(rx_b), .run(run_rx), .strobe(stb_b), .debug(dbg_b));

   // Reference: same settings as channel A, never re-programmed.
   ddc_chain #(.BASE(128), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) ddc_r
     (.clk(clk), .rst(rst), .clr(1'b0), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .rx_fe_i(rx_i), .rx_fe_q(rx_q), .sample(rx_r), .run(run_rx), .strobe(stb_r), .debug(dbg_r));

   // ------------------------------------------------------------------ TX ---
   reg  [31:0] tx_sample = 0;
   reg         run_tx = 0;
   wire [23:0] tx_a_i, tx_a_q, tx_b_i, tx_b_q;
   wire        tx_stb_a, tx_stb_b;
   wire [31:0] tdbg_a, tdbg_b;

   duc_chain #(.BASE(64), .DSPNO(0), .WIDTH(24), .NEW_HB_INTERP(1), .DEVICE("7SERIES")) duc_a
     (.clk(clk), .rst(rst), .clr(1'b0), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_a_i), .tx_fe_q(tx_a_q), .sample(tx_sample), .run(run_tx),
      .strobe(tx_stb_a), .debug(tdbg_a));

   duc_chain #(.BASE(96), .DSPNO(1), .WIDTH(24), .NEW_HB_INTERP(1), .DEVICE("7SERIES")) duc_b
     (.clk(clk), .rst(rst), .clr(1'b0), .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .tx_fe_i(tx_b_i), .tx_fe_q(tx_b_q), .sample(tx_sample), .run(run_tx),
      .strobe(tx_stb_b), .debug(tdbg_b));

   // ---------------------------------------------------------------- drive ---
   integer n = 0;
   real arg;
   always @(posedge clk) begin
      if (rst) n <= 0;
      else if (run_rx) begin
         arg = 2.0 * 3.14159265358979 * $itor(n) / 64.0;
         // Full-scale 24-bit quadrature input (12-bit ADC at [23:12]).
         rx_i <= $rtoi(8384512.0 * $cos(arg));
         rx_q <= $rtoi(8384512.0 * $sin(arg));
         n <= n + 1;
      end
   end

   // ------------------------------------------------------------ observers ---
   integer n_rx = 0, n_ar = 0, rail_i = 0;
   integer tx_na = 0, tx_nb = 0, tx_diff = 0;
   reg [23:0] txa_i [0:1023];
   reg [23:0] txa_q [0:1023];
   reg [23:0] txb_i [0:1023];
   reg [23:0] txb_q [0:1023];

   always @(posedge clk) begin
      if (!rst && stb_a) begin
         n_rx = n_rx + 1;
         if (stb_r) begin
            n_ar = n_ar + 1;
            if (rx_a !== rx_r) $display("DBG A/R differ at %0d: %h vs %h", n_ar, rx_a, rx_r);
         end
         if ($signed(rx_a[31:16]) == 16'sh7FFF || $signed(rx_a[31:16]) == -16'sh8000 ||
             $signed(rx_a[15:0])  == 16'sh7FFF || $signed(rx_a[15:0])  == -16'sh8000 ||
             $signed(rx_b[31:16]) == 16'sh7FFF || $signed(rx_b[31:16]) == -16'sh8000 ||
             $signed(rx_b[15:0])  == 16'sh7FFF || $signed(rx_b[15:0])  == -16'sh8000)
           rail_i = rail_i + 1;
      end
      if (!rst && tx_stb_a && tx_na < 1024) begin
         txa_i[tx_na] = tx_a_i; txa_q[tx_na] = tx_a_q; tx_na = tx_na + 1;
      end
      if (!rst && tx_stb_b && tx_nb < 1024) begin
         txb_i[tx_nb] = tx_b_i; txb_q[tx_nb] = tx_b_q; tx_nb = tx_nb + 1;
      end
   end

   integer k, mismatches;
   initial begin
      mismatches = 0;
      repeat (8) @(posedge clk);
      rst <= 0;
      repeat (4) @(posedge clk);

      // ---- prime both TX interpolators (recipe from tb_duc_chain) --------
      seta(8'd64, 32'h0); seta(8'd65, 32'h1FFFF); seta(8'd66, (2'b11 << 8) | 8'd2);
      seta(8'd96, 32'h0); seta(8'd97, 32'h1FFFF); seta(8'd98, (2'b11 << 8) | 8'd2);
      run_tx <= 1;
      repeat (300) @(posedge clk);
      rst <= 1;
      repeat (4) @(posedge clk);
      rst <= 0;
      repeat (4) @(posedge clk);
      run_tx <= 0;

      // ---- A and the reference at fs/8, B at 2.5x fs/8 -------------------
      seta(8'd0,   32'h1000_0000);
      seta(8'd3,   32'h0);
      seta(8'd128, 32'h1000_0000);
      seta(8'd131, 32'h0);
      seta(8'd32,  32'h2800_0000);
      seta(8'd35,  32'h0);
      run_rx <= 1;

      // ---- TX: both channels on the same DC input ------------------------
      seta(8'd64, 32'h0); seta(8'd65, 32'h1FFFF); seta(8'd66, (2'b11 << 8) | 8'd2);
      seta(8'd96, 32'h0); seta(8'd97, 32'h1FFFF); seta(8'd98, (2'b11 << 8) | 8'd2);
      run_tx <= 1;
      tx_sample <= {16'sd4096, 16'sd1024};

      repeat (3000) @(posedge clk);
      run_rx <= 0;
      run_tx <= 0;
      repeat (20) @(posedge clk);

      // A vs reference, sample by sample (checked continuously above).
      $display("PAIR: RX %0d samples; A vs reference %0d compared; rail hits %0d; TX %0d/%0d samples",
               n_rx, n_ar, rail_i, tx_na, tx_nb);

      for (k = 0; k < ((tx_na < tx_nb) ? tx_na : tx_nb); k = k + 1)
        if (txa_i[k] !== txb_i[k] || txa_q[k] !== txb_q[k]) tx_diff = tx_diff + 1;

      check(n_rx > 2500,      "enough receive samples captured");
      check(n_ar > 2500,      "channel A and the reference ran in lockstep");
      check(mismatches === 0, "channel A unaffected by B LO change");
      check(rail_i === 0,     "no 16-bit rail hit at full scale");
      check(tx_na > 300 && tx_nb > 300, "enough transmit samples captured");
      check(tx_diff === 0,    "transmit channels produce the same sample sequence");

      if (errors == 0)
        $display("PASS: channels byte identical in RX and TX, independent LOs, no rail hits");
      else
        $display("FAIL: %0d errors", errors);
      $finish;
   end

   initial begin
      #3000000;
      $display("FAIL: timeout");
      $finish;
   end

   // Byte-identity of A and the reference is checked continuously; count the
   // comparisons so a silent zero cannot pass the test.
   always @(posedge clk)
     if (!rst && stb_a && stb_r && (rx_a !== rx_r)) mismatches = mismatches + 1;

endmodule
