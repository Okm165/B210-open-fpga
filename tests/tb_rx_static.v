// tb_rx_static.v - the receive DSP is a static function of its input.
//
// Two identical ddc_chain instances see the same stimulus and the same reset.
// One of them is hammered with register writes on every address that used to
// carry a signal-path option (rate, halfband, scale, coefficient reload).  The
// outputs must be bit-identical for the whole run: proof that those options no
// longer exist in hardware, rather than merely being ignored by software.
//
// Notes on what deliberately still matters:
//   BASE+0  LO phase increment  - tuning; writing it changes the output by
//                                 design (checked separately, below)
//   BASE+3  I/Q mux             - invert / swap / real mode, the only other
//                                 live control, written by the frontend driver
module tb_rx_static;

   localparam integer N = 200000;

   reg clk = 0; always #8.138 clk = ~clk;    // 61.44 MHz
   reg rst = 1;

   // ---- stimulus: pseudorandom 24-bit I/Q --------------------------------
   reg [31:0] lfsr = 32'h1234_5678;
   reg signed [23:0] stim_i = 0, stim_q = 0;
   always @(posedge clk) begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      stim_i <= $signed(lfsr[23:0]);
      stim_q <= $signed({lfsr[15:0], lfsr[31:24]});
   end

   // ---- two DDCs ---------------------------------------------------------
   reg        stb_a = 0, stb_b = 0;
   reg  [7:0] addr_a = 0, addr_b = 0;
   reg [31:0] data_a = 0, data_b = 0;
   wire [31:0] sample_a, sample_b;
   wire strobe_a, strobe_b;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut_a (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(stb_a), .set_addr(addr_a), .set_data(data_a),
      .rx_fe_i(stim_i), .rx_fe_q(stim_q),
      .sample(sample_a), .run(1'b1), .strobe(strobe_a), .debug());

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut_b (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(stb_b), .set_addr(addr_b), .set_data(data_b),
      .rx_fe_i(stim_i), .rx_fe_q(stim_q),
      .sample(sample_b), .run(1'b1), .strobe(strobe_b), .debug());

   // ---- hammer B with writes to every dead option address ----------------
   // Addresses 1,2 and 4..15 are no longer decoded (rate, halfband, scale,
   // coefficient reload).  Address 3 is also written, always with the value
   // the driver leaves it at (zero), to show repeated default writes are inert.
   integer w = 0;
   always @(posedge clk) begin
      stb_b  <= 1'b1;
      w      <= (w == 15) ? 0 : w + 1;
      // never address 0 (that is the LO, which must keep working) and write
      // address 3 only with the value the driver leaves (zero)
      addr_b <= (w == 0) ? 8'd9 : (w == 3) ? 8'd3 : w[7:0];
      data_b <= (w == 3) ? 32'h0 : {lfsr[31:16], lfsr[15:0]} ^ w;
   end

   // ---- comparison -------------------------------------------------------
   integer cycles = 0, mismatches = 0, compared = 0;
   always @(posedge clk) begin
      if (!rst) begin
         cycles = cycles + 1;
         if (strobe_a !== strobe_b) begin
            mismatches = mismatches + 1;
            if (mismatches < 4) $display("STATIC: strobe mismatch at cycle %0d", cycles);
         end else if (strobe_a) begin
            compared = compared + 1;
            if (sample_a !== sample_b) begin
               mismatches = mismatches + 1;
               if (mismatches < 4)
                  $display("STATIC: output mismatch at cycle %0d: %08x vs %08x",
                           cycles, sample_a, sample_b);
            end
         end
      end
   end

   // ---- LO must still work: a non-zero phase increment changes the output
   reg [31:0] lo_a = 0;
   wire [31:0] sample_lo;
   wire strobe_lo;
   reg stb_lo = 0, lo_done = 0;
   integer lo_diff = 0;

   ddc_chain #(.BASE(0), .DSPNO(0), .WIDTH(24), .DEVICE("7SERIES")) dut_lo (
      .clk(clk), .rst(rst), .clr(1'b0),
      .set_stb(stb_lo), .set_addr(8'd0), .set_data(lo_a),
      .rx_fe_i(stim_i), .rx_fe_q(stim_q),
      .sample(sample_lo), .run(1'b1), .strobe(strobe_lo), .debug());

   initial begin
      repeat (8) @(posedge clk);
      rst <= 0;
      repeat (100) @(posedge clk);
      // tune the third instance to fs/8 and count how many samples differ
      @(posedge clk); stb_lo <= 1; lo_a <= 32'h2000_0000;
      @(posedge clk); stb_lo <= 0;
      repeat (60000) @(posedge clk);
      $display("STATIC: %0d cycles, %0d samples compared, %0d mismatches under write hammering",
               cycles, compared, mismatches);
      $display("STATIC: LO=fs/8 differs from LO=0 on %0d samples (tuning must still work)", lo_diff);
      if (mismatches == 0 && lo_diff > 0 && compared > 50000)
         $display("STATIC: PASS - the stream is a constant function of the input; only LO moves it");
      else
         $display("STATIC: FAIL");
      $finish;
   end

   always @(posedge clk) if (!rst && strobe_lo && strobe_a)
     if (sample_lo !== sample_a) lo_diff = lo_diff + 1;

endmodule
