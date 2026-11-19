// tb_gpif_cdc.v - the RX side of the FX3 interface across a genuinely
// asynchronous boundary.
//
// Every other bench that touches the GPIF drives gpif_clk and fifo_clk from the
// same clock.  On the board they are different oscillators: the FX3's IFCLK
// against the FPGA's 100 MHz, arbitrary phase, a few hundred ppm apart.  This
// bench runs fifo64_to_gpif2 (64-bit samples in on fifo_clk -> 32-bit words out
// on gpif_clk) with independent clocks and backpressure on the far side, which
// is the condition under which a packet boundary (tlast) could be separated
// from its data word, or a word duplicated or lost.
//
// Convention under test (axi_fifo64_to_fifo32): high half first, low half
// second, tlast on the low half of the packet's last word.
//
// The checker does not depend on where the stream starts (the first words may
// still be in flight when it begins): it locks onto the first packet/word seen
// and then requires the sequence to advance by exactly one 64-bit word per
// pair, with tlast every WORDS words on the low half.
`timescale 1ns/1ps

module tb_gpif_cdc;

   localparam integer PACKETS = 20;
   localparam integer WORDS   = 8;    // 64-bit words per packet

   // Independent clocks: 100 MHz and 101 MHz with 3 ns of phase.
   reg fifo_clk = 0;
   reg gpif_clk = 0;
   always #5.0 fifo_clk = ~fifo_clk;
   initial begin
      #3.0;
      forever #4.95 gpif_clk = ~gpif_clk;
   end

   reg fifo_rst = 1, gpif_rst = 1;
   reg started  = 0;                  // producers idle until reset settled

   reg  [63:0] a_in = 0;
   reg         a_in_last = 0, a_in_valid = 0;
   wire        a_in_ready;
   wire [31:0] a_out;
   wire        a_out_last, a_out_valid;
   reg         a_out_ready = 1;

   fifo64_to_gpif2 #(.FIFO_SIZE(9), .MTU(16)) dut (
      .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
      .i_tdata(a_in), .i_tlast(a_in_last), .i_tvalid(a_in_valid), .i_tready(a_in_ready),
      .gpif_clk(gpif_clk), .gpif_rst(gpif_rst),
      .o_tdata(a_out), .o_tlast(a_out_last), .o_tvalid(a_out_valid), .o_tready(a_out_ready));

   // ------------------------------------------------------------ producer
   integer ap = 0, aw = 0, seed_w = 32'h1357_9BDF;

   // The DUT samples tready at the posedge; latch exactly that value so the
   // producer advances on real handshakes only (sampling the live tready at
   // the negedge is a cycle stale and silently loses a word).
   reg ready_q;
   always @(posedge fifo_clk) ready_q <= a_in_ready;

   always @(negedge fifo_clk) begin
      if (!fifo_rst && started) begin
         if (a_in_valid && ready_q) begin
            if (aw == WORDS - 1) begin aw = 0; ap = ap + 1; end
            else aw = aw + 1;
         end
         if (ap < PACKETS) begin
            a_in       = {ap[15:0], aw[15:0], 32'd0};
            a_in_last  = (aw == WORDS - 1);
            a_in_valid = (($random(seed_w) & 3) != 0);
         end else
            a_in_valid = 1'b0;
      end
   end

   // ------------------------------------------------------------- checker
   integer a_words = 0, a_err = 0, locked = 0;
   integer cur_p = 0, cur_w = 0, seed_r = 32'h0A5A_5A5A;

   always @(posedge gpif_clk) begin
      a_out_ready <= (($random(seed_r) & 3) != 0);    // backpressure
      if (!gpif_rst && a_out_valid && a_out_ready) begin
         a_words = a_words + 1;
         if ((a_words & 1) == 1) begin                 // high half
            if (!locked) begin
               locked = 1;
               cur_p  = a_out[31:16];
               cur_w  = a_out[15:0];
            end
            if (a_out !== {cur_p[15:0], cur_w[15:0]}) begin
               a_err = a_err + 1;
               if (a_err < 5)
                  $display("GPIF-CDC: high half %h != expected pkt/word %0d/%0d",
                           a_out, cur_p, cur_w);
            end
            if (a_out_last) begin
               a_err = a_err + 1;
               if (a_err < 5) $display("GPIF-CDC: tlast on the high half");
            end
         end else begin                                // low half
            if (a_out !== 32'd0) begin
               a_err = a_err + 1;
               if (a_err < 5) $display("GPIF-CDC: low half %h != 0", a_out);
            end
            if (a_out_last !== ((cur_w == WORDS-1) ? 1'b1 : 1'b0)) begin
               a_err = a_err + 1;
               if (a_err < 5)
                  $display("GPIF-CDC: tlast %b at pkt %0d word %0d",
                           a_out_last, cur_p, cur_w);
            end
            if (cur_w == WORDS-1) begin cur_w = 0; cur_p = cur_p + 1; end
            else cur_w = cur_w + 1;
         end
      end
   end

   initial begin
      repeat (10) @(posedge fifo_clk);
      @(negedge fifo_clk); fifo_rst = 0; gpif_rst = 0;
      repeat (100) @(posedge fifo_clk);
      started = 1;
      wait (ap >= PACKETS);
      repeat (2000) @(posedge fifo_clk);
      $display("GPIF-CDC: %0d packets in, %0d 32-bit words out, %0d errors",
               ap, a_words, a_err);
      if (a_err == 0 && a_words == 2*PACKETS*WORDS && locked)
         $display("GPIF-CDC: PASS - packet boundaries and data survive the async FX3 interface");
      else
         $display("GPIF-CDC: FAIL - %0d errors, %0d of %0d words",
                  a_err, a_words, 2*PACKETS*WORDS);
      $finish;
   end

endmodule
